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
