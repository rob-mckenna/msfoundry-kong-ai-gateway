# McManus — History

## Project Context
- **Project:** Kong AI Gateway on Azure Container Apps
- **Stack:** Kong 3.7 (DB-less), Bicep IaC, Azure Container Apps, ACR, Bash deploy scripts
- **Goal:** Deploy Kong as an AI proxy for Microsoft Foundry models
- **User:** Rob McKenna

## Key Files
- `infra/main.bicep` — ACA env + ACR + Log Analytics + Container App
- `scripts/deploy.sh` — Full deploy lifecycle (RG → Bicep → Docker build → push → update)
- `scripts/deploy-simple.sh` — Same with progress output
- `Dockerfile` — Kong 3.7, DB-less, bakes kong.yaml in

## Learnings

### 2026-06-16 — Initial infra validation

**Fixes applied directly:**
- `infra/main.bicep`: roleAssignments API version `2020-04-01-preview` → `2022-04-01`
- `scripts/deploy.sh` + `deploy-simple.sh`: Named deployment (`--name kongai-deploy`) replaces fragile `[-1]` list lookup; added `sleep 60` for RBAC propagation before `containerapp update`

**Flagged to decisions inbox:**
- `kong.yaml` global JWT plugin with no consumers is a **deploy blocker** — all traffic will 401 until Fenster addresses it
- Startup probe absent in Bicep — potential liveness restart loop if Kong init takes >30s; pending Keaton review

**Verified OK:**
- ACR Pull role assignment GUID, managed identity pattern, ingress config, Log Analytics wiring, env var secret injection, Kong 3.7 DB-less config

### 2026-06-16 — Deploy restructure: chicken-and-egg image fix

**Problem:** Deploying everything in one `main.bicep` caused `ContainerAppOperationError: Operation expired`. The stock `kong:3.7` fallback image crashed immediately because `KONG_DECLARATIVE_CONFIG=/etc/kong/kong.yaml` doesn't exist in the stock image — only in our custom build.

**Fixes applied:**
- Created `infra/acr.bicep`: ACR + Log Analytics + Container App Environment (no container app)
- Rewrote `infra/main.bicep`: Container App only; `containerImage` is now a **required param** with no stock-image fallback; takes `acrName` and `containerAppEnvId` as params
- Rewrote `scripts/deploy-simple.sh` as a 3-phase flow:
  1. `az deployment group create` → `infra/acr.bicep`
  2. `az acr build` (cloud-side build — no local Docker required)
  3. `az deployment group create` → `infra/main.bicep` with custom image URL
- Deleted `scripts/deploy.sh` (fully superseded by deploy-simple.sh)
- Updated `README.md`: removed Docker prereq, documented 3-phase flow
- Deleted `rg-kong-aca` resource group (was in bad state from failed deployment)

**Key lesson:** Never deploy a Container App with an image that references env vars pointing to files that don't exist in that image. ACR infra must be separated from Container App deployment so the custom image can be built first.

- **Fix applied:** `infra/main.bicep` liveness and readiness probes — bumped `initialDelaySeconds` from 30 to 60 (lines 136, 146)
- **Reason:** Kong takes 30–40s to initialize on cold Container Apps replicas; original 30s timeout caused restart loops. Extended to 60s prevents premature failure detection during startup.

### 2026-06-17 — GitHub Actions CI/CD Workflow & Deployment Automation

**Outcome:** Created `.github/workflows/deploy.yml` — comprehensive 3-phase GitHub Actions pipeline.

**Pattern learned:** Federated OIDC identity with Azure — eliminates stored secrets, leverages GitHub's OIDC provider token to mint short-lived Azure credentials at runtime.

**Implementation details:**
- **Phase 1 (Build & Test):** Unit tests + `az acr build` (cloud-side image build, no local Docker)
- **Phase 2 (Staging Deploy):** `az containerapp update` to staging environment with health probe verification
- **Phase 3 (Production Deploy):** Manual approval gate, production deploy with artifact retention (30 days)
- **Authentication:** `azure/login@v1` with GitHub OIDC token, no stored secrets in GitHub
- **Environment Variables:** Staging/prod environments mapped to separate ACA apps; secrets pulled from Azure Key Vault at runtime

**Key insight:** OIDC federated identity is enterprise-grade for GitHub → Azure workflows — simpler than service principal management and aligns with platform team security posture.

### 2026-06-17 — Mock API Container App (Phase 1 of MCP Gateway)

**Outcome:** Built complete Mock API infrastructure per Decision 5 (MCP Gateway Architecture).

**Files created:**
- `mock-api/package.json` — Express.js 4.18 with Node 22 engine requirement
- `mock-api/server.js` — Express app with 3 REST endpoints:
  - `GET /api/weather?location=<city>` (randomized mock weather data)
  - `POST /api/calculate` (validates operation: add/subtract/multiply; validates numeric inputs)
  - `GET /api/status` (health check with uptime)
- `mock-api/Dockerfile` — Node 22 Alpine base, npm install --omit=dev, runs as non-root user
- `mock-api/.dockerignore` — Excludes node_modules, git files
- `infra/mock-api.bicep` — Container App deployment:
  - Internal-only ingress (`external: false`)
  - Minimal resources (0.25 CPU, 0.5Gi memory)
  - Health probes on `/api/status` (30s initial delay)
  - Scale 1-3 replicas based on concurrent requests (max 100)
- `scripts/deploy-simple.sh` — Added Phase 2.5:
  - `az acr build` for Mock API image (`mock-api:1.0`)
  - Bicep deployment with internal FQDN output
  - Summary reports both Kong Gateway and Mock API FQDNs

**Key patterns learned:**
- **Internal ingress** (`external: false`) ensures Mock API is accessible only from Container App Environment — crucial for internal backend services that should never be internet-facing
- **30s health probe delay** is sufficient for Node.js Express.js apps (vs. 60s for Kong which has heavier config parsing)
- **Logging to stdout** for Container Apps simplicity — all `console.log()` output flows to Log Analytics automatically
- **Lower scaling concurrency threshold** (100 vs. 50 for Kong) because Mock API endpoints are synchronous, low-latency operations

**Follow-up required:**
- Phase 2: Build MCP Server Container App (wraps Mock API endpoints as MCP tools)
- Phase 3: Add Kong routes for `/mcp/*` path-based routing to MCP Server
- Phase 4: Configure SSE-optimized Kong settings (disable buffering, extend timeout)

### 2026-06-17T04:27:00Z — Scribe: Orchestration & Documentation
**Task:** Archive decisions (33,457 bytes), log Phase 1 Mock API completion.

**Completed:**
- Archived decisions.md → decisions_archive/2026-06-17T042700Z-decisions.md
- Reset decisions.md to empty template
- Wrote orchestration log: 2026-06-17T042700Z-mcmanus.md
- Wrote session log: 2026-06-17T042700Z-mock-api-phase1.md
- Appended to McManus history

