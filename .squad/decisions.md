# Squad Decisions

## Active Decisions

### Decision 1: JWT Plugin Scoped to Chat Service + POC Consumer Added
**Author:** Fenster (API/Gateway Dev)  
**Date:** 2026-06-16T18:38:14-04:00  
**Status:** Proposed — awaiting Keaton review

**Context:** Keaton's ACA deployment assessment flagged a P0 blocker: the JWT plugin was declared in the global `plugins:` block with no consumers defined, causing Kong to return HTTP 401 on every proxied request.

**Decision:**
1. **Remove global JWT plugin.** The top-level `plugins:` section has been deleted from `kong.yaml`.
2. **Scope JWT to the `chat` service.** The `jwt` plugin entry now lives inside `services[chat].plugins[]`. It applies only to the `/chat` route. Any future routes (health checks, new model endpoints) will not inherit JWT enforcement unless explicitly added.
3. **Add a POC consumer with HS256 credential:**
   - Consumer username: `poc-user`
   - JWT key (issuer): `kong-poc`
   - Algorithm: `HS256`
   - Secret: `poc-secret-change-me` ← must be rotated before any non-local deployment

**Rationale:** Kong's JWT plugin requires at least one consumer with a matching credential in order to validate tokens. Service-level scope is the right granularity — easier to maintain as routes are added. Global JWT was too broad for a gateway that will eventually expose unauthenticated internal endpoints (e.g., a future `/health` passthrough).

**Follow-up Required:**
- [ ] Rotate `poc-secret-change-me` before any deployment beyond local Docker testing.
- [ ] Define real consumer/credential strategy (Azure AD tokens? API key + JWT bridge?) before the Foundry integration milestone.
- [ ] Consider moving credentials to a secrets manager and using `envsubst` at container startup.

---

### Decision 2: ACA Deployment Readiness Assessment
**Author:** Keaton (Lead)  
**Date:** 2026-06-16T18:32:09-04:00  
**Status:** Draft — pending team review

**TL;DR:** Two P0 issues will prevent successful first deployment:
1. The global JWT plugin blocks all traffic (fixed by Decision 1).
2. The deploy script has no RBAC propagation delay for ACR image pull.

**What's Already Solid:**
- Dockerfile: Correct for DB-less Kong 3.7 with proper env vars and health endpoint.
- Bicep: Well-structured system-assigned identity + AcrPull role, Log Analytics wired correctly.
- kong.yaml structure: Valid for Kong 3.7. Service/route/plugin hierarchy is sound.
- deploy-simple.sh flow: Correct sequence overall.

**Blockers (Must Fix Before First Deploy):**

**BLOCKER 1 — Global JWT Plugin with No Consumers**  
Resolved by Decision 1.

**BLOCKER 2 — RBAC Propagation Delay in Deploy Script**  
Azure RBAC role assignments take 1–3 minutes to propagate. Deploy script must insert a 90-second sleep between Bicep deployment and ACR login/docker push to avoid image pull failures.

**Significant Issues (Won't Block First Deploy):**

**ISSUE 1 — `${OPENAI_API_KEY}` Interpolation**  
Kong's DB-less config does not perform shell-style substitution inside plugin configs. Deferred until actual upstream (Foundry) integration. Options: (a) startup script with envsubst, (b) custom plugin, (c) static config pass-through.

**ISSUE 2 — Health Probe `initialDelaySeconds: 30` May Be Too Short**  
Kong on cold ACA can take 20–40s to initialize. Increase to 60 seconds for both liveness and readiness probes. (McManus implementing in Decision 3.)

**ISSUE 3 — `deploy.sh` and `deploy-simple.sh` Are Near-Identical**  
Consolidate to `deploy-simple.sh` and delete `deploy.sh`.

**Prioritized Work Items:**
| Priority | Item | Owner |
|---|---|---|
| **P0** | Remove/scope global JWT plugin from kong.yaml | Fenster (Done — Decision 1) |
| **P0** | Add RBAC propagation delay (90s sleep) to deploy scripts | McManus |
| **P1** | Increase health probe initialDelaySeconds to 60 in Bicep | McManus (Done — Decision 3) |
| **P1** | Consolidate deploy.sh → deploy-simple.sh, update README | McManus |
| **P2** | Design envsubst or equivalent for plugin config env vars | Keaton (arch) + Fenster |

---

### Decision 3: Infra Fixes — Bicep + Deploy Script Updates
**Author:** McManus (Infra/Cloud Dev)  
**Date:** 2026-06-16T18:32:09-04:00  
**Status:** In Progress

**Changes Already Applied:**
| File | Change |
|---|---|
| `infra/main.bicep` | `roleAssignments` API version: `2020-04-01-preview` → `2022-04-01` (stable) |
| `scripts/deploy.sh` | Added `--name kongai-deploy` to deployment create; read outputs from named deployment instead of fragile list lookup; added `sleep 60` for RBAC propagation |
| `scripts/deploy-simple.sh` | Same changes as deploy.sh |
| `infra/main.bicep` | Increased health probe `initialDelaySeconds` from 30 to 60 (both liveness and readiness) |

**Implementation Notes:**
- RBAC delay fixes both `deploy.sh` and `deploy-simple.sh`.
- Health probe tuning addresses cold-start initialization window for Kong config parsing.
- API version bump to stable version aligns with Azure best practices.

---

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
