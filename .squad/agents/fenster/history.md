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
