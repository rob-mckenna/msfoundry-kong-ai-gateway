# OAuth Identity Passthrough Implementation Plan

## Status

Design only. No gateway, Entra, Foundry, or infrastructure changes are applied by this document.

## Executive Decision

**Recommended approach:** keep the current JWT path as-is and add a second OAuth-only MCP endpoint family.

- **Existing JWT demo path remains unchanged:**
  - `GET /mcp/sse`
  - `POST /mcp/messages?sessionId=...`
- **New OAuth passthrough path is added in parallel:**
  - `GET /mcp/oauth/sse`
  - `POST /mcp/oauth/messages?sessionId=...`
- **Kong auth split:**
  - JWT routes keep the current `jwt` plugin.
  - OAuth routes use an **OIDC/JWT-access-token validation** plugin against a **custom Microsoft Entra audience**.
- **Foundry split:**
  - one project connection continues to use key-based JWT
  - one project connection uses custom OAuth identity passthrough

This gives Rob the cleanest side-by-side demo while avoiding any regression to the existing key-based flow.

## Why this is the best fit

1. **Preserves the working POC**. The current `/mcp/*` JWT flow already passes the 10/10 Bash gateway suite and should remain the baseline demo.
2. **Makes the demo obvious**. Rob can show “same tools, same backend, different auth modes” without explaining token-shape branching.
3. **Contains blast radius**. OAuth validation, claim mapping, and consent only affect the new OAuth path.
4. **Matches Foundry's model**. Foundry can hold two separate MCP connections: one shared credential, one per-user consented OAuth connection.

## Current State and Constraints

### Current gateway shape

- Kong is running from the OSS image `kong:3.7` in DB-less mode.
- JWT auth is already configured on the MCP service in `kong.yaml`.
- Current public MCP endpoints are:
  - `GET /mcp/sse`
  - `POST /mcp/messages?sessionId=...`
- The MCP server currently emits the companion message endpoint as **`/mcp/messages`** from the SSE bootstrap flow.

### Foundry constraints from Microsoft docs

- OAuth identity passthrough preserves user identity and consent.
- Foundry supports **managed OAuth** and **custom OAuth**.
- For a **custom MCP server**, do **not** rely on a Microsoft-owned audience.
- If a Microsoft-scoped managed OAuth token is sent to an untrusted custom MCP endpoint, Foundry returns:
  - `Cannot pass Microsoft token to untrusted MCP endpoint.`
- Therefore this gateway must use **custom OAuth with our own Entra app registration and audience**.

### Kong product constraint

Kong's **OpenID Connect** plugin is the best fit technically, but it is an **Enterprise/Konnect plugin**, not part of the base OSS `kong:3.7` image.

That creates a design gate:

- **Preferred path:** use Kong Enterprise/Konnect `openid-connect` plugin for the OAuth route.
- **Fallback path:** stay on OSS Kong and adopt a supported third-party OIDC-capable plugin or move OAuth enforcement to another gateway tier.

For planning purposes, this document assumes the **preferred path** because it is the cleanest and most supportable design.

## Architecture Options

| Option | Shape | Pros | Cons | Verdict |
| --- | --- | --- | --- | --- |
| **A. Separate routes** | JWT stays on `/mcp/*`; OAuth added on `/mcp/oauth/*` | Best demo UX, easiest rollback, route-level isolation, simple Foundry setup with two connections | Requires MCP bootstrap path support for `/mcp/oauth/messages`; duplicates a small amount of route config | **Recommended** |
| **B. Header-based** | Same `/mcp/sse` and `/mcp/messages`; Kong decides auth based on token type or header | No new public path family; avoids bootstrap path change | Hard to reason about plugin precedence, ambiguous failures, weaker demo story, harder rollback | Not recommended |
| **C. Separate services** | Two MCP services in `kong.yaml`, potentially two upstream instances | Strong isolation and simpler per-service config | More deployment overhead; still needs separate public endpoint or hostname; higher operational cost for a demo | Useful later, but not first choice |

## Recommended Implementation Pattern

### Public endpoint layout

Keep the current JWT endpoints unchanged and add a new OAuth pair:

| Auth mode | SSE endpoint | Message endpoint |
| --- | --- | --- |
| JWT / key-based | `/mcp/sse` | `/mcp/messages` |
| OAuth passthrough | `/mcp/oauth/sse` | `/mcp/oauth/messages` |

### Kong route strategy

Create a second pair of Kong routes that target the same MCP backend behavior but carry different auth policy.

- **JWT routes**
  - keep current route behavior, current docs, and current tests
- **OAuth routes**
  - new route-level OIDC validation
  - new claim-to-header mapping
  - separate rate limit and observability tags if desired

### Critical implementation note: SSE bootstrap path

This is the one upstream change the design depends on.

The current MCP server bootstraps the message endpoint as `/mcp/messages`, which is correct for the existing JWT path but not for a second OAuth route family. To support OAuth cleanly, the MCP server should be made aware of its public message path.

**Recommended fix:** make the MCP server's advertised message endpoint configurable, for example with one of these patterns:

1. `PUBLIC_MCP_MESSAGES_PATH=/mcp/messages` or `/mcp/oauth/messages`
2. `PUBLIC_MCP_BASE_PATH=/mcp` or `/mcp/oauth`
3. route-specific header from Kong, such as `X-External-Mcp-Base-Path`, which the MCP server uses when creating the SSE transport

For the first OAuth demo, the smallest clean change is a configurable public base path.

## Kong Plugin Strategy

### Recommended plugin

**Use `openid-connect` in bearer/JWT access-token mode against Microsoft Entra discovery + JWKS.**

Why:

- Entra access tokens are JWTs and can be validated statelessly.
- Kong can verify signature and standard claims without round-tripping to introspection on every request.
- It preserves a normal OAuth/OIDC architecture: Entra is the authorization server; Kong is the resource server.

### Why not use Kong `oauth2`

Kong's OSS `oauth2` plugin is not the right match for Foundry OAuth passthrough here.

It is designed for Kong to act as the OAuth authorization/token service for the protected API. In practice that means:

- Kong would issue or manage the tokens itself
- authorization-code flow requires an authorization page/backend we would have to build
- it does not natively validate Microsoft Entra user tokens as the primary design

That is the opposite of the desired model, where:

- Foundry acquires a user token from Entra
- Kong validates that Entra-issued token
- the MCP server receives trusted user context

### Token validation approach

#### Recommendation: stateless JWT validation

Use Entra **issuer discovery + JWKS** and require:

- `iss` = tenant-specific Entra issuer
- `aud` = our custom gateway API audience, not a Microsoft audience
- `scp` contains the delegated scope we expose for MCP access, for example `MCP.Use`
- `exp` and `nbf` are valid

#### Why not introspection

Introspection is optional but not preferred here.

- Entra access tokens are already JWTs.
- Introspection adds latency and an extra dependency for every request.
- SSE and tool calls benefit from fewer external lookups.

Use introspection only if a later identity provider choice issues opaque access tokens.

## User Context Propagation

### Kong to MCP Server

Forward only a small, curated set of claims so downstream logging and auditing can identify the user without parsing the bearer token again.

Recommended headers:

- `X-Auth-Mode: oauth`
- `X-User-Object-Id: <oid>`
- `X-User-Tenant-Id: <tid>`
- `X-User-Principal-Name: <upn or preferred_username>`
- `X-User-Display-Name: <name>`
- `X-User-Scopes: <scp>`

For the existing JWT route, set an equivalent marker such as:

- `X-Auth-Mode: jwt`
- `X-Client-Subject: <sub>`

### MCP Server behavior

The MCP server does **not** need to become an authorization server.

Recommended behavior:

- trust Kong as the enforcement point
- log the incoming auth mode and user headers
- optionally forward the user headers to the Mock API for audit visibility
- do not add user-specific authorization logic in phase 1 unless a tool requires it

### Mock API behavior

The Mock API can stay transparent for the demo.

Optional enhancement for better demos:

- log `X-Auth-Mode`, `X-User-Object-Id`, and `X-User-Principal-Name`
- echo a sanitized user summary in test responses only if that helps the demo

## Required Components

| Component | Required | Notes |
| --- | --- | --- |
| Entra tenant ID | Yes | Used in issuer, authorize, and token URLs |
| Resource API app registration | Yes | Owns the custom audience and delegated scope |
| OAuth client app registration | Recommended | Cleaner separation for Foundry redirect + secret handling |
| Client ID | Yes | From the Foundry-facing client app |
| Client secret | Plan for yes | Docs mark it optional, but create one for the first demo path |
| Redirect URI | Yes | Generated by Foundry custom OAuth setup and copied into the client app registration |
| Custom delegated scope | Yes | Example: `api://<gateway-api-app-id>/MCP.Use` |
| Kong OIDC validation plugin | Yes | Prefer Kong Enterprise/Konnect `openid-connect` |
| Updated `kong.yaml` | Yes | Add OAuth routes/plugins without touching the JWT baseline |
| MCP advertised message-path configurability | Yes | Needed for `/mcp/oauth/messages` bootstrap |
| User context header propagation | Yes | Needed for auditable identity passthrough demo |

## Foundry Configuration

Create **two separate project connections** so the demo can switch cleanly between auth methods.

### Connection 1: current key-based JWT

- Authentication type: key-based
- Credential name: `Authorization`
- Credential value: `Bearer <jwt>`
- Server URL: existing JWT SSE endpoint

### Connection 2: custom OAuth passthrough

- Authentication type: OAuth identity passthrough
- OAuth mode: custom OAuth
- Server URL: `https://<gateway>/mcp/oauth/sse`
- Client ID: Entra client app ID
- Client secret: Entra client secret
- Auth URL: `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/authorize`
- Token URL: `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token`
- Refresh URL: `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token`
- Scopes: `openid profile offline_access api://<gateway-api-app-id>/MCP.Use`

### Redirect URI handling

After the custom OAuth connection is configured, Foundry provides a redirect URI. Add that URI to the Entra **client app** registration under **Authentication**.

## Demonstration Model

The cleanest demo is:

1. **JWT demo**
   - connect to `/mcp/sse`
   - show shared credential flow still works
2. **OAuth demo**
   - connect to `/mcp/oauth/sse`
   - show Foundry consent link on first use
   - sign in as a user
   - show user context arriving downstream
3. **Compare**
   - same tools
   - same MCP server behavior
   - different trust model and user attribution

## Risks and Open Questions

1. **Kong distribution choice**
   - The current OSS image does not include the Enterprise OIDC plugin.
   - Decide early whether to move to Kong Enterprise/Konnect or adopt a fallback.
2. **Bootstrap path support**
   - The current MCP server must be made path-aware for the OAuth route family.
3. **Foundry consent UX timing**
   - The first OAuth tool call returns a consent link and then requires a retry after consent.
4. **Cross-tenant support**
   - Not supported for this pattern; keep the Foundry project and Entra app registrations in the same tenant.
5. **Secret operations**
   - Even though this is user passthrough, the client app secret still needs storage and rotation.

## Effort Estimate

| Work item | Estimate |
| --- | --- |
| Entra app registrations | 30-60 minutes |
| Kong OAuth route/plugin configuration | 2-4 hours |
| MCP bootstrap-path support | 1-2 hours |
| Deployment + route validation | 1-2 hours |
| Foundry custom OAuth setup | 30-60 minutes |
| Documentation + handoff | 2-3 hours |

**Total:** about **1-2 working days**.

## Final Recommendation

Proceed with **Option A: separate routes**, implemented as:

- **unchanged JWT MCP endpoint family** for the current POC
- **new OAuth MCP endpoint family** for identity passthrough
- **OIDC JWT validation against a custom Entra audience**
- **minimal MCP server enhancement** to advertise the correct message path for the OAuth route

This is the lowest-risk way to add per-user OAuth identity passthrough while preserving the current key-based JWT demo.
