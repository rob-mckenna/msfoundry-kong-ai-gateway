# Keaton — History

## Project Context
- **Project:** Kong AI Gateway on Azure Container Apps
- **Stack:** Kong 3.7 (DB-less), Bicep IaC, Azure Container Apps, ACR, Bash deploy scripts
- **Goal:** Deploy Kong as an AI proxy for Microsoft Foundry models
- **User:** Rob McKenna

## Learnings

### 2026-06-17T08:33:31-04:00 — Foundry Auth Automation

- Mapped the current Kong MCP Gateway JWT pattern directly to **Foundry key-based authentication**: `Authorization: Bearer <jwt>` stored in the Foundry project connection.
- Added operator docs: `docs/foundry-auth-analysis.md` for option analysis and `docs/foundry-setup-guide.md` for Foundry portal setup, validation, and troubleshooting.
- Added reusable JWT generators at `scripts/generate-foundry-jwt.sh` and `scripts/generate-foundry-jwt.ps1`, both using PyJWT with env var overrides for issuer, secret, TTL, and optional subject.
- Recommendation for this phase: keep shared key-based auth for POC validation, and treat OAuth passthrough / Entra auth as production enhancements depending on whether user identity or secretless workload identity is needed.

### 2026-06-17T07:03:00Z — Phase 4 Foundry Documentation

- Added Phase 4 documentation to `README.md` plus two detailed guides: `docs/foundry-integration.md` and `docs/architecture.md`.
- Documented the validated Foundry integration shape as **generic MCP client guidance** rather than UI-specific steps, because Foundry surface details were not provided.
- Captured the critical protocol requirement that clients must open `GET /mcp/sse`, preserve the returned `sessionId`, and send authenticated JSON-RPC messages to `POST /mcp/messages?sessionId=...`.
- Updated `test/README.md` with Foundry-specific validation scenarios so the existing 10/10 gateway suite can be reused as the pre-Foundry baseline.

### 2026-06-16T18:32:09-04:00 — ACA Deployment Readiness Review

- Reviewed all five input artifacts (Dockerfile, kong.yaml, main.bicep, deploy.sh, deploy-simple.sh, README).
- **Two P0 blockers identified:** global JWT plugin (no consumers → 401 on all traffic) and missing RBAC propagation delay in deploy scripts (ACR pull will fail on first run).
- **Bicep and Dockerfile are solid** — system-assigned identity + AcrPull role, health probes on status port 8100, DB-less config all correct.
- **`${OPENAI_API_KEY}` in kong.yaml plugin config** will not be interpolated by Kong — noted as P2 since OpenAI upstream is a placeholder anyway.
- Decisions document written to `.squad/decisions/inbox/keaton-aca-deployment-plan.md`.
- Next step: assign P0/P1 fixes to McManus.

### 2026-06-17 — README Rewrite for POC Completion

**Outcome:** Rewrote `README.md` with comprehensive documentation covering architecture, deployment, testing, and troubleshooting.

**Scope:**
- **Architecture section:** ASCII diagram showing Kong (DB-less, declarative config) → API Gateway → ACA + ACR topology
- **Prerequisites:** Updated for cloud-native flow (no local Docker; uses `az acr build` instead)
- **Deploy instructions:** Step-by-step 3-phase flow with command walkthroughs, example outputs, RBAC propagation timing notes
- **Testing section:** Local unit test commands (`npm test`), post-deploy smoke tests (curl against Kong health endpoint)
- **Project structure:** Directory layout with descriptions of Bicep files, scripts, Dockerfile, configuration
- **Troubleshooting:** Common issues (image pull failures, 401 unauthorized, health probe timeout, ARM deployment timeout) and resolution paths
- **Environment variables:** Full list of Kong config vars, Azure env vars, and guidance on secret injection via Key Vault

**Key documentation pattern:** Separated local dev testing from cloud deployment testing — made it clear that users can validate Kong config locally before cloud deploy, reducing iteration friction.

**Quality check:** All commands tested, all paths verified, no broken references to deleted files (e.g., deploy.sh).

### 2026-06-17T05:43:00Z — MCP Gateway Routes Complete (Fenster)

**Team Update:** Kong MCP Gateway routing is now fully operational. Fenster completed integration with standalone MCP Server.

**What changed:**
- Kong routes configured for `/mcp/sse` (SSE streaming) and `/mcp/messages` (tool calls)
- Critical resolution: Kong upstream must use ACA internal ingress FQDN with HTTPS (`https://kongai-mcp-server.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io`), not port-direct HTTP
- Kong proxy timeout directives require full Nginx names: `KONG_NGINX_PROXY_PROXY_READ_TIMEOUT` and `KONG_NGINX_PROXY_PROXY_SEND_TIMEOUT`

**For Phase 4 (your work):**
- README needs section documenting `/mcp/*` routes and MCP integration
- Squad member discovery workflow can now route SSE and tool calls through Kong
- Decision recorded: Kong internal ACA routing pattern for future reference

### 2026-06-17T06:08:00Z — MCP Gateway Test Suite Complete (Hockney)

**Team Update:** Full test suite for MCP Gateway is now operational and integrated.

**What changed:**
- Bash test suite: 10/10 pass (fully operational)
- PowerShell test suite: 6/10 pass (timing-related, server logs confirm tool execution)
- Test files committed: `test/test-mcp-gateway.sh`, `test/test-mcp-gateway.ps1`, `test/README.md`
- Commit 21ccb2c includes Phase 2.5 (MCP Server deployment) + Phase 3 (Kong MCP Gateway) + tests

**For Phase 4 (your work):**
- Phase 3 is now **COMPLETE AND VALIDATED**
- README can reference existing test suite for verification instructions
- Phase 4 unblocked: README update and final integration documentation

### 2026-06-17T14:32:13-04:00 — OAuth Passthrough Parallel Auth Design

- Designed the OAuth identity passthrough plan to run **in parallel** with the current key-based JWT MCP flow rather than replacing it.
- Recommended preserving the current JWT endpoints as the baseline demo and adding a second OAuth route family (`/mcp/oauth/sse` + `/mcp/oauth/messages`) for side-by-side validation.
- Chose **custom Microsoft Entra OAuth** with a **custom audience** because Foundry will not pass Microsoft-scoped managed OAuth tokens to an untrusted custom MCP endpoint.
- Recommended **OIDC JWT validation** at Kong for the OAuth route, while noting the current `kong:3.7` OSS image does not include Kong's Enterprise `openid-connect` plugin.
- Captured the key implementation dependency that the MCP server currently advertises `/mcp/messages`, so the server needs a small public-path configuration enhancement to support a second OAuth message endpoint cleanly.
- Added four operator docs under `docs/` plus the design decision in `.squad/decisions/inbox/keaton-oauth-passthrough-design.md`.
