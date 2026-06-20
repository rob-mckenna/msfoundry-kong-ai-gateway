# OAuth Identity Passthrough Implementation Phases

## Overview

The goal is to add OAuth identity passthrough **without disturbing the working JWT path**. For the Konnect path, the team should first establish Kong Konnect as the control plane and then add the new OAuth route family in Konnect while keeping the current `/mcp/*` JWT routes intact.

Each phase below has an explicit rollback so the team can stop at any boundary and still preserve the current demo.

## Phase 0 - Kong Konnect foundation

### Objective

Create the Konnect account/control plane and prepare the ACA-hosted Kong container to run as a self-managed Konnect data plane.

### Tasks

1. Create or select the Konnect organization.
2. Choose the **US** geo for the current East US 2 deployment.
3. Create the control plane for the gateway.
4. Open **Add Data Plane** and capture:
   - control plane endpoint
   - telemetry endpoint
   - cluster certificate
   - cluster private key
5. Store the cluster certificate and private key in Azure Key Vault.
6. Prepare Dockerfile updates:
   - remove `COPY kong.yaml`
   - remove `KONG_DECLARATIVE_CONFIG`
   - switch to a Konnect-capable/Kong Gateway Enterprise image
   - add `data_plane` runtime settings
7. Prepare `infra/main.bicep` updates for:
   - `KONG_ROLE=data_plane`
   - `KONG_CLUSTER_MTLS=pki`
   - `KONG_KONNECT_MODE=on`
   - Key Vault-backed secret refs for cluster cert/key
8. Recreate the current JWT services/routes/consumers/plugins in Konnect before cutover.

### Exit criteria

- Konnect control plane exists
- Key Vault contains the Konnect cluster cert/key
- planned Dockerfile/Bicep changes are documented
- current JWT route family is recreated in Konnect

### Rollback

- Stop before ACA deployment changes.
- Keep the current OSS DB-less deployment and `kong.yaml` as-is.
- Delete the new control plane only if the Konnect path is abandoned entirely.

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

## Phase 2 - Konnect OAuth plugin and route configuration

### Objective

Add a second MCP route family in **Konnect** that validates Entra access tokens while preserving the current JWT routes.

### Entry gate

Before starting this phase, confirm the team has at least:

- the Entra tenant ID
- the resource API app registration client ID

If either value is missing, defer this phase, document it as **pending Entra setup**, and continue with the JWT route family only.

### Tasks

1. Confirm the Kong distribution decision:
   - preferred: Konnect / Kong Gateway Enterprise `openid-connect`
   - fallback: alternative OIDC-capable enforcement path
2. In Konnect, keep the existing JWT route pair unchanged:
   - `/mcp/sse`
   - `/mcp/messages`
3. Add the OAuth route pair in Konnect:
   - `/mcp/oauth/sse`
   - `/mcp/oauth/messages`
4. Attach `openid-connect` to the OAuth routes only.
5. Configure bearer-token validation for Entra JWTs.
6. Enforce custom audience and `MCP.Use` scope.
7. Add claim-to-header propagation.
8. Ensure SSE timeout and CORS behavior match the current MCP routes.
9. Confirm the MCP server advertises the OAuth message path correctly.

### Exit criteria

- Konnect control plane contains separate JWT and OAuth route families
- Current JWT config is unchanged
- OAuth route config is isolated and reviewable
- MCP bootstrap path requirement is addressed

### Rollback

- Remove the OAuth route pair and `openid-connect` plugin only.
- Restore the last exported Konnect config snapshot if needed.
- Existing `/mcp/sse` and `/mcp/messages` continue to function.

## Phase 3 - Konnect data plane deployment and route-level testing

### Objective

Deploy the ACA gateway as a Konnect data plane and validate the OAuth endpoint independently from Foundry.

### Tasks

1. Build the updated Kong image.
2. Deploy the updated ACA revision with Konnect env vars and Key Vault secret refs.
3. Verify the data plane shows **Connected** in Konnect.
4. Keep the current Bash gateway suite as the regression test for the JWT route.
5. Acquire an Entra access token for the custom scope.
6. Test `GET /mcp/oauth/sse` with the Entra token.
7. Confirm the bootstrap event advertises the OAuth message endpoint.
8. Test `POST /mcp/oauth/messages?sessionId=...` with the same Entra token.
9. Verify downstream services receive the expected user-context headers.

### Exit criteria

- Konnect data plane is connected and syncing
- JWT route still passes its baseline validation
- OAuth route accepts valid Entra tokens
- OAuth route rejects wrong audience or missing scope
- MCP bootstrap and message flow succeed on the OAuth path

### Rollback

- Disable only the OAuth routes if the ACA data plane is healthy but OAuth fails.
- If Konnect cutover itself fails, switch back to the last known-good DB-less ACA revision.
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
- Konnect OAuth route can remain deployed but unused if needed.

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

- Remove the Foundry OAuth connection and Konnect OAuth routes.
- If necessary, roll the ACA gateway back to the last DB-less revision.
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
| Konnect control plane edit while data plane is connected | Sync reaches ACA data plane quickly |

## Konnect-specific rollback procedures

### Config-only rollback

Use when the ACA data plane is healthy and only the OAuth config is bad.

1. Disable `/mcp/oauth/*` routes in Konnect.
2. Remove `openid-connect` or revert to the prior Konnect config snapshot.
3. Re-run the JWT regression suite.

### Platform rollback

Use when the Konnect cutover itself is unstable.

1. Activate or redeploy the last ACA revision that still uses the baked-in `kong.yaml`.
2. Keep the Konnect control plane for later retry unless the project abandons Konnect entirely.
3. Re-run `bash test/test-mcp-gateway.sh` to confirm the baseline is restored.

## Phase Gate Recommendation

Do not begin Phase 2 until the Konnect control plane foundation from Phase 0 is complete and the team confirms the Kong distribution choice for OIDC validation. Those are the only decisions in this plan that materially change the implementation path.
