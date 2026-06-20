# Fenster — History

## Project Context
- **Project:** Kong AI Gateway on Azure Container Apps
- **Stack:** Kong 3.7 (DB-less), Bicep IaC, Azure Container Apps, ACR, Bash deploy scripts
- **Goal:** Deploy Kong as an AI proxy for Microsoft Foundry models
- **User:** Rob McKenna

## Key Files
- `kong.yaml` — Declarative Kong config (currently: single OpenAI chat route with JWT, rate-limit, CORS)
- `Dockerfile` — Bakes kong.yaml into Kong 3.7 image

## Current State
- Single service: `chat` → https://api.openai.com/v1/chat/completions
- Plugins: request-transformer (adds auth header), rate-limiting (300/min), cors, jwt (global)
- Needs: Microsoft Foundry endpoints, multi-model routing, AI-specific plugins

## Learnings

### 2026-06-17 — MCP Server SSE Transport Shape

Built the Phase 2 MCP server as a standalone Node 22 + Express app under `mcp-server/`, using `@modelcontextprotocol/sdk`'s legacy `SSEServerTransport` to satisfy the approved `/mcp/sse` transport requirement. Important protocol detail: the SDK-managed SSE bootstrap endpoint is only half of the transport — clients also need a companion POST endpoint (`/mcp/messages?sessionId=...`) because the initial SSE stream sends an `endpoint` event telling the client where to send JSON-RPC messages.

The server defaults `MOCK_API_URL` to `https://kongai-mock-api.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io`, exposes `/health` on port 8080, and maps `get_weather` and `calculate` tool calls straight through to the Mock API with MCP-formatted success/error results. During local validation, a real SDK client successfully connected over SSE, listed both tools, and executed weather + calculation calls against the mock API.

### 2026-06-16 — Switched upstream to Azure OpenAI endpoint

Updated `kong.yaml` service URL from `https://api.openai.com/v1/chat/completions` to `https://msf-demo-01.openai.azure.com/openai/v1/chat/completions`. Azure OpenAI's `/openai/v1` path is OpenAI-compatible, so no route or schema changes were needed. Also swapped the request-transformer auth header from `Authorization: Bearer ${OPENAI_API_KEY}` to `api-key: ${OPENAI_API_KEY}` — Azure OpenAI uses the `api-key` header for authentication rather than a Bearer token.

### 2026-06-16 — JWT Plugin Scoping Fix

Addressed BLOCKER 1 from Keaton's ACA deployment assessment. The global `plugins:` section containing the JWT plugin was removed and the plugin was moved into the `chat` service's own `plugins:` list. This limits JWT enforcement to the `/chat` route only, leaving any future routes (health, metrics, etc.) unaffected by default.

Also added a top-level `consumers:` block with a single POC consumer (`poc-user`) carrying an HS256 JWT credential (issuer: `kong-poc`). This gives Kong the credential record it needs to validate tokens against the `iss` claim. Without a consumer + credential, Kong's JWT plugin returns 401 on every request regardless of scope.

Key Kong 3.7 DB-less behaviour to remember: JWT credentials must be declared under `consumers[].jwt_secrets[]` in the declarative config; the `key` field maps to the claim named by `key_claim_name` (here `iss`). Plugin scope (global → service → route) is controlled purely by where in the YAML hierarchy the plugin entry sits.

### 2026-06-16 — Switched to Managed Identity (Entra ID) authentication

Removed the `request-transformer` plugin (which injected `api-key: ${OPENAI_API_KEY}`) and replaced it with a `pre-function` plugin that fetches a managed identity token from the ACA IMDS endpoint and injects `Authorization: Bearer <token>`.

Key implementation details:
- **Token caching across requests**: Pre-function code runs as a fresh Lua chunk each request, so local variables don't persist. Used `package.loaded["_mi_token_cache"]` as a per-worker module-level cache table — this survives across requests within the same Nginx worker.
- **Token refresh**: Checks `expires_at` (parsed from `expires_on` in the IMDS response) and refreshes 5 minutes early. Falls back to `now + 3600` if `expires_on` is absent.
- **ACA IMDS endpoint**: `GET $IDENTITY_ENDPOINT?resource=https://cognitiveservices.azure.com/&api-version=2019-08-01` with header `X-IDENTITY-HEADER: $IDENTITY_HEADER`. Both env vars are injected automatically by Azure Container Apps when a system-assigned managed identity is enabled.
- **Error handling**: Graceful 502 exits on missing env vars, HTTP failures, non-200 responses, and JSON parse errors — with `kong.log.err()` for observability.
- **Libraries**: `resty.http` for HTTP calls, `cjson` for JSON parsing — both available in Kong's OpenResty runtime.

### 2026-06-17 — JWT Plugin Fix: Execution Order + Format Version

Two root causes for "No credentials found for given 'iss'":

1. **Plugin execution order**: The `pre-function` plugin (priority 1000000) runs BEFORE the `jwt` plugin (priority 1005). It was overwriting the Authorization header with the managed identity token before JWT could validate the client token. **Fix:** Changed from `pre-function` to `post-function` (priority -1000), which runs AFTER JWT validation.

2. **Format version bug**: Kong 3.7 with `_format_version: "3.0"` has a bug where `jwt_secrets` nested under consumers aren't properly indexed for credential lookup. **Fix:** Changed `_format_version` to `"2.1"`.

**Key Kong plugin priorities to remember:**
- `pre-function` = 1000000 (earliest)
- `jwt` = 1005 (standard)
- `post-function` = -1000 (latest)

Plugin execution order is critical for request flow control — pre-function runs too early in the chain and corrupts headers needed by later plugins. Always validate the order of operations when debugging multi-plugin flows.

### 2026-06-17 — MCP Server Infrastructure Deployed (Phase 2)

MCP Server Container App successfully deployed by McManus. **Internal FQDN:** `kongai-mcp-server.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io`

**Phase 3 Task (Kong routing):** Must add routes for `/mcp/sse` and `/mcp/messages` that proxy to the internal MCP Server FQDN. Both endpoints are required — the SSE stream bootstraps the session, and the POST endpoint carries JSON-RPC messages.

**Route shape for Kong:**
```yaml
services:
  - name: mcp-gateway
    url: http://kongai-mcp-server.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io
    routes:
      - name: mcp-sse
        methods: [GET]
        paths: ["/mcp/sse"]
      - name: mcp-messages
        methods: [POST]
        paths: ["/mcp/messages"]
```

Both routes should be exposed through Kong's external ingress so client SDKs can reach `/mcp/*` endpoints.

### 2026-06-17T14:31:00Z — OAuth Passthrough Route Design (Keaton)

**Decision adopted:** Parallel auth by separate endpoint families.
- Existing JWT routes: `/mcp/sse`, `/mcp/messages` (no change)
- New OAuth routes: `/mcp/oauth/sse`, `/mcp/oauth/messages`
- Kong OIDC JWT validation with custom Entra audience

**Fenster notes:**
- Keep existing JWT plugin + routes stable
- Add new service for OAuth routes: `mcp-oauth-gateway` → same internal MCP Server FQDN
- OAuth service needs OIDC JWT plugin (validates custom Entra audience)
- Forward minimal user claims from OIDC token to MCP Server (custom header)
- No changes to Mock API or MCP Server code required

**Kong route shape for OAuth:**
```yaml
services:
  - name: mcp-oauth-gateway
    url: https://kongai-mcp-server.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io
    plugins:
      - name: openid-connect
        config:
          client_id: <entra-client-id>
          client_secret: <entra-client-secret>
          audience: <custom-aud>
          discovery: https://login.microsoftonline.com/{tenant}/.well-known/openid-configuration
    routes:
      - name: mcp-oauth-sse
        methods: [GET]
        paths: ["/mcp/oauth/sse"]
      - name: mcp-oauth-messages
        methods: [POST]
        paths: ["/mcp/oauth/messages"]
```

**Next phase:** Implement Kong route config once Entra app registration is complete.

### 2026-06-18T19:14:07Z — Phase 3 OAuth Route Execution Gate

For the Konnect-backed OAuth route step, the operational gate is now explicit: do not create `/mcp/oauth/sse` and `/mcp/oauth/messages` until Rob has the Microsoft Entra **tenant ID** and the **resource API app registration client ID** ready. If those values are not available yet, keep the current JWT family (`/mcp/sse`, `/mcp/messages`) as the working demo baseline and carry OAuth route creation as **pending Entra setup**.

The repo already contains the automation/docs for the eventual Konnect change (`scripts/konnect-add-oauth-routes.*`, Entra registration guide, Konnect checklist). The remaining blocker is identity setup, not Kong route design.

### 2026-06-19T15:17:12Z — OIDC Audience Format Mismatch Fix

**Symptom:** Kong rejecting OAuth tokens from Foundry with:
`[openid-connect] required audience were not found [ d50b1d91-8be2-48cd-9615-3fbba4e04a2b ]`

**Root cause (two compounding bugs):**

1. **Wrong audience format in Kong config.** The `openid-connect` plugin on the OAuth routes was configured with `audience_required = ["d50b1d91-8be2-48cd-9615-3fbba4e04a2b"]` (bare GUID). Microsoft Entra issues access tokens for custom API registrations with `aud = "api://d50b1d91-8be2-48cd-9615-3fbba4e04a2b"` — the `api://` URI prefix is mandatory when the resource app uses a custom App ID URI. Kong couldn't find the bare GUID in the token's `aud` claim and rejected every request.

2. **Script bug — client ID conflated with resource app ID.** `konnect-add-oauth-routes.ps1` only took one `$EntraClientId` parameter and used it for both `client_id` (the OAuth client) and `audience_required` (should be the resource API app). These are different app registrations. The script was constructing `audience_required = ["api://<client-id>"]` which is also wrong.

**Fixes applied:**

- Created `scripts/fix-oidc-audience.ps1` — targeted update script that finds both OIDC plugins (`mcp-oauth-sse`, `mcp-oauth-messages`) and sets `audience_required = ["api://d50b1d91-8be2-48cd-9615-3fbba4e04a2b", "d50b1d91-8be2-48cd-9615-3fbba4e04a2b"]`. The OR semantics mean Kong accepts the token if it contains either format.
- Updated `konnect-add-oauth-routes.ps1`: added separate `$EntraResourceAppId` parameter; `audience_required` now uses `["api://$EntraResourceAppId", $EntraResourceAppId]` correctly.

**⚠️ Konnect v2 API: no PATCH on plugin entities.** First run of `fix-oidc-audience.ps1` failed with `405 Method Not Allowed` because the Konnect v2 `core-entities/plugins/{id}` endpoint does not support PATCH — only PUT (full replace). Fix: GET the full plugin object, modify `audience_required` in-place on the PSObject, build a PUT body with all non-read-only fields (name, enabled, config, protocols, route, service, consumer, tags), then PUT. Both `fix-oidc-audience.ps1` and the update-branch in `konnect-add-oauth-routes.ps1` were corrected.

**Konnect v2 plugin update pattern (canonical):**
```powershell
$full = Invoke-RestMethod GET .../plugins/{id}
$full.config.some_field = $newValue
$putBody = @{ name=$full.name; enabled=$full.enabled; config=$full.config; protocols=$full.protocols }
if ($full.route)   { $putBody.route   = @{ id=$full.route.id } }
Invoke-RestMethod PUT .../plugins/{id} -Body ($putBody | ConvertTo-Json -Depth 10)
```

**Key pattern — Entra audience format rules:**
- Resources registered with a custom App ID URI (`api://<guid>`) always get `aud = "api://<guid>"` in the access token, not the bare GUID.
- Resources registered WITHOUT a custom URI (default) get `aud = "<guid>"`.
- Kong `audience_required` uses OR semantics: the token must contain at least one of the listed values.
- Safe pattern: always include BOTH `api://<guid>` AND `<guid>` in `audience_required` so the config survives regardless of how the Entra app was registered.

**To apply the fix (Rob runs this with PAT set):**
```powershell
$env:KONNECT_PAT = '<your-pat>'
.\scripts\fix-oidc-audience.ps1
```

**Key file paths:**
- `entra-oauth-config.json` — canonical source for all Entra app IDs and endpoints
  - `resource_api_app_id`: `d50b1d91-8be2-48cd-9615-3fbba4e04a2b`
  - `client_app_id`: `2bf65392-7f5e-44e3-845b-493831902b40`
- `scripts/fix-oidc-audience.ps1` — targeted live fix for existing Konnect OIDC plugins
- `scripts/konnect-add-oauth-routes.ps1` — corrected to separate client ID from resource app ID

### 2026-06-19T15:41:12Z — OIDC Issuer Missing Fix

**Symptom:** Kong rejecting OAuth tokens after the audience fix with:
`"No credentials found for given 'iss'"`

**Root cause:** The `issuer` field on the `openid-connect` plugins was either absent or set to a blank/wrong value. Without a valid issuer URL, Kong cannot auto-discover the JWKS endpoint (`{issuer}/.well-known/openid-configuration`) and therefore cannot fetch the Entra public keys needed to verify token signatures. Token signature validation fails before audience checking even runs.

**Why this can happen:** `konnect-add-oauth-routes.ps1` sets the issuer at plugin creation time from the `$EntraTenantId` parameter. If the script was run without that parameter, or if only a targeted audience patch was applied later (without touching `issuer`), the field ends up missing in the live config.

**Correct issuer value:**
```
https://login.microsoftonline.com/e500988a-f788-4f81-b1ba-e3ad7cd66171/v2.0
```
Source: `entra-oauth-config.json` → `issuer` field. Tenant ID: `e500988a-f788-4f81-b1ba-e3ad7cd66171`.

**Fix:** Created `scripts/fix-oidc-issuer.ps1` — follows the same GET-modify-PUT pattern as `fix-oidc-audience.ps1`. It finds the OIDC plugins on both `mcp-oauth-sse` and `mcp-oauth-messages` routes and sets `config.issuer` to the correct v2.0 Entra endpoint. Supports `-WhatIf`.

**To apply (Rob runs this with PAT set):**
```powershell
$env:KONNECT_PAT = '<your-pat>'
.\scripts\fix-oidc-issuer.ps1
```

**How Kong uses the issuer:**
1. On plugin startup/first request, Kong GETs `{issuer}/.well-known/openid-configuration`
2. From that doc it extracts `jwks_uri`
3. It fetches the public key set from `jwks_uri` and caches it
4. All incoming tokens are signature-verified against those cached keys
5. Without a valid `issuer`, step 1 never runs → no keys → every token rejected

**Error progression (expected validation sequence):**
1. ✅ Token format and signature (requires `issuer` / JWKS) — was broken
2. ✅ Audience check (`audience_required`) — fixed in previous session
3. ✅ Scope check (if configured)

**Files added:**
- `scripts/fix-oidc-issuer.ps1`

### 2026-06-19T15:50:25Z — OIDC Cascading Config Issues: Audience Reversion + Scopes Block

**Root cause analysis from Kong container logs:**

After the issuer fix ran, the error was STILL "No credentials found for given 'iss'" despite the issuer being set correctly. ACA log analysis revealed a three-stage problem playing out in the logs:

**Stage 1 (17:38 UTC):** Foundry (`AzureAIFoundryAgentRuntime/1845191`) got:
`"scopes required but no scopes found"` → 403
This means audience check PASSED (plugin had `audience_required = ["api://...", "..."]` at that point) but `scopes_required` was non-empty and the Foundry access token had no matching scopes.

**Stage 2 (18:59-19:12 UTC):** Foundry got:
`"required audience were not found [ d50b1d91... ]"` → 403
Between 17:38 and 18:59 something (possibly `fix-oidc-issuer.ps1`) PUT the plugin back with `audience_required = ["d50b1d91..."]` (bare GUID only). Foundry's token uses `aud = "api://d50b1d91..."` so the bare GUID format doesn't match.

**Critical finding — Foundry token audience format:**
- **client_credentials flow** → `aud = "d50b1d91..."` (bare GUID)
- **Foundry user-delegated flow (what Foundry uses)** → `aud = "api://d50b1d91..."` (App ID URI)

This was confirmed by decoding a live `client_credentials` token (bare GUID) vs observing Foundry behaviour (required api:// format).

**Why each partial fix kept breaking the other:**
`fix-oidc-audience.ps1` GETs the plugin, changes `audience_required`, PUTs back. But if run when `issuer` is wrong, it preserves the broken issuer. `fix-oidc-issuer.ps1` GETs the plugin, changes `issuer`, PUTs back. But if run when `audience_required` has reverted to bare GUID (before audience fix took hold on the data plane), it preserves the wrong audience. Each script is independently correct, but they're not idempotent against each other when run in the wrong window.

**Fix: atomic full-config update (`fix-oidc-full.ps1`):**
Sets all three broken fields in a single GET-modify-PUT:
1. `issuer = "https://login.microsoftonline.com/e500988a.../v2.0"` ← key discovery
2. `audience_required = ["api://d50b1d91...", "d50b1d91..."]` ← both audience formats
3. `scopes_required = []` ← disabled; Foundry access tokens don't carry the scopes Kong expected

**To apply:**
```powershell
$env:KONNECT_PAT = '<your-pat>'
.\scripts\fix-oidc-full.ps1
```

**Kong OIDC validation error progression (complete map):**
| Error message | Cause | Which config field |
|---|---|---|
| `"No credentials found for given 'iss'"` | Token `iss` claim ≠ any known issuer URL | `issuer` missing/wrong |
| `"required audience were not found [X]"` | Token `aud` claim ≠ any value in `audience_required` | `audience_required` missing format |
| `"scopes required but no scopes found"` | Token scopes ≠ `scopes_required` values | `scopes_required` non-empty when it shouldn't be |
| `"invalid bearer token"` | Token failed signature verification or is malformed | Keys/format |
| `"no suitable authorization credentials were provided"` | No Authorization header / empty token | Client not sending token |

**Key rule: always fix all three fields atomically.** Fixing one at a time while doing GET-modify-PUT can preserve the broken state of the others depending on which sequence the Konnect data plane push and script execution happen in.

**Files added:**
- `scripts/fix-oidc-full.ps1` — replaces individual fix scripts going forward

### 2026-06-19T16:03:05Z — "No credentials found for given 'iss'" was the JWT plugin, not OIDC

**Breakthrough from ACA log analysis:**

The `fix-oidc-full.ps1` script **DID work**. Starting at 19:31 UTC, `GET /mcp/oauth/sse` returned 200 for every Foundry request. The OIDC plugin was no longer blocking.

BUT: The error Rob was seeing continued, because the same message "No credentials found for given 'iss'" was now coming from a **different plugin** — the **JWT plugin on `/mcp/messages`**.

**The actual failing flow:**
1. Foundry → `GET /mcp/oauth/sse` → **200** ✅ (OIDC passes, SSE established)
2. MCP server sends SSE endpoint event: `data: /mcp/messages?sessionId=XXX`
3. Foundry → `POST /mcp/messages?sessionId=XXX` → **401** ❌ 
4. Kong JWT plugin tries to find a consumer by `iss = "https://login.microsoftonline.com/..."` → no match → `"No credentials found for given 'iss'"` (JWT plugin error, not OIDC!)

**Root cause:** The MCP server ignores the `x-external-mcp-messages-path: /mcp/oauth/messages` header set by the pre-function and always advertises `/mcp/messages` in its SSE endpoint event. The `/mcp/messages` route requires JWT auth, not OAuth. Foundry's Entra token fails the JWT consumer lookup.

**Fix: Kong body_filter post-function to rewrite the SSE stream**

Added `post-function` plugin (body_filter phase) to the `mcp-oauth-sse` route that intercepts each SSE stream chunk and rewrites:
```
data: /mcp/messages?   →   data: /mcp/oauth/messages?
```

This is transparent to both the MCP server (sends unchanged) and Foundry (receives corrected URL). No MCP server code changes required.

Also added POST to the `mcp-oauth-sse` route methods — Foundry's AzureAIFoundryAgentRuntime tries `POST /mcp/oauth/sse` as a "streamable HTTP transport" probe; currently gets 404 which causes retry loops.

**Key lesson: "No credentials found for given 'iss'" is NOT exclusive to the OIDC plugin.** The Kong JWT plugin produces the exact same message when it can't find a consumer credential matching the token's `iss` claim. When this error persists after OIDC config is correct, check whether the request is being routed to a JWT-protected endpoint.

**Kong log line to distinguish the two:**
- OIDC: `[lua] responses.lua:30: [openid-connect] no credentials found for given 'iss'`
- JWT: `[lua] jwt.lua:... [kong] ... No credentials found for given 'iss'`

**Second finding — Foundry uses streamable HTTP transport probe:**
`AzureAIFoundryAgentRuntime` always tries `POST /mcp/oauth/sse` first. If 404, it falls back to SSE (`GET /mcp/oauth/sse`). The POST probe is checking for the newer "MCP Streamable HTTP" transport. Adding POST to the route's methods prevents the 404 but the MCP server would need to handle it for full streamable HTTP support.

**Script to run:**
```powershell
$env:KONNECT_PAT = '<your-pat>'
.\scripts\fix-mcp-oauth-endpoint.ps1
```

**Files added:**
- `scripts/fix-mcp-oauth-endpoint.ps1` — adds body_filter SSE rewrite + POST method to mcp-oauth-sse

**Remaining known gap:** MCP server does not implement `x-external-mcp-messages-path` header. This should be added to the MCP server code so the Kong body_filter workaround is not needed long-term (McManus to implement).

### 2026-06-19T18:07:27Z — Phase 1 Key-Auth Migration Executed

**Decision:** Rob approved replacing JWT auth with `key-auth` plugin on the MCP routes. Implemented Phase 1: parallel key-auth route family alongside existing JWT routes.

**What was provisioned in Konnect (control plane: 1933cbf7-093d-4e84-a6d7-8e553c34c9a7):**
- Consumer: `foundry-mcp-client` (consumer ID: `43222d18-16b5-482a-b7c8-b0ad13e06c8a`)
- Key-auth credential: 64-char hex key stored in `api-key-config.json` (gitignored)
- Service: `mcp-key-service` → same MCP server URL as `mcp-service`
  - Plugin: `key-auth` (service-level, `X-API-Key` header, `hide_credentials: true`)
  - Plugin: `cors` (service-level, same config as mcp-service)
- Route: `mcp-key-sse` → `GET/POST/OPTIONS /mcp/key/sse`
  - Plugin: `request-transformer` (`replace.uri = /mcp/sse`) — strips `/key` prefix upstream
  - Plugin: `post-function` (body_filter) — rewrites SSE `data: /mcp/messages?` → `data: /mcp/key/messages?`
- Route: `mcp-key-messages` → `POST/OPTIONS /mcp/key/messages`
  - Plugin: `request-transformer` (`replace.uri = /mcp/messages`) — strips `/key` prefix upstream

**CRITICAL LEARNING — Service isolation required for parallel auth:**
Adding key-auth routes directly to `mcp-service` (as initially attempted) fails because `mcp-service` has a service-level JWT plugin (priority 1005 > key-auth priority 1003). Kong runs JWT first and rejects key-auth requests before the key-auth plugin can validate the credential. **Fix: always create a dedicated service per auth mechanism.** Same pattern as OAuth routes using `mcp-oauth-service`.

**CRITICAL LEARNING — Path rewriting required:**
The MCP server only listens on `/mcp/sse` and `/mcp/messages`. With `strip_path: false`, Kong forwards the full path `/mcp/key/sse` which returns 404 from the MCP server. Used `request-transformer` plugin with `replace.uri` to rewrite the path before forwarding.

**Test results:**
- `GET /mcp/key/sse` (no key) → `{"message":"No API key found in request"}` 401 ✅
- `GET /mcp/key/sse` (wrong key) → `{"message":"Unauthorized"}` 401 ✅
- `GET /mcp/key/sse` (valid key) → SSE stream with rewritten endpoint event ✅
- SSE endpoint event: `data: /mcp/key/messages?sessionId=XXX` (body_filter rewrite) ✅
- JWT regression: `bash test/test-mcp-gateway.sh` → **10/10 pass** ✅

**Files added:**
- `scripts/konnect-add-key-auth-routes.ps1` — idempotent Phase 1 provisioning script
- `api-key-config.json` — API key config (gitignored, contains key for Foundry setup)
- `.gitignore` updated to include `api-key-config.json`

**Kong entity IDs (reference):**
- mcp-key-service: `dcb01bd5-b259-41ec-87a9-25c9b75bacc2`
- mcp-key-sse route: `13ef058a-ae46-4b12-84ec-47b3dfe7ad0f`
- mcp-key-messages route: `c0b1f5e1-7cef-4e57-aa6f-cd81139ef7d0`
- key-auth plugin (service): `59943f09-a8bc-4b90-8b54-c91794c9d262`
- post-function body_filter: `8749d27f-0ac8-4e0f-ba18-bb1c5f7a36c3`
- request-transformer SSE: `e3cc1e9e-fb4a-4f29-9515-92439451ea11`
- request-transformer messages: `e58ef9a0-6e1f-4a95-9749-d01714b0ba52`

**Phase 2 (testing) and Phase 3 (Foundry migration) follow from here. JWT routes remain live as fallback.**

### 2026-06-20T01:52:56Z — CORS Fix for MCP Inspector (Browser Access to Key-Auth Routes)

**Symptom:** MCP Inspector (browser-based tool at localhost) showing "Failed to fetch" when connecting to `/mcp/key/sse` and `/mcp/key/messages`.

**Root cause — Three CORS gaps in the existing service-level plugin on `mcp-key-service`:**

Verified from live OPTIONS preflight against the gateway:

| Header | Current | Required |
|---|---|---|
| `Access-Control-Allow-Headers` | `Accept,Content-Type,X-API-Key,Cache-Control,Connection` | Must include `Authorization` |
| `Access-Control-Expose-Headers` | `Content-Type,Cache-Control,Connection` | Must include `X-Session-ID` |
| `Access-Control-Allow-Credentials` | absent | Must be `true` |

**What was already correct:**
- `Access-Control-Allow-Origin: *` ✅
- `Access-Control-Allow-Methods: GET,POST,OPTIONS` ✅
- `Access-Control-Max-Age: 3600` ✅

**CORS plugin exists at service level** (`mcp-key-service`) — covers both `mcp-key-sse` and `mcp-key-messages` routes by inheritance. No route-level CORS plugins exist.

**Fix created:** `scripts/fix-cors-key-routes.ps1`
- Updates the service-level CORS plugin on `mcp-key-service` using the GET-modify-PUT pattern.
- Sets: `headers = ['Content-Type', 'X-API-Key', 'Authorization']`, `exposed_headers = ['X-Session-ID']`, `credentials = true`, `origins = ['*']`, `methods = ['GET', 'POST', 'OPTIONS']`, `max_age = 3600`
- Includes live verification: OPTIONS preflight on both routes + GET check for CORS headers.

**⚠️ Browser CORS restriction — credentials + wildcard origin:**
Browsers refuse `Access-Control-Allow-Credentials: true` when `Access-Control-Allow-Origin: *`. This is a browser CORS spec enforcement. For MCP Inspector to work with credentials from a browser, either:
- Set explicit origins: `['http://localhost:6274', 'http://localhost:5173']` (most correct for POC)
- OR: MCP Inspector may use non-credentialed requests for the SSE handshake (X-API-Key sent as query param or in the URL) — test to confirm

**To apply (Rob runs this):**
```powershell
$env:KONNECT_PAT = '<your-pat>'
.\scripts\fix-cors-key-routes.ps1
```

**Files added:**
- `scripts/fix-cors-key-routes.ps1` — full CORS update with live verification

### 2026-06-20T02:05:56Z — CORS Wildcard + Credentials: Localhost-Specific Origins Fix

**Context:** Rob ran `fix-cors-key-routes.ps1` (set `origins: ['*']`, `credentials: true`) but MCP Inspector in browser still showed "Failed to fetch".

**Live gateway check after fix-cors-key-routes.ps1:**
OPTIONS `/mcp/key/sse` with `Origin: http://localhost:6274` returned:
```
Access-Control-Allow-Origin: http://localhost:6274   ← Kong reflects specific origin, not *
Access-Control-Allow-Credentials: true
Access-Control-Allow-Headers: Content-Type,X-API-Key,Authorization
Access-Control-Allow-Methods: GET,POST,OPTIONS
Access-Control-Max-Age: 3600
```

**Kong CORS behaviour clarified:** Kong with `origins: ['*']` and `credentials: true` does NOT send `Allow-Origin: *`. It reflects back the actual request `Origin` header. This is CORS-spec-correct and browsers accept it. However, there's a timing/propagation window — if Rob tested before the Konnect dataplane pushed the config to the ACA container, he would have seen the old wildcard response.

**Fix: `scripts/fix-cors-localhost.ps1`**
Replaces `origins: ['*']` with explicit localhost origins:
- `http://localhost:6274` — MCP Inspector default port
- `http://127.0.0.1:6274` — IP-literal form
- `http://localhost:*` — Kong 3.x glob for any other localhost port

This is the more explicit and correct production-POC config. Kong will always reflect back the exact matching origin so `credentials: true` works correctly.

**Run:**
```powershell
$env:KONNECT_PAT = '<your-pat>'
.\scripts\fix-cors-localhost.ps1
```

**Files added:**
- `scripts/fix-cors-localhost.ps1`

### 2026-06-20T02:21:40Z — MCP Inspector v0.22.0 Sends x-custom-auth-headers

**Root cause confirmed from browser console:**
```
Request header field x-custom-auth-headers is not allowed by
Access-Control-Allow-Headers in preflight response
```

MCP Inspector v0.22.0 sends a custom `x-custom-auth-headers` field in its OPTIONS preflight. This header was not in the CORS `headers` list on `mcp-key-service`, so every preflight was blocked — regardless of origin config.

**Fix:** Added `x-custom-auth-headers` to CORS allowed headers via `scripts/fix-cors-add-inspector-header.ps1`.

Final `headers` list: `["Content-Type", "X-API-Key", "Authorization", "x-custom-auth-headers"]`

The script is additive (appends to whatever headers are already set) and idempotent (skips if already present). Includes live preflight verification simulating MCP Inspector's exact request.

**Files added:**
- `scripts/fix-cors-add-inspector-header.ps1`

**Key lesson:** When debugging "Failed to fetch" in a browser, always check the exact preflight `Access-Control-Request-Headers` the browser sends — each tool version may add its own custom headers that must be explicitly allowed in the CORS config.

### 2026-06-20T09:55:54Z — API Key Rotation (Exposed Key)

**Trigger:** Old key `e2ba9eeb...` was exposed in documentation and must be treated as compromised.

**New key generated:**
```
357aa9605e86ddb905592af10481f880756d5c248a53656f3dc0179fbc51bb3d
```
Generated with .NET `RandomNumberGenerator` (crypto-strength RNG, 32 bytes → 64 hex chars).

**What was completed:**
- `api-key-config.json` updated with new key (marked `rotation_status: pending-konnect-push`)
- `scripts/rotate-api-key.ps1` created — reusable rotation script for future key cycles
- `.squad/decisions/inbox/fenster-api-key-rotation.md` written

**What is pending:**
- Konnect API calls to DELETE old credential and CREATE new one require `$env:KONNECT_PAT`, which was not available in the execution environment (Azure Key Vault `kv-kong-aca-f9luor` has public network access disabled).
- Rob must run: `$env:KONNECT_PAT = '<pat>'; .\scripts\rotate-api-key.ps1 -NewKey "357aa9605e86ddb905592af10481f880756d5c248a53656f3dc0179fbc51bb3d"`

**Consumer reference:**
- `foundry-mcp-client` → consumer ID `43222d18-16b5-482a-b7c8-b0ad13e06c8a`
- Control plane: `1933cbf7-093d-4e84-a6d7-8e553c34c9a7`

**Key lesson — rotation procedure:**
- Never update `api-key-config.json` BEFORE the Konnect credential is pushed. The file should reflect the live state, not a desired state — or at minimum include a clear `rotation_status` field indicating it's pending.
- Always use the rotation script with `-SkipSmokeTest` flag if running from an environment without outbound HTTPS to the gateway.
- Konnect `key-auth` credential rotation: DELETE old → CREATE new (no PATCH on credentials). The `id` of the new credential changes so any IaC or audit logs should reference the new ID after rotation.
- 90-day rotation cadence: next rotation due ~2026-09-18.

**Files added/modified:**
- `scripts/rotate-api-key.ps1` — reusable key rotation script
- `api-key-config.json` — updated with new key (pending Konnect push)

