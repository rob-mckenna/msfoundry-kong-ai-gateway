# Keaton — History

## Project Context
- **Project:** Kong AI Gateway on Azure Container Apps
- **Stack:** Kong 3.7 (DB-less), Bicep IaC, Azure Container Apps, ACR, Bash deploy scripts
- **Goal:** Deploy Kong as an AI proxy for Microsoft Foundry models
- **User:** Rob McKenna

## Learnings

### 2026-06-16T18:32:09-04:00 — ACA Deployment Readiness Review

- Reviewed all five input artifacts (Dockerfile, kong.yaml, main.bicep, deploy.sh, deploy-simple.sh, README).
- **Two P0 blockers identified:** global JWT plugin (no consumers → 401 on all traffic) and missing RBAC propagation delay in deploy scripts (ACR pull will fail on first run).
- **Bicep and Dockerfile are solid** — system-assigned identity + AcrPull role, health probes on status port 8100, DB-less config all correct.
- **`${OPENAI_API_KEY}` in kong.yaml plugin config** will not be interpolated by Kong — noted as P2 since OpenAI upstream is a placeholder anyway.
- Decisions document written to `.squad/decisions/inbox/keaton-aca-deployment-plan.md`.
- Next step: assign P0/P1 fixes to McManus.
