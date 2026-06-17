# Decisions Log

## Decision: Restructure Deploy Flow to Fix Chicken-and-Egg Image Problem

**Date:** 2026-06-16  
**Author:** McManus  
**Status:** Implemented

### Problem

The single-Bicep deploy was failing with `ContainerAppOperationError: Operation expired`.

Root cause: `infra/main.bicep` fell back to `kong:3.7` (stock image) when no `containerImage` param was provided. The Container App started with that image, but `KONG_DECLARATIVE_CONFIG=/etc/kong/kong.yaml` pointed to a file that only exists in our custom Dockerfile build. Kong crashed, the health probe failed, and the ARM deployment timed out.

This was a chicken-and-egg: ACR had to exist before we could push the custom image, but the Container App needed the custom image to start.

### Decision

Split the deploy into three phases and eliminate the stock-image fallback:

#### Phase 1 — `infra/acr.bicep`
Deploys ACR, Log Analytics workspace, and Container App Environment. No container app. Outputs: `acrName`, `acrLoginServer`, `containerAppEnvId`.

#### Phase 2 — `az acr build`
Runs a cloud-side image build. Uploads the local Dockerfile context to ACR and builds inside Azure. **No local Docker daemon required.** The custom image (with `kong.yaml` baked in) is pushed to ACR before the container app is ever created.

#### Phase 3 — `infra/main.bicep`
Deploys the Container App with `containerImage` as a **required parameter** (no fallback). Also creates the ACR Pull role assignment for the app's system-assigned identity in the same deployment.

### Changes

| File | Change |
|------|--------|
| `infra/acr.bicep` | New — ACR + Log Analytics + Container App Environment |
| `infra/main.bicep` | Updated — Container App only; `containerImage` required param; ACR/LAW/env resources removed |
| `scripts/deploy-simple.sh` | Rewritten with 3-phase flow; removed `docker build/push`; uses `az acr build` |
| `scripts/deploy.sh` | Deleted — consolidated into deploy-simple.sh |
| `README.md` | Updated prereqs (no local Docker), updated deploy instructions |

### Why `az acr build` Over Local Docker

- No local Docker daemon requirement — works from any shell including Cloud Shell
- Reduces POC setup friction
- Build happens closer to the registry (no push latency)

### RBAC Propagation

The ACR Pull role assignment is created in the same Phase 3 deployment as the Container App. Because Kong's startup takes 60+ seconds (probes set to `initialDelaySeconds: 60`), there is sufficient runway for the role assignment to propagate before the first image pull is attempted.

---

## Decision: Mock API Implementation

**Author:** McManus (Infra/Cloud Dev)  
**Date:** 2026-06-17T04:24:00Z  
**Status:** Implemented (Phase 1 of Decision 5 — MCP Gateway Architecture)

### Context

Per Decision 5 (approved by Rob McKenna), we need a simple REST API backend that will be wrapped by the MCP Server as MCP tools. This is Phase 1 of the MCP Gateway implementation.

### Implementation Decisions

#### 1. Internal-Only Ingress
**Decision:** Set `ingress.external = false` in mock-api.bicep

**Rationale:**
- Mock API is a **backend service** — should never be internet-facing
- Only the MCP Server (also internal) needs to reach it
- Container App Environment DNS provides automatic service discovery for internal apps
- Reduces attack surface and eliminates need for network security rules

**Technical note:** Internal ingress means the FQDN is only resolvable within the Container App Environment. External clients (including Kong's external ingress) cannot reach it directly.

#### 2. Health Probe Timing: 30 seconds (not 60)
**Decision:** Set `initialDelaySeconds: 30` for both liveness and readiness probes

**Rationale:**
- Node.js + Express.js cold start is <5 seconds
- Kong requires 60s because it parses heavy declarative config on startup
- Mock API has no config parsing — only npm package loading
- 30s provides 6x safety margin without delaying replica readiness

**Comparison with Kong:**
| App | Startup Time | Probe Delay | Safety Margin |
|-----|--------------|-------------|---------------|
| Kong | ~30-40s | 60s | 1.5-2x |
| Mock API | ~3-5s | 30s | 6-10x |

#### 3. Minimal Resource Allocation
**Decision:** 0.25 CPU, 0.5Gi memory (vs. Kong's 0.5 CPU, 1Gi)

**Rationale:**
- Mock API is stateless, synchronous, no database
- Express.js overhead is ~50MB resident memory
- Three simple endpoints (weather, calculate, status) with no external calls
- Lower resource allocation = faster cold start and lower cost

**Scaling config:** 1-3 replicas with HTTP rule at 100 concurrent requests (vs. Kong's 50). Mock API endpoints are faster than proxied AI model calls.

#### 4. Randomized Weather Data (Not Fixed)
**Decision:** Weather endpoint returns randomized temperature/condition on each request

**Rationale:**
- Makes testing more realistic (simulates live data source)
- Easier to verify MCP Gateway is actually calling the API (vs. cached response)
- No added complexity — just array indexing with Math.random()

**Example outputs:**
```json
// Request 1
{"location": "Seattle", "temperature": 55, "condition": "Cloudy", "humidity": 75}

// Request 2 (same location, different data)
{"location": "Seattle", "temperature": 70, "condition": "Sunny", "humidity": 60}
```

#### 5. Calculation Validation (Strict)
**Decision:** Reject invalid operations and non-numeric inputs with HTTP 400

**Rationale:**
- Provides clear error messages for MCP tool debugging
- Prevents NaN/undefined propagation into Foundry model responses
- Validates contract between MCP Server and Mock API

**Valid operations:** `add`, `subtract`, `multiply` (no `divide` to avoid divide-by-zero edge case during POC)

### Files Created

| File | Purpose |
|------|---------|
| `mock-api/package.json` | Dependency manifest (Express.js 4.18, Node 22 engine) |
| `mock-api/server.js` | Express app with 3 REST endpoints + error handling |
| `mock-api/Dockerfile` | Node 22 Alpine, npm install --omit=dev, non-root user |
| `mock-api/.dockerignore` | Exclude node_modules, git files from image build |
| `infra/mock-api.bicep` | Container App deployment (internal ingress, health probes) |
| `scripts/deploy-simple.sh` | Updated with Phase 2.5 (Mock API build + deploy) |

### Deployment Integration

**Phase 2.5 added to deploy-simple.sh:**
1. `az acr build --image mock-api:1.0 ./mock-api` — Cloud-side image build
2. `az deployment group create -f infra/mock-api.bicep` — Bicep deployment
3. Capture internal FQDN output: `<app-name>.internal.<env-dns-suffix>`

**Execution order:**
```
Phase 1: ACR + Log Analytics + Container App Environment
Phase 2: Kong image build
Phase 2.5: Mock API image build + deploy ← NEW
Phase 3: Kong Container App deploy
```

### Next Steps (Not in This Task)

- [ ] **Phase 2:** Build MCP Server Container App (uses `@modelcontextprotocol/sdk`)
- [ ] **Phase 3:** Add Kong routes for `/mcp/*` path (route to MCP Server internal FQDN)
- [ ] **Phase 4:** Configure Kong for SSE streaming (disable buffering, extend timeout)

### Testing Guidance (For Future Validation)

When Mock API is deployed, validate with:

```bash
# From within Container App Environment (e.g., from MCP Server container)
MOCK_API_FQDN="<captured from deployment output>"

# Health check
curl http://$MOCK_API_FQDN/api/status

# Weather
curl "http://$MOCK_API_FQDN/api/weather?location=Seattle"

# Calculate
curl -X POST http://$MOCK_API_FQDN/api/calculate \
  -H "Content-Type: application/json" \
  -d '{"operation":"add","a":10,"b":20}'
```

**Expected:** All return 200 OK with JSON payloads. Status includes uptime. Weather/calculate return valid mock data.

### Team Impact

- **Fenster:** No Kong config changes in Phase 1 (routes added in Phase 3)
- **Cordova (future MCP Server work):** Mock API FQDN will be passed as env var to MCP Server
- **Keaton:** Phase 1 complete; ready for review before Phase 2 kickoff

---

## Decision: MCP Server Transport Implementation

**Author:** Fenster (API/Gateway Dev)  
**Date:** 2026-06-17T04:46:00Z  
**Status:** Implemented (Phase 2 of Decision 5 — MCP Gateway Architecture)

### Context

Decision 5 requires the Phase 2 MCP Server to expose the Model Context Protocol over SSE at `GET /mcp/sse`, wrap the Mock API as tools, and remain deployable as a standalone Container App.

### Implementation Decision

#### 1. Legacy SSE transport requires a companion POST endpoint
**Decision:** Implement `GET /mcp/sse` together with `POST /mcp/messages`

**Rationale:**
- The approved endpoint shape explicitly calls for SSE, so the implementation uses `@modelcontextprotocol/sdk`'s `SSEServerTransport`
- In the SDK, the SSE stream only bootstraps the session; it emits an `endpoint` event containing the JSON-RPC POST target with `sessionId`
- Without the POST endpoint, clients can open the stream but cannot send `initialize`, `tools/list`, or `tools/call`

**Operational detail:** Kong Phase 3 should route both `/mcp/sse` and `/mcp/messages` to the MCP Server, not just the SSE bootstrap route.

#### 2. Health probe validates downstream reachability
**Decision:** Make `/health` call the Mock API `/api/status` endpoint instead of returning a static process-only response

**Rationale:**
- Confirms the MCP server can actually reach its only upstream dependency
- Surfaces bad `MOCK_API_URL` configuration immediately during readiness/liveness checks
- Better matches the MCP server's real success criteria than a simple "process is running" probe

#### 3. Default upstream uses the deployed Mock API FQDN
**Decision:** Default `MOCK_API_URL` to `https://kongai-mock-api.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io`

**Rationale:**
- Matches the Phase 1 deployed target provided by Rob
- Keeps local/dev override simple while giving McManus a working default for the first Container App wiring pass
- Preserves the architecture decision that service discovery is environment-variable-driven rather than hardcoded in Kong

### Files Created

| File | Purpose |
|------|---------|
| `mcp-server/package.json` | Node 22 manifest with MCP SDK, Express, and Zod |
| `mcp-server/server.js` | Express-based MCP SSE server with tool registrations and Mock API proxying |
| `mcp-server/Dockerfile` | Node 22 Alpine container image for ACA deployment |
| `mcp-server/.dockerignore` | Excludes `node_modules` from image context |

### Validation

- `GET /health` succeeded locally with `MOCK_API_URL=http://127.0.0.1:3000`
- An SDK client connected to `http://127.0.0.1:8080/mcp/sse`
- `tools/list` returned `get_weather` and `calculate`
- Both tool calls completed successfully against the running Mock API

### Team Impact

- **McManus:** Phase 2 app is ready for infra wiring; deploy both `/mcp/sse` and `/mcp/messages` through the internal Container App ingress
- **Fenster (Phase 3):** Kong route work must include the companion POST endpoint for MCP message delivery
- **Keaton:** Approved SSE architecture is implemented without adding Bicep/deploy automation yet
