# Kong OAuth Configuration for Parallel JWT and OAuth MCP Routes

## Recommendation Summary

- **Keep the current JWT plugin on the existing MCP route family.**
- **Add a new OAuth-only route family for identity passthrough.**
- **Use Kong `openid-connect` with JWT access-token validation** against Microsoft Entra if an Enterprise/Konnect-capable distribution is available.
- **Do not use Kong OSS `oauth2` as the primary solution** for Foundry passthrough.

## Plugin Decision

| Plugin | Fit for this project | Why |
| --- | --- | --- |
| `jwt` | Keep for current route | Already working for shared key-based Foundry JWT |
| `oauth2` | Poor fit | Makes Kong the OAuth server; requires auth page/backend; not the desired Entra passthrough model |
| `openid-connect` | Best fit | Validates Entra-issued JWT access tokens statelessly via discovery + JWKS |
| Third-party OIDC plugin | Fallback only | Possible if staying on OSS Kong, but introduces support and lifecycle risk |

## Important Product Note

The current Docker image is based on **`kong:3.7` OSS**. Kong's official `openid-connect` plugin is an **Enterprise/Konnect** capability.

That means the team must decide one of these before implementation:

1. Move the gateway to Kong Enterprise/Konnect for the OAuth route, or
2. Accept a fallback plugin/gateway layer for OAuth validation.

This document assumes **option 1** because it is the cleanest design for a demo that we may later productionize.

## Recommended Route Layout

### Keep the current JWT routes

- `GET /mcp/sse`
- `POST /mcp/messages`

These continue to use:

- Kong `jwt` plugin
- current `iss=kong-poc` POC token model

### Add the OAuth passthrough routes

- `GET /mcp/oauth/sse`
- `POST /mcp/oauth/messages`

These use:

- Kong `openid-connect` plugin
- Microsoft Entra access tokens for a **custom audience** that we control

## Recommended Validation Model

### Use JWT access-token validation, not introspection

Configure the OAuth route to validate:

- **Issuer**: tenant-specific Entra issuer
- **Signature**: via Entra discovery document and JWKS
- **Audience**: `api://<resource-api-client-id>` or another custom Application ID URI you own
- **Scope**: require delegated scope `MCP.Use`
- **Lifetime**: honor `exp` and `nbf`

### Why this is preferable

- No round-trip to an introspection endpoint on every request
- Better fit for SSE + follow-up POST traffic
- Aligns with Entra's normal JWT access-token model

## Conceptual Kong Plugin Configuration

The exact schema can vary slightly by Kong delivery model, but the OAuth route should conceptually include:

```yaml
- name: openid-connect
  config:
    issuer: https://login.microsoftonline.com/<tenant-id>/v2.0
    auth_methods:
      - bearer
    bearer_token_param_type:
      - header
    audience_required:
      - api://<resource-api-client-id>
```

Add client credentials only if the chosen auth method or claim lookup requires Kong to call protected IdP endpoints. For pure bearer/JWT validation, the main requirement is correct issuer discovery and audience enforcement.

## Coexistence with Existing JWT Plugin

Do **not** stack JWT and OIDC validation on the same public route.

Instead:

- keep the current JWT plugin attached only to the current JWT routes
- attach the OIDC plugin only to the new OAuth routes
- keep both route families pointed at the MCP backend behavior

This avoids ambiguous `401` and `403` failures and keeps rollback simple.

## `kong.yaml` Shape to Target

Conceptually, the updated declarative config should look like this:

```yaml
services:
  - name: mcp-service-jwt
    url: https://<internal-mcp-server>
    plugins:
      - name: jwt
      - name: cors
    routes:
      - name: mcp-sse-route
        paths: ["/mcp/sse"]
      - name: mcp-messages-route
        paths: ["/mcp/messages"]

  - name: mcp-service-oauth
    url: https://<internal-mcp-server>
    plugins:
      - name: openid-connect
      - name: cors
    routes:
      - name: mcp-oauth-sse-route
        paths: ["/mcp/oauth/sse"]
      - name: mcp-oauth-messages-route
        paths: ["/mcp/oauth/messages"]
```

Whether the two services point to the exact same upstream instance or to two differently configured MCP server instances depends on how the bootstrap message path is implemented.

## Bootstrap Path Requirement

Because the MCP server currently advertises `/mcp/messages`, the OAuth route family needs one of these:

1. a configurable public message path in the MCP server, or
2. a dedicated OAuth MCP server instance configured to advertise `/mcp/oauth/messages`

For the demo, a **configurable public path** is the lowest-effort approach.

## Claim Extraction and Propagation

### Goal

Pass verified user identity downstream without making the MCP server parse or trust raw tokens directly.

### Recommended headers to forward

- `X-Auth-Mode`
- `X-User-Object-Id`
- `X-User-Tenant-Id`
- `X-User-Principal-Name`
- `X-User-Display-Name`
- `X-User-Scopes`

### Implementation note

Use the OIDC plugin's authenticated claim data if the plugin exposes the needed fields directly. If not, add a lightweight request-transform step on the OAuth routes to map validated claims into those headers.

## CORS and SSE Considerations

Retain the current MCP route operational behavior on the new OAuth routes:

- `GET`, `POST`, `OPTIONS`
- `Authorization`, `Accept`, `Content-Type`, `Cache-Control`, `Connection`
- SSE-safe proxy buffering/timeouts already validated for `/mcp/*`

The OAuth routes should inherit the same SSE hardening as the existing JWT routes.

## Suggested Observability

Tag or distinguish OAuth traffic from JWT traffic for easier demos and rollback:

- response header or injected upstream header `X-Auth-Mode`
- separate route names in Kong logs
- log `oid`, `tid`, and `preferred_username` only after sanitization
- never log the full bearer token

## Rollback Strategy

If OAuth validation causes issues:

1. Remove or disable the OAuth route pair only.
2. Leave the existing JWT route family untouched.
3. Keep the Entra registrations for later retry.

That rollback keeps the current Foundry key-based demo fully operational.

## Final Recommendation

Use **Kong `openid-connect` bearer/JWT validation** for the new `/mcp/oauth/*` route family and keep the existing JWT route family unchanged. This gives the cleanest parallel-auth demo and the lowest operational risk.
