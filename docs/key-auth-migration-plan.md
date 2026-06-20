# Key-Auth Migration Plan

**Decision Date:** 2026-06-19  
**Decision Owner:** Rob McKenna  
**Author:** Keaton (Lead Architect)  
**Status:** Approved — awaiting execution

---

## 1. Decision Record

Rob McKenna has directed the team to replace the Kong `jwt` plugin on the MCP routes with Kong's `key-auth` plugin. This switches the client credential from a short-lived HS256-signed JWT (`Authorization: Bearer <token>`) to a static opaque API key (recommended header: `X-API-Key: <key>`).

**What changes:**  
The `jwt` plugin and its associated consumer `jwt_secrets` configuration are removed from the `mcp-service`. A `key-auth` plugin and a new consumer key credential replace them.

**What does not change:**  
- The `chat` service JWT plugin stays as-is.  
- The OAuth route family (`/mcp/oauth/sse`, `/mcp/oauth/messages`) is untouched.  
- No Azure infrastructure, no Bicep, no ACA deployment changes are required for this migration.

**Why Rob chose this:**  
Simplicity and operational convenience. No token generation script, no expiry management, no PyJWT dependency. A static API key is stored once in Foundry and works indefinitely until manually rotated.

---

## 2. Architecture Changes

### Current State

```
Foundry → Kong /mcp/sse       → jwt plugin (HS256, exp claim required) → MCP Server
Foundry → Kong /mcp/messages  → jwt plugin (HS256, exp claim required) → MCP Server
```

Consumer config:
```yaml
consumers:
  - username: poc-user
    jwt_secrets:
      - key: kong-poc
        secret: poc-secret-change-me
        algorithm: HS256
```

### Target State

```
Foundry → Kong /mcp/key/sse       → key-auth plugin (X-API-Key header) → MCP Server
Foundry → Kong /mcp/key/messages  → key-auth plugin (X-API-Key header) → MCP Server
```

Consumer config:
```yaml
consumers:
  - username: poc-user
    keyauth_credentials:
      - key: <generated-api-key>
```

### Parallel Route Strategy (Recommended)

Rather than mutating the existing `/mcp/sse` and `/mcp/messages` routes in place, add new `/mcp/key/sse` and `/mcp/key/messages` routes protected by `key-auth`. Keep the old JWT routes live until Foundry is migrated and validated. Deprecate the JWT routes in Phase 4.

This preserves the existing `10/10` test suite baseline and gives a clean rollback path.

---

## 3. Kong Configuration Changes

### 3.1 Plugin Comparison

| Attribute | `jwt` (current) | `key-auth` (target) |
|-----------|----------------|---------------------|
| Credential type | Signed JWT (HS256) | Opaque string key |
| Expiration | Yes — `exp` claim enforced | No — static until rotated |
| Header | `Authorization: Bearer <jwt>` | `X-API-Key: <key>` (recommended) |
| Credential location | Authorization header or `?jwt=` param | Header, query param, or body |
| Consumer binding | Via `iss` claim matching `jwt_secrets.key` | Via key lookup in `keyauth_credentials` |
| Credential generation | Requires JWT signing (PyJWT or openssl) | Any random string (e.g., `openssl rand -hex 32`) |

### 3.2 Header vs Query Param Decision

Use **`X-API-Key` header** (not query param `apikey=`).

Reasons:
- Query params appear in server access logs and browser history — avoid leaking the credential.
- Foundry's key-based connection stores a header name + value pair natively. Using a header is the cleaner Foundry integration pattern.
- `X-API-Key` is the conventional API key header name; more recognizable than a custom header.

### 3.3 `kong.yaml` Changes

#### Consumer section — replace `jwt_secrets` with `keyauth_credentials`

```yaml
# BEFORE
consumers:
  - username: poc-user
    jwt_secrets:
      - key: kong-poc
        secret: poc-secret-change-me
        algorithm: HS256

# AFTER
consumers:
  - username: poc-user
    keyauth_credentials:
      - key: <generated-api-key>   # generate with: openssl rand -hex 32
```

> Keep the `jwt_secrets` block if the `chat` service or any other service still needs it. For this POC, `chat` also uses `jwt`, so retain `jwt_secrets` for `chat` and add `keyauth_credentials` alongside.

#### New `mcp-key-service` — parallel key-auth protected routes

```yaml
services:
  # ... existing chat and mcp-service entries unchanged ...

  - name: mcp-key-service
    url: https://kongai-mcp-server.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io
    plugins:
      - name: key-auth
        config:
          key_names:
            - X-API-Key      # header name Foundry will send
          hide_credentials: true   # strip the key before forwarding to MCP server
          key_in_header: true
          key_in_query: false
          key_in_body: false
      - name: cors
        config:
          origins:
            - "*"
          methods:
            - GET
            - POST
            - OPTIONS
          headers:
            - Accept
            - Content-Type
            - X-API-Key
            - Cache-Control
            - Connection
          exposed_headers:
            - Content-Type
            - Cache-Control
            - Connection
          credentials: false     # must be false when origins: ["*"]
          max_age: 3600
    routes:
      - name: mcp-key-sse-route
        paths:
          - "/mcp/key/sse"
        methods:
          - GET
          - OPTIONS
        strip_path: false
        preserve_host: false
      - name: mcp-key-messages-route
        paths:
          - "/mcp/key/messages"
        methods:
          - POST
          - OPTIONS
        strip_path: false
        preserve_host: false
```

> **Important:** The MCP Server currently expects requests at `/mcp/sse` and `/mcp/messages`. Kong's `strip_path: false` preserves the full path, so the upstream will receive `/mcp/key/sse` — not `/mcp/sse`. Check whether the MCP server accepts this path or whether a `request-transformer` plugin needs to rewrite it (see Section 5).

### 3.4 Generating the API Key

```bash
openssl rand -hex 32
```

Example output: `a3f8e2d1c9b04765f1e2a3b4c5d6e7f80123456789abcdef0123456789abcdef`

Store this value securely. It becomes the `key` field in `keyauth_credentials` and the value Foundry sends in `X-API-Key`.

---

## 4. MCP Server Path Compatibility

The MCP Server currently advertises `/mcp/messages` as the message endpoint in the SSE bootstrap event. When Kong forwards a request to `/mcp/key/sse`, the server will respond with a bootstrap payload that includes a `?sessionId=` URL pointing back at `/mcp/messages`.

Two options:

**Option A — Use Kong `request-transformer` to rewrite the path (recommended for this POC)**  
Add a `request-transformer` plugin to `mcp-key-service` that strips the `/key` prefix before forwarding:

```yaml
- name: request-transformer
  config:
    replace:
      uri: "$(uri_captures[1])"   # strips /mcp/key prefix → /mcp/...
```

Or use a simpler approach: set `strip_path: true` on the route and configure a path prefix that matches cleanly:

```yaml
routes:
  - name: mcp-key-sse-route
    paths:
      - "/mcp/key"
    strip_path: true   # Kong forwards /sse to upstream, not /mcp/key/sse
```

> **Simplest POC approach:** point the new routes directly at `/mcp/key/sse` but also update the MCP server environment to accept this path (if it's configurable). If not configurable, use the request-transformer rewrite.

**Option B — Keep route paths identical to existing paths, just use a different service**  
Use `/mcp/sse` and `/mcp/messages` as the route paths on `mcp-key-service` too, and differentiate auth via route name and plugin config only. This avoids any MCP path issue but means two routes with the same path and different auth — Kong handles this via route priority, but it is fragile.

**Recommendation:** Use Option A with the `strip_path` approach. Less moving parts than a Lua transformer.

---

## 5. Implementation Phases

### Phase 1 — Add Key-Auth Routes in Parallel

**Goal:** New `/mcp/key/sse` and `/mcp/key/messages` routes exist alongside JWT routes. Both work independently.

Steps:
1. Generate an API key: `openssl rand -hex 32`
2. Add `keyauth_credentials` to the `poc-user` consumer in `kong.yaml`
3. Add `mcp-key-service` with `key-auth` plugin and two new routes to `kong.yaml`
4. Rebuild and redeploy the Kong container (or sync via Konnect if migrated)
5. Smoke test the new routes:
   ```bash
   curl -s -H "X-API-Key: <generated-key>" \
     https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/key/sse
   ```
6. Confirm the old JWT routes still return HTTP 200 with a valid token (regression check)

**Deliverable:** Two working route families. No Foundry changes yet.

---

### Phase 2 — Test Key-Auth Routes

**Goal:** Full functional validation of the new key-auth path before touching Foundry.

Steps:

1. **Health check — Kong gateway responds:**
   ```bash
   curl -I https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/key/sse
   # Expect: 401 Unauthorized (no key provided — correct behavior)
   ```

2. **Auth rejection — no key:**
   ```bash
   curl -s https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/key/sse
   # Expect: {"message":"No API key found in request"}
   ```

3. **Auth rejection — wrong key:**
   ```bash
   curl -s -H "X-API-Key: wrong-key" \
     https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/key/sse
   # Expect: {"message":"Invalid authentication credentials"}
   ```

4. **SSE stream — valid key:**
   ```bash
   curl -s -N -H "Accept: text/event-stream" \
     -H "X-API-Key: <generated-key>" \
     https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/key/sse
   # Expect: SSE bootstrap event with sessionId
   ```

5. **MCP message — valid key + valid sessionId:**
   ```bash
   SESSION_ID=<from-step-4>
   curl -s -X POST \
     -H "Content-Type: application/json" \
     -H "X-API-Key: <generated-key>" \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
     "https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/key/messages?sessionId=${SESSION_ID}"
   # Expect: tools list with get_weather and calculate
   ```

6. **Verify key is stripped from upstream:** Confirm the MCP server does not receive the `X-API-Key` header (enabled by `hide_credentials: true` in the plugin config).

7. **Regression — old JWT routes still work:** Run the existing test suite:
   ```bash
   bash test/test-mcp-gateway.sh
   ```
   All 10 tests must still pass.

**Deliverable:** All manual tests pass. JWT regression clean.

---

### Phase 3 — Migrate Foundry Configuration

**Goal:** Foundry project connection switches from JWT to the new API key.

Steps:

1. Open the Foundry project containing the Kong MCP gateway connection.
2. Locate the existing connection (currently using `Authorization: Bearer <jwt>`).
3. Create a **new** connection (do not edit the existing one yet):
   - **Server URL:** `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/key/sse`
   - **Authentication type:** `Key-based authentication`
   - **Credential name:** `X-API-Key`
   - **Credential value:** `<generated-api-key>` (no `Bearer` prefix — this is not a Bearer token)
4. Save the new connection and capture the new `project_connection_id`.
5. Update the Foundry agent to reference the new `project_connection_id`.
6. Validate tool discovery and a sample tool invocation via Foundry.
7. Keep the old JWT connection intact as fallback during this phase.

**Foundry credential format comparison:**

| Field | JWT (old) | Key-Auth (new) |
|-------|-----------|----------------|
| Credential name | `Authorization` | `X-API-Key` |
| Credential value | `Bearer eyJ...` | `a3f8e2d1c9b0...` |
| Header sent | `Authorization: Bearer eyJ...` | `X-API-Key: a3f8e2d1c9b0...` |

**Deliverable:** Foundry agent connects via key-auth. Tool discovery and invocation succeed.

---

### Phase 4 — Deprecate JWT Routes (Optional)

**Goal:** Remove the old JWT MCP routes once key-auth is confirmed stable.

Decision criteria before deprecating:
- Foundry has been running on key-auth for at least one full validation session.
- No other consumers of the old JWT routes have been identified.
- Rollback window has passed (suggest: 48–72 hours).

If proceeding:
1. Remove the `mcp-service` entry (JWT routes) from `kong.yaml`.
2. Remove `jwt_secrets` from the `poc-user` consumer (unless `chat` still needs it).
3. Redeploy or sync config.
4. Delete the old Foundry project connection for the JWT path.
5. Update `docs/foundry-setup-guide.md` to reflect key-auth as the default.

**Alternative — keep both in perpetuity:**  
There is no operational harm in keeping the JWT routes as a parallel option. They won't cause conflicts. The only cost is config sprawl and the occasional need to regenerate the JWT POC token to keep it non-expired.

---

## 6. Rollback Plan

Key-auth migration can be fully reversed at any phase.

### Rollback from Phase 1 (before Foundry changes)

1. Remove the `mcp-key-service` block and `keyauth_credentials` from `kong.yaml`.
2. Redeploy / sync config.
3. Result: exactly the original state. No Foundry changes needed.

### Rollback from Phase 3 (after Foundry migration)

1. In Foundry: switch the agent back to the original JWT `project_connection_id`.
2. The original JWT project connection was preserved in Phase 3 and is immediately usable.
3. Optionally regenerate a fresh JWT if the POC token has expired:
   ```bash
   bash scripts/generate-foundry-jwt.sh --ttl 3600
   ```
4. Update the JWT connection credential in Foundry with the new token.
5. Result: Foundry back on JWT. Key-auth routes can remain in parallel or be removed.

### Rollback from Phase 4 (after JWT routes deleted)

This is the only irreversible-ish phase. To restore JWT routes:
1. Re-add `mcp-service` block to `kong.yaml` with the `jwt` plugin.
2. Re-add `jwt_secrets` to the `poc-user` consumer.
3. Redeploy.
4. Regenerate and re-enter a JWT in Foundry.

Cost: ~15 minutes of configuration work. Not a hard block.

---

## 7. Trade-offs

### What We Lose by Switching to Key-Auth

| Capability | JWT (current) | Key-Auth (new) |
|-----------|---------------|----------------|
| Token expiration | Yes — `exp` claim enforced, Kong rejects stale tokens | No — key is valid until manually deleted |
| Cryptographic signing | Yes — HS256 HMAC signature | No — opaque string, no signature |
| Claims-based identity | Yes — `iss`, `sub`, `exp` in token payload | No — key has no payload metadata |
| Automatic revocation signal | Via expiry | Manual deletion only |

### What We Gain by Switching to Key-Auth

| Benefit | Detail |
|---------|--------|
| No token generation tooling | No PyJWT, no `generate-foundry-jwt.sh` script |
| No expiry management | Foundry stores it once and it keeps working |
| Simpler credential format | Raw string, no JSON encoding or Base64 |
| Easier to reason about | No clock skew issues, no `exp` miscalculation |
| Kong-native consumer binding | Key directly linked to consumer, no JWT claim lookups |

### Security Considerations

1. **Static credentials are higher-risk than time-limited ones.** A compromised key is valid forever until rotated. Establish a rotation policy before production use.

2. **Recommended mitigations:**
   - Store the key in Azure Key Vault; inject as an environment variable or ACA secret reference — do not commit it to the repo.
   - Treat the key as a secret at the same tier as a password.
   - Establish a regular rotation cadence (e.g., 90 days for POC, 30 days for any production path).
   - Enable Kong's rate-limiting plugin on the `mcp-key-service` (already on `chat`; add it here too).

3. **`hide_credentials: true`** in the key-auth plugin config ensures the raw API key is stripped before Kong forwards the request to the MCP Server. This is important: the MCP Server should never see the auth credential.

4. **One key per consumer.** The `poc-user` consumer should have exactly one key for this POC. If multiple Foundry projects or agents need separate credentials, create separate consumers — do not share a single key across unrelated consumers.

---

## 8. Validation Checklist

Use this checklist to confirm the migration is complete before deprecating the JWT routes.

### Kong Configuration
- [ ] `keyauth_credentials` added to `poc-user` consumer in `kong.yaml`
- [ ] `mcp-key-service` with `key-auth` plugin added to `kong.yaml`
- [ ] `/mcp/key/sse` route responds with 401 when no key provided
- [ ] `/mcp/key/sse` route responds with 401 when wrong key provided
- [ ] `/mcp/key/sse` route opens SSE stream with valid key
- [ ] `/mcp/key/messages` route responds to JSON-RPC messages with valid key and sessionId
- [ ] `hide_credentials: true` — `X-API-Key` header is not forwarded to MCP Server
- [ ] Rate limiting plugin applied to `mcp-key-service`
- [ ] Original `/mcp/sse` and `/mcp/messages` JWT routes still pass `bash test/test-mcp-gateway.sh` (10/10)

### Foundry Configuration
- [ ] New Foundry project connection created with `X-API-Key` credential
- [ ] Server URL points to `/mcp/key/sse` (not `/mcp/sse`)
- [ ] Tool discovery succeeds: `get_weather` and `calculate` visible in Foundry
- [ ] Sample weather tool prompt returns tool-derived result
- [ ] Sample calculate tool prompt returns tool-derived result
- [ ] Foundry agent updated to reference new `project_connection_id`

### Regression
- [ ] Original JWT test suite passes without modification: `bash test/test-mcp-gateway.sh`
- [ ] Old Foundry JWT connection still works during transition window

---

## 9. Files Affected

| File | Change |
|------|--------|
| `kong.yaml` | Add `keyauth_credentials` to consumer; add `mcp-key-service` with `key-auth` plugin |
| `docs/foundry-setup-guide.md` | Add key-auth section; update default path to `/mcp/key/sse` in Phase 4 |
| `docs/foundry-final-configuration.md` | Add key-auth connection option |
| `README.md` | Note new `/mcp/key/*` endpoint family |
| `scripts/generate-foundry-jwt.sh` | No change — retained for `chat` route JWT use |
| `scripts/generate-foundry-jwt.ps1` | No change — retained for `chat` route JWT use |

---

## 10. Execution Assignments (Suggested)

| Phase | Owner | Prerequisites |
|-------|-------|---------------|
| Phase 1 — Add key-auth routes | McManus (implementation) | API key generated by operator |
| Phase 2 — Test key-auth routes | Hockney (testing) | Phase 1 deployed |
| Phase 3 — Foundry migration | Rob McKenna (manual portal steps) | Phase 2 validated |
| Phase 4 — Deprecate JWT routes | Keaton decision call | Phase 3 stable ≥ 48 hours |

---

*Plan authored by Keaton. Approved by Rob McKenna on 2026-06-19.*
