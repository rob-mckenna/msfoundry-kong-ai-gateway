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
