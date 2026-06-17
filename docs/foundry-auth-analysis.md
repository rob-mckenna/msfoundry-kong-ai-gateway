# Foundry Authentication Analysis for Kong MCP Gateway

## Executive Summary

Our current Kong MCP Gateway authentication model is a **shared HS256 JWT** validated by the Kong `jwt` plugin. In Microsoft Foundry terms, that maps directly to **key-based authentication** because Foundry stores a reusable credential in the project connection and sends it as a header on each MCP request.

**Recommendation:** keep the current gateway on **Foundry key-based authentication** for POC validation, and automate token generation for the Foundry project connection. Document **OAuth identity passthrough** and **Microsoft Entra authentication** as production-focused follow-on options if we need per-user identity or secretless service identity.

## Current Gateway State

- Public SSE endpoint: `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/sse`
- Companion message endpoint: `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/messages`
- Auth mechanism: Kong `jwt` plugin on the MCP service
- Algorithm: `HS256`
- Required JWT claims:
  - `iss=kong-poc`
  - `exp=<unix timestamp>`
  - optional `sub=<subject>`
- Current shared secret: `poc-secret-change-me`
- User context: **none**; all callers share the same gateway identity

## Foundry Authentication Mapping

### 1. Key-based authentication

**Fit with current gateway:** **Direct match**

Foundry key-based auth stores a credential in the project connection and replays it when it connects to the MCP server. Our Kong gateway expects exactly that pattern today:

- **Credential name:** `Authorization`
- **Credential value:** `Bearer <jwt>`
- **Project connection behavior:** shared identity for all users of that connection

This is the best fit for the current design because Kong validates a bearer token, not a per-user delegated identity.

### 2. Microsoft Entra authentication

**Fit with current gateway:** **Not currently supported**

Foundry can use an agent identity or managed identity and handle token rotation automatically, but our Kong gateway does not currently validate Entra-issued tokens. The existing `jwt` plugin configuration expects a shared HS256 token whose `iss` matches `kong-poc`.

### 3. OAuth identity passthrough

**Fit with current gateway:** **Not currently supported**

OAuth passthrough preserves end-user identity and consent, but our gateway does not currently accept or validate user-delegated OAuth access tokens. It also does not propagate user context downstream.

### 4. Unauthenticated access

**Fit with current gateway:** **Intentionally unsupported**

The gateway is configured to require JWT auth on MCP routes. Disabling auth would simplify Foundry setup but would weaken the current design and is not recommended even for this POC.

## Recommended Path

### Recommendation for this project

**Use Foundry key-based authentication with generated JWTs.**

Why:

1. **No Kong changes required** — it matches the deployed gateway today.
2. **Fastest path to validation** — only the Foundry project connection and agent config need to be supplied.
3. **Matches current trust model** — a shared service identity is acceptable for the current POC.
4. **Automatable immediately** — token generation can be scripted without changing Azure resources or Kong config.

### What Foundry should store

- `server_url`: `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/sse`
- `server_label`: any operator-friendly label, e.g. `kong-mcp-gateway-poc`
- `require_approval`: choose based on agent policy, typically `true` for early testing
- `project_connection_id`: the ID of the Foundry project connection created for this gateway
- Project connection credential:
  - name: `Authorization`
  - value: `Bearer <generated-jwt-token>`

## Gap Analysis by Authentication Option

### Option 1 — Stay on key-based auth

**Gateway changes required:** none for POC

**Automation we can provide now:**

- JWT generation scripts for Bash and PowerShell
- Setup guide for Foundry project connections and agent config
- Validation guidance using the existing MCP gateway test suite

**Remaining gaps for production:**

- shared secret is static and repo-known
- manual secret rotation
- manual token refresh / replacement in Foundry project connections
- no per-user identity
- no audience / scope isolation
- no dedicated operational workflow for credential rollover

### Option 2 — Migrate to OAuth identity passthrough

**Gateway changes required:**

- Replace or augment Kong auth strategy to validate OAuth/OIDC access tokens
- Define trusted issuer, audience, scopes, and JWKS validation
- Preserve or forward user identity claims to downstream services where needed
- Decide whether MCP server and mock/API backends enforce user-level authorization

**Azure / identity changes required:**

- Entra app registration for the MCP gateway
- consent flow definition for Foundry users
- token scope / app role design
- redirect / callback and trust configuration for the Foundry-managed or custom OAuth flow

**Automation opportunities later:**

- Kong plugin configuration templates
- Entra app setup scripts
- policy validation for scopes and claims

### Option 3 — Migrate to Microsoft Entra authentication

**Gateway changes required:**

- Accept and validate Entra-issued tokens instead of shared HS256 tokens
- Configure Kong for JWT/OIDC verification against Entra signing keys
- Define whether the caller is a Foundry agent identity, project managed identity, or another workload identity

**Azure changes required:**

- managed identity enablement on the Foundry side
- app registration / exposed API definition for the gateway
- RBAC or claims mapping for the gateway's accepted identities

**Automation opportunities later:**

- infrastructure templates for identity objects
- Kong auth config generation for Entra token validation
- smoke tests that acquire and replay Entra tokens

## Production Readiness Requirements

To move from the current POC to production, we should require all of the following:

### Identity and credential management

1. Replace `poc-secret-change-me` with managed signing material.
2. Store the signing secret in Azure Key Vault or an approved secret store.
3. Define a secret rotation runbook with overlap time for old/new tokens.
4. Create separate credentials per environment and, ideally, per client/application.

### Token lifecycle

1. Decide a supported token TTL and operational refresh cadence.
2. Automate token regeneration before expiry for any shared-credential deployment.
3. Document how Foundry project connections are updated when tokens rotate.
4. Consider moving away from shared symmetric secrets if frequent rotation becomes operationally heavy.

### Authorization model

1. Decide whether shared service identity is sufficient.
2. If user attribution is required, plan for OAuth passthrough.
3. If workload identity is sufficient, evaluate Entra authentication.
4. Define downstream authorization boundaries if more tools or sensitive APIs are added.

### Platform hardening

1. Add rate limiting specific to `/mcp/sse` and `/mcp/messages`.
2. Add monitoring for `401`, `429`, `5xx`, dropped SSE sessions, and tool latency.
3. Ensure logs never persist full bearer tokens.
4. Review whether downstream hops also need auth if the network boundary expands.

## Final Recommendation

For Rob's immediate Foundry validation goal, **stay with key-based authentication and use generated JWTs in the Foundry project connection**. That is the only option that aligns cleanly with the deployed Kong gateway today.

Treat **OAuth identity passthrough** and **Microsoft Entra authentication** as the production-upgrade paths:

- choose **OAuth passthrough** if preserving end-user identity is a requirement
- choose **Entra authentication** if service-to-service trust and automatic token rotation are the priority
