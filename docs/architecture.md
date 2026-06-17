# Architecture Documentation

This document describes the current POC architecture for the Kong AI Gateway, the MCP tool chain, and the validated deployment workflow.

## System Overview

### Primary outcomes

- **Chat proxy:** Kong fronts Azure OpenAI and swaps a client JWT for a managed identity token.
- **MCP gateway:** Kong fronts an internal MCP server that exposes the mock tools used for Foundry integration.

### End-to-end component map

```text
External clients / Microsoft Foundry
  |
  | HTTPS
  v
Kong Gateway (Azure Container Apps, external ingress)
  | \
  |  \__ POST /chat ------------------------------> Azure OpenAI
  |
  \____ GET /mcp/sse + POST /mcp/messages -------> MCP Server (ACA internal ingress)
                                                    |
                                                    v
                                                 Mock API (ACA internal ingress)

Build and operations dependencies:
  Local repo -> az acr build -> Azure Container Registry
  Logs/metrics -> Log Analytics workspace
  All apps run inside one Azure Container Apps Environment
```

### Current deployed endpoints

| Surface | Endpoint |
|---|---|
| Public gateway | `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io` |
| MCP bootstrap | `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/sse` |
| MCP messages | `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/messages` |
| Chat proxy | `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/chat` |
| Internal MCP upstream | `https://kongai-mcp-server.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io` |
| Internal Mock API upstream | `https://kongai-mock-api.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io` |

## Data Flows

### 1. Chat flow

1. Client sends `POST /chat` with `Authorization: Bearer <client JWT>`.
2. Kong validates the JWT with the `jwt` plugin.
3. Kong's `post-function` plugin calls the Container Apps managed identity endpoint.
4. Kong replaces the incoming bearer token with an Azure access token for `https://cognitiveservices.azure.com/`.
5. Kong proxies the request to Azure OpenAI.
6. The completion response returns through Kong to the client.

### 2. Foundry MCP flow

1. Foundry opens `GET /mcp/sse` with the same gateway JWT model used for the POC.
2. Kong validates the token and proxies the request to the internal MCP server.
3. The MCP server creates an SSE session and emits the companion message endpoint with `sessionId`.
4. Foundry sends JSON-RPC messages to `POST /mcp/messages?sessionId=<uuid>`.
5. The MCP server executes either:
   - `GET /api/weather?location=<city>`
   - `POST /api/calculate`
6. The Mock API returns JSON.
7. The MCP server maps the JSON into MCP `content` and `structuredContent`.
8. Foundry receives the result over the open session and can incorporate it into a model response.

## Component Details

| Component | Role | Key configuration |
|---|---|---|
| Kong Gateway | Public ingress and policy enforcement | DB-less config in `kong.yaml`; JWT auth on `/chat` and `/mcp/*`; SSE-safe proxy settings in `infra/main.bicep` |
| Azure OpenAI | Upstream LLM endpoint for `/chat` | Accessed with Kong's system-assigned managed identity |
| MCP Server | Implements SSE transport and tool registration | Node.js 22, `@modelcontextprotocol/sdk`, `/mcp/sse`, `/mcp/messages`, `/health` |
| Mock API | Simple backend for demo tools | Node.js + Express, `/api/weather`, `/api/calculate`, `/api/status` |
| Azure Container Registry | Stores Kong, MCP server, and Mock API images | Built via `az acr build` |
| Container Apps Environment | Shared runtime and internal DNS boundary | Hosts Kong, MCP server, and Mock API |
| Log Analytics | Platform log sink | Configured in `infra/acr.bicep` |

### Kong configuration summary

- **Public route:** `POST /chat`
- **MCP routes:** `GET /mcp/sse`, `POST /mcp/messages`
- **Chat plugins:** `jwt`, `post-function`, `rate-limiting`, `cors`
- **MCP plugins:** `jwt`, `cors`
- **SSE support:** proxy buffering off, read/send timeouts set to `600s`

### MCP server summary

- Server name returned by `initialize`: `mock-api-mcp-server`
- Tool set:
  - `get_weather`
  - `calculate`
- Health probe calls downstream Mock API status rather than just process health

### Mock API summary

- Internal-only ingress
- Randomized weather payload to prove live calls
- Strict validation for `calculate` to avoid invalid arithmetic responses

## Authentication

### Managed identity and JWT together

The system currently uses two auth patterns at the same time:

1. **Client-to-Kong authentication**
   - JWT bearer token
   - issuer: `kong-poc`
   - algorithm: `HS256`
   - secret: `poc-secret-change-me`
2. **Kong-to-Azure OpenAI authentication**
   - system-assigned managed identity on the Kong Container App
   - role: `Cognitive Services OpenAI User`

### Why the auth split matters

- `/chat` uses client JWTs only as a gateway access control mechanism; Azure OpenAI never sees that token.
- `/mcp/*` currently uses the same JWT validation model, but the downstream MCP server and Mock API are trusted internal hops.
- Production will likely need stronger client identity separation for Foundry than the shared POC consumer model.

## Network Topology

### External vs internal ingress

- **Kong:** external ingress enabled; the only internet-facing application
- **MCP Server:** internal ingress only
- **Mock API:** internal ingress only

### DNS resolution

- Azure Container Apps provides internal DNS names for services in the same environment.
- Kong must target the **internal ingress FQDN over HTTPS** for the MCP server:
  - `https://kongai-mcp-server.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io`
- The MCP server calls the Mock API through its internal FQDN:
  - `https://kongai-mock-api.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io`

### Why internal HTTPS matters

Using the ACA internal ingress FQDN over HTTPS is the validated path for service-to-service routing in this environment. Direct port-based HTTP access was specifically rejected because it caused the MCP route to hang before the server saw the request.

## Deployment Process

The current deploy flow is implemented by `scripts/deploy-simple.sh`.

### Build → Deploy → Validate workflow

1. **Phase 1 — shared infrastructure**
   - deploy `infra/acr.bicep`
   - creates:
     - Azure Container Registry
     - Log Analytics workspace
     - Container Apps Environment
2. **Phase 2 — Kong image build**
   - `az acr build --image kong-ai-gw:<tag> .`
3. **Phase 2.5 — Mock API**
   - build image from `.\mock-api`
   - deploy `infra/mock-api.bicep`
4. **Phase 2.6 — MCP Server**
   - build image from `.\mcp-server`
   - deploy `infra/mcp-server.bicep`
   - inject `MOCK_API_URL`
5. **Phase 3 — Kong app deployment**
   - deploy `infra/main.bicep`
   - point Kong at the previously built image
6. **Validation**
   - run `bash test/test-mcp-gateway.sh`
   - confirm `10/10` pass
   - optionally run the PowerShell variant in `test\test-mcp-gateway.ps1`

## Validation Status

Validated today:

- SSE handshake works through Kong
- `tools/list` returns `get_weather` and `calculate`
- both tools execute successfully end to end
- Azure OpenAI `/chat` flow still succeeds
- Bash gateway suite passes `10/10`

## Key Decisions

These docs reflect the following implemented decisions:

1. **Deploy flow split to avoid stock-image startup failure**
   - Reference: `.squad/decisions/decisions.md`
   - Result: ACR and environment are provisioned before Container Apps are created.
2. **Mock API remains internal-only**
   - Reference: `.squad/decisions/decisions.md`
   - Result: the backend tool service is not internet-exposed.
3. **MCP uses legacy SSE plus companion POST endpoint**
   - Reference: `.squad/decisions/decisions.md`
   - Result: clients must open `/mcp/sse` and then post to `/mcp/messages?sessionId=...`.
4. **Kong targets ACA internal ingress over HTTPS**
   - Reference: `.squad/decisions.md`
   - Result: `https://<app>.internal...` is the supported routing pattern for the MCP upstream.

## Production Considerations

- Replace the shared JWT secret and move signing keys to managed storage.
- Add per-client rate limits and connection limits for MCP traffic.
- Add Application Insights or equivalent observability for Kong and both internal services.
- Review ACA scaling thresholds for long-lived SSE connections.
- Consider enabling the Kong Admin API only on an internal-only port for operational debugging.

## Related Files

- `README.md`
- `kong.yaml`
- `infra\acr.bicep`
- `infra\main.bicep`
- `infra\mock-api.bicep`
- `infra\mcp-server.bicep`
- `scripts\deploy-simple.sh`
- `test\README.md`
