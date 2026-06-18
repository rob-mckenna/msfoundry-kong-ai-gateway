# Squad Decisions

## Active Decisions

### Keaton — Foundry Auth Automation

For the current Microsoft Foundry integration, the team should standardize on **Foundry key-based authentication** backed by the existing Kong HS256 JWT model.

**Why:**
- It matches the deployed gateway without changing Kong config or Azure resources.
- Foundry can store the gateway credential in a project connection as:
  - name: `Authorization`
  - value: `Bearer <jwt>`
- It is the fastest path to validate tool discovery and tool invocation through the current `/mcp/sse` and `/mcp/messages` routes.

**Follow-on guidance:**
- Keep this as the POC/default path.
- Treat **OAuth identity passthrough** as the upgrade path when we need per-user identity and consent.
- Treat **Microsoft Entra authentication** as the upgrade path when we want service identity plus automatic token rotation.
- Any production rollout must also add secret rotation, token refresh operations, and stronger client separation than the shared POC credential.

### Fenster — Kong MCP Route Follow-up

For Azure Container Apps internal service-to-service routing, Kong should target the internal ingress FQDN over HTTPS (`https://<app>.internal.<env>...`) instead of trying to reach the container port directly with `http://<fqdn>:8080`.

**Why this matters:**
- The approved Phase 3 architecture was correct about exposing `/mcp/sse` and `/mcp/messages` through Kong, but the concrete upstream URL shape in practice is HTTPS-on-FQDN for ACA internal ingress.
- Using `http://kongai-mcp-server.internal...:8080` caused Kong requests to hang before the SSE bootstrap event because the MCP Server request never arrived.
- Switching the Kong service URL to `https://kongai-mcp-server.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io` immediately fixed end-to-end SSE and MCP message delivery.

**Operational note:** Kong 3.7 custom Nginx overrides for SSE timeouts also need the full directive name in the proxy block:
- `KONG_NGINX_PROXY_PROXY_READ_TIMEOUT=600s`
- `KONG_NGINX_PROXY_PROXY_SEND_TIMEOUT=600s`

Using `KONG_NGINX_PROXY_READ_TIMEOUT` / `...SEND_TIMEOUT` renders invalid `read_timeout` / `send_timeout` directives and prevents Kong from starting.

### Keaton — OAuth Passthrough Parallel Auth Design

Adopt **parallel auth by separate MCP endpoint families**.

- Keep the existing JWT/key-based path unchanged:
  - `GET /mcp/sse`
  - `POST /mcp/messages`
- Add a new OAuth passthrough path:
  - `GET /mcp/oauth/sse`
  - `POST /mcp/oauth/messages`
- Validate OAuth tokens at Kong with **OIDC JWT access-token validation** against a **custom Microsoft Entra audience** we control.
- Forward a minimal set of verified user claims to the MCP Server and optionally the Mock API for audit visibility.

**Rationale:** This is the best demo shape because it preserves the current working JWT flow while making OAuth identity passthrough visible and easy to explain. It also contains risk: the existing JWT routes, tests, and Foundry setup do not need to change.

Separate routes are clearer than header-based branching because each auth model has an explicit endpoint and isolated Kong policy. That makes troubleshooting, rollback, and documentation much simpler.

**Key implementation note:** The current MCP server advertises `/mcp/messages` during the SSE bootstrap flow. To support `/mcp/oauth/messages`, the MCP server needs a small enhancement so the advertised public message path can be configured per route family.

**Trade-offs:**

Advantages:
- Lowest regression risk to the existing JWT demo
- Clear side-by-side comparison for Rob
- Clean Foundry setup with two project connections
- Route-level rollback without touching the JWT baseline

Costs:
- Slightly more Kong route/config duplication
- Requires MCP bootstrap-path awareness for the OAuth route family
- Preferred Kong plugin (`openid-connect`) requires Enterprise/Konnect capability or a fallback design if the team stays on OSS Kong

**Production readiness considerations:**
1. Use a **custom Entra audience**, not a Microsoft-owned audience, to avoid the Foundry restriction on passing Microsoft tokens to untrusted custom MCP endpoints.
2. Prefer **stateless JWT validation via OIDC/JWKS** over introspection for Entra access tokens.
3. Store client secrets outside the repo and define a rotation owner before rollout.
4. Keep user-identity enforcement at the gateway first; add downstream authorization only when a tool actually needs it.
5. Add observability that distinguishes JWT vs OAuth route traffic without logging raw tokens.

### Keaton — Konnect as the OAuth Enablement Path for ACA Gateway

Use **Kong Konnect with a self-managed ACA data plane** as the preferred path for adding OAuth passthrough.

**Implementation shape:**
1. Keep the current ACA-hosted Kong container as the runtime data plane.
2. Move configuration ownership from local `kong.yaml` to a Konnect control plane.
3. Store Konnect cluster certificate material in **Azure Key Vault** and inject it into ACA with the app's system-assigned managed identity.
4. Preserve the current JWT route family: `GET /mcp/sse`, `POST /mcp/messages`
5. Add a second OAuth route family in Konnect: `GET /mcp/oauth/sse`, `POST /mcp/oauth/messages`
6. Attach `openid-connect` only to the OAuth route family.

**Why:** It unlocks the supported Kong `openid-connect` capability without introducing a second gateway product. It preserves the working JWT demo during cutover. It keeps rollback simple and aligns with the current ACA + Key Vault + managed identity operating model.

**Benefits:**
- Clean parallel-auth demo
- Better separation of control plane and runtime concerns
- Portal/API-driven changes instead of image rebuilds for every route tweak
- Future export/backup of gateway config from Konnect

**Costs:**
- The runtime no longer uses `kong.yaml` as the source of truth
- ACA deployment needs new Konnect env vars and Key Vault secret refs
- Team must manage Konnect control plane objects and cert rotation procedures
- `/mcp/oauth/messages` still depends on the MCP server advertising the correct public path

**Follow-up work:** Update docs and runbooks for Konnect cutover. Implement Dockerfile and Bicep changes in a later task. Add MCP server public message path configurability if not already present.
