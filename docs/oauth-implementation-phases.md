# OAuth Identity Passthrough Implementation Phases

## Overview

The goal is to add OAuth identity passthrough **without disturbing the working JWT path**. Each phase below has an explicit rollback so the team can stop at any boundary and still preserve the current demo.

## Phase 1 - Entra app registration and configuration

### Objective

Create the Entra objects and values needed for Foundry custom OAuth and Kong token validation.

### Tasks

1. Create the resource API app registration.
2. Set the Application ID URI.
3. Add delegated scope `MCP.Use`.
4. Create the Foundry client app registration.
5. Add the Foundry redirect URI to the client app.
6. Create a client secret.
7. Grant delegated permission from the client app to the API scope.
8. Record tenant ID, client ID, client secret, scope string, and OAuth endpoints.

### Exit criteria

- Resource API app exists
- Client app exists
- Redirect URI is registered
- Scope string is documented
- Secret is stored securely

### Rollback

- Delete the new app registrations if the design is abandoned.
- No impact to Kong or the current JWT demo.

## Phase 2 - Kong OAuth plugin and route configuration

### Objective

Add a second MCP route family that validates Entra access tokens while preserving the current JWT routes.

### Tasks

1. Confirm the Kong distribution decision:
   - preferred: Enterprise/Konnect `openid-connect`
   - fallback: alternative OIDC-capable enforcement path
2. Add OAuth route pair:
   - `/mcp/oauth/sse`
   - `/mcp/oauth/messages`
3. Configure bearer-token validation for Entra JWTs.
4. Enforce custom audience and `MCP.Use` scope.
5. Add claim-to-header propagation.
6. Preserve the current JWT route family unchanged.
7. Ensure SSE timeout and CORS behavior match the current MCP routes.

### Exit criteria

- Kong config renders with separate JWT and OAuth route families
- Current JWT config is unchanged
- OAuth route config is isolated and reviewable

### Rollback

- Remove the OAuth route pair and OAuth plugin only.
- Re-deploy the previous `kong.yaml`.
- Existing `/mcp/sse` and `/mcp/messages` continue to function.

## Phase 3 - Deployment and route-level testing

### Objective

Deploy the new route configuration and validate the OAuth endpoint independently from Foundry.

### Tasks

1. Deploy the updated Kong configuration.
2. Keep the current Bash gateway suite as the regression test for the JWT route.
3. Acquire an Entra access token for the custom scope.
4. Test `GET /mcp/oauth/sse` with the Entra token.
5. Confirm the bootstrap event advertises the OAuth message endpoint.
6. Test `POST /mcp/oauth/messages?sessionId=...` with the same Entra token.
7. Verify downstream services receive the expected user-context headers.

### Exit criteria

- JWT route still passes its baseline validation
- OAuth route accepts valid Entra tokens
- OAuth route rejects wrong audience or missing scope
- MCP bootstrap and message flow succeed on the OAuth path

### Rollback

- Disable only the OAuth routes if any failure occurs.
- Revert to the last known-good Kong deployment.
- Keep the Entra registrations for later retry.

## Phase 4 - Foundry custom OAuth configuration

### Objective

Register the OAuth route in Foundry as a second MCP connection.

### Tasks

1. Create a new Foundry MCP connection for `https://<gateway>/mcp/oauth/sse`.
2. Choose **OAuth identity passthrough**.
3. Select **custom OAuth**.
4. Enter:
   - Client ID
   - Client secret
   - Auth URL
   - Token URL
   - Refresh URL
   - Scopes
5. Capture the Foundry-generated redirect URI.
6. Add that redirect URI to the Entra client app.
7. Retry the connection if Foundry requires the redirect URI before the full flow completes.

### Exit criteria

- Foundry connection saves successfully
- Redirect URI is registered in Entra
- First OAuth tool invocation returns a valid consent link

### Rollback

- Delete the new Foundry OAuth connection only.
- Leave the existing JWT connection untouched.
- Kong OAuth route can remain deployed but unused if needed.

## Phase 5 - End-to-end validation and demo readiness

### Objective

Prove both authentication methods work side-by-side and are demo-ready.

### Tasks

1. Re-run the current JWT regression validation.
2. Run the OAuth route with a real user consent flow.
3. Confirm Foundry retries successfully after consent.
4. Confirm tool discovery works on both connections.
5. Invoke `get_weather` and `calculate` through both auth paths.
6. Verify logs show:
   - JWT path = shared service identity
   - OAuth path = user-specific claims
7. Capture final operator notes and troubleshooting steps.

### Exit criteria

- Two working Foundry connections exist
- JWT path still works
- OAuth path works with user consent and stored credentials
- Demo script clearly shows the difference between auth modes

### Rollback

- Remove the Foundry OAuth connection and Kong OAuth routes.
- Return to the JWT-only setup with no other user-visible changes.

## Recommended Validation Matrix

| Scenario | Expected result |
| --- | --- |
| Existing JWT route with valid token | Success |
| Existing JWT route with invalid token | `401/403` |
| OAuth route with valid Entra token and correct audience/scope | Success |
| OAuth route with wrong audience | Rejected |
| OAuth route with missing `MCP.Use` scope | Rejected |
| OAuth route first use in Foundry | Consent link returned |
| OAuth route after consent | Tool discovery and invocation succeed |

## Phase Gate Recommendation

Do not begin Phase 2 until the team explicitly confirms the Kong distribution choice for OIDC validation. That is the only decision in this plan that can materially change the implementation path.
