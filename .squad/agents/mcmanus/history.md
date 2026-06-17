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
