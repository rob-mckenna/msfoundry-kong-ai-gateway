# POC Completion Status

_Assessed: 2026-06-18_

## Executive summary

The core platform work is complete. Kong, Konnect, Azure OpenAI proxying, MCP routing, Entra registrations, and the parallel JWT + OAuth route design are all in place. The main work left is **Foundry-side configuration and live end-to-end validation**, especially for the OAuth user-consent path.

## What is complete

### Infrastructure

- [x] Kong Gateway deployed on Azure Container Apps
- [x] Konnect control plane and data plane configured
- [x] Azure OpenAI `/chat` proxy working
- [x] Internal MCP Server and Mock API deployed
- [x] ACA internal HTTPS routing validated

### Authentication and routing

- [x] JWT-based MCP route family working:
  - `GET /mcp/sse`
  - `POST /mcp/messages`
- [x] OAuth-based MCP route family configured:
  - `GET /mcp/oauth/sse`
  - `POST /mcp/oauth/messages`
- [x] Entra app registrations created for custom OAuth
- [x] MCP server supports public message-path override needed for the OAuth route family

### Validation already completed

- [x] JWT regression suite passes `10/10`
- [x] Azure OpenAI `/chat` flow passes in the same regression suite
- [x] OAuth route protection behavior documented and partially validated:
  - unauthenticated requests rejected
  - invalid tokens rejected
  - JWT baseline preserved

## What is still left to configure

## 1. Foundry project configuration

This is now the primary remaining setup step.

- [ ] Create a Foundry MCP connection for the **JWT** path
- [ ] Create a Foundry MCP connection for the **OAuth** path
- [ ] Attach one or both connections to the target Foundry agent/project
- [ ] Save the working project connection IDs in the demo runbook

Recommended operator pattern:

1. Configure **JWT first** as the baseline
2. Confirm it works
3. Configure **OAuth second**
4. Validate both side by side

See `docs/foundry-final-configuration.md`.

## 2. Live end-to-end Foundry testing

This is the biggest remaining validation gap.

- [ ] Confirm Foundry discovers `get_weather`
- [ ] Confirm Foundry discovers `calculate`
- [ ] Run the weather prompt successfully through the **JWT** tool
- [ ] Run the calculate prompt successfully through the **JWT** tool
- [ ] Complete user sign-in and consent for the **OAuth** tool
- [ ] Run the same prompts successfully through the **OAuth** tool

What is already known:

- JWT route family is validated outside Foundry
- OAuth route family is configured and protected
- real browser-driven OAuth success still needs to be proven from Foundry

## 3. Demo evidence capture

Before calling the POC fully finished, capture:

- [ ] screenshot or notes showing the JWT connection configured in Foundry
- [ ] screenshot or notes showing the OAuth connection configured in Foundry
- [ ] one successful JWT-backed prompt result
- [ ] one successful OAuth-backed prompt result

## Configuration gaps that do **not** appear to block the POC

### Networking / firewall

No additional gateway networking changes appear required for the default ACA-hosted demo. The important requirement is simply that Foundry can reach:

- `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/sse`
- `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/oauth/sse`

### DNS / TLS

No extra DNS or certificate work is required for the default ACA domain:

- ACA already provides the public hostname and TLS termination
- internal MCP and Mock API traffic remains private inside the ACA environment

Custom DNS and custom certificates are only needed if Rob wants a branded public URL later.

## Optional enhancements

These are useful, but not required to demo the POC:

- [ ] Konga or other operator UI
- [ ] Stronger monitoring and alerting for Kong, MCP, and Mock API
- [ ] Route-specific rate limiting for long-lived MCP traffic
- [ ] Additional Azure OpenAI models or routes
- [ ] Secret rotation and Key Vault-backed JWT signing material
- [ ] Better observability for forwarded OAuth user identity headers
- [ ] Production-grade Foundry credential rotation process

## Recommended next steps

## Fastest path to a complete demo

1. Generate a fresh JWT with `.\scripts\generate-foundry-jwt.ps1`
2. Configure the **JWT** Foundry connection and validate it first
3. Configure the **OAuth** Foundry connection from local `entra-oauth-config.json`
4. Complete a real OAuth sign-in / consent flow in Foundry
5. Run the same prompt through both connections and compare the behavior

## Demo messaging recommendation

Use this framing:

- **JWT path** = current working baseline and fallback
- **OAuth path** = upgraded identity-preserving path

That gives Rob a stable demo even if OAuth consent behavior needs one more troubleshooting pass.

## POC completion call

### Current status

**Platform build:** complete  
**Gateway configuration:** complete  
**Konnect migration:** complete  
**OAuth route implementation:** complete  
**Foundry configuration:** pending manual setup  
**Foundry end-to-end validation:** pending final manual test

## Bottom line

The repo looks **POC-ready but not fully demo-closed**. What remains is mostly manual Foundry work: configure the two Foundry connections, run a real OAuth consent flow, and capture the end-to-end evidence.
