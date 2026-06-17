# Squad Decisions

## Active Decisions

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
