# Foundry Final Configuration Guide

This guide covers the last manual setup steps after the Kong gateway, Konnect, Azure OpenAI proxy, MCP server, and dual-auth routes are already deployed.

## What is already ready

- Kong public gateway is live
- Konnect control plane and data plane are connected
- JWT MCP routes are working:
  - `GET /mcp/sse`
  - `POST /mcp/messages`
- OAuth MCP routes are configured:
  - `GET /mcp/oauth/sse`
  - `POST /mcp/oauth/messages`
- Entra app registrations exist and local OAuth config has been captured in `entra-oauth-config.json`

## Recommendation

For the demo, configure **two separate Foundry MCP connections**:

1. **Kong MCP Gateway (JWT)** for the current shared-key POC path
2. **Kong MCP Gateway (OAuth)** for the per-user identity passthrough path

Keep the JWT connection as the default demo fallback because it is already fully validated end to end.

---

## Part 1 - JWT MCP tool setup

### Generate a JWT

Use one of the existing helper scripts:

```powershell
.\scripts\generate-foundry-jwt.ps1 -TtlSeconds 3600 -Issuer kong-poc -Subject foundry-poc
```

or:

```bash
bash scripts/generate-foundry-jwt.sh --ttl 3600 --issuer kong-poc --subject foundry-poc
```

Copy the output token and keep the `Bearer ` prefix when you paste it into Foundry.

### Create the Foundry connection

In Foundry, add a new external MCP connection with these values:

- **Name:** `Kong MCP Gateway (JWT)`
- **Server URL:** `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/sse`
- **Transport:** `SSE`
- **Authentication:** `Key-based authentication`
- **Credential name:** `Authorization`
- **Credential value:** `Bearer <generated-jwt-token>`

> If the Foundry screen labels the field as **Base URL**, still enter the full SSE endpoint above. This gateway uses the legacy SSE bootstrap flow, not a base path that Foundry expands automatically.

### Validate the JWT connection

Expected behavior:

1. Foundry opens `GET /mcp/sse`
2. Kong accepts the JWT
3. Foundry receives the bootstrap event with a `sessionId`
4. Foundry posts JSON-RPC messages to `/mcp/messages?sessionId=...`
5. Tools `get_weather` and `calculate` become available

Suggested prompts:

- `Use the weather tool to tell me the current weather in Seattle.`
- `Use the calculate tool to multiply 6 by 7.`

---

## Part 2 - OAuth MCP tool setup

### Use the local Entra OAuth config

Read values from the local ignored file:

- `entra-oauth-config.json`

Use that file as the source of truth for:

- client ID
- client secret
- auth URL
- token URL
- refresh URL
- scopes

Do **not** copy the client secret into repo docs or source files.

### Create the Foundry OAuth connection

In Foundry, add a second external MCP connection with these values:

- **Name:** `Kong MCP Gateway (OAuth)`
- **Server URL:** `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/oauth/sse`
- **Transport:** `SSE`
- **Authentication:** `OAuth identity passthrough` or `Custom OAuth`
- **Client ID:** `2bf65392-7f5e-44e3-845b-493831902b40`
- **Client secret:** copy from local `entra-oauth-config.json` or approved secret store
- **Authorization URL:** `https://login.microsoftonline.com/e500988a-f788-4f81-b1ba-e3ad7cd66171/oauth2/v2.0/authorize`
- **Token URL:** `https://login.microsoftonline.com/e500988a-f788-4f81-b1ba-e3ad7cd66171/oauth2/v2.0/token`
- **Refresh URL:** `https://login.microsoftonline.com/e500988a-f788-4f81-b1ba-e3ad7cd66171/oauth2/v2.0/token`
- **Scopes:** `openid profile offline_access api://d50b1d91-8be2-48cd-9615-3fbba4e04a2b/MCP.Use`

### Validate the OAuth connection

Expected behavior:

1. Foundry sends the user through Entra sign-in and consent
2. Foundry opens `GET /mcp/oauth/sse`
3. Kong validates the Entra access token
4. The SSE bootstrap advertises `/mcp/oauth/messages?sessionId=...`
5. Foundry reuses the same OAuth token on the POST leg
6. The same tools are available, but traffic now carries user identity

Notes:

- Without a valid user token, `/mcp/oauth/sse` should return `401`
- Browser-based sign-in and consent are still manual
- This is the main remaining end-to-end test gap for the POC

---

## Part 3 - Test both paths

## JWT test prompts

- `Use the weather tool to get Seattle weather.`
- `Use the calculate tool to multiply 6 by 7.`

Expected result:

- tool discovery succeeds
- prompts complete successfully
- this should already match the validated gateway baseline

## OAuth test prompts

Use the same prompts after sign-in:

- `Use the weather tool to get Seattle weather.`
- `Use the calculate tool to multiply 6 by 7.`

Expected result:

- sign-in and consent succeed
- tool discovery succeeds
- prompts complete successfully through `/mcp/oauth/*`

## Compare the two paths

| Path | Endpoint family | Auth model | Current status |
| --- | --- | --- | --- |
| JWT | `/mcp/sse`, `/mcp/messages` | Shared HS256 JWT | Fully validated |
| OAuth | `/mcp/oauth/sse`, `/mcp/oauth/messages` | Entra delegated user token | Route config complete; live Foundry validation still pending |

## What to capture for the demo

Capture evidence for both connections:

1. connection created successfully
2. tools discovered
3. weather prompt succeeds
4. calculate prompt succeeds

For OAuth, also capture:

5. successful user sign-in / consent
6. successful tool call through `/mcp/oauth/*`

## Current known limitation

The OAuth route is configured to forward verified user claims downstream, but the repo does not yet provide a purpose-built demo view that echoes those forwarded headers back to the operator. For the POC, the critical validation is a successful Foundry OAuth run through `/mcp/oauth/*`; explicit user-header observability is a follow-on enhancement if Rob wants that shown in the demo.
