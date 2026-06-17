# Microsoft Entra App Registration Guide for Kong MCP OAuth Passthrough

## Goal

Create the Microsoft Entra registrations needed for **Foundry custom OAuth identity passthrough** to the Kong MCP Gateway.

## Recommended Registration Layout

Use **two app registrations**.

| Registration | Purpose | Why |
| --- | --- | --- |
| `kong-mcp-gateway-api` | Represents the protected MCP gateway API | Owns the custom audience and delegated scope validated by Kong |
| `foundry-kong-mcp-client` | OAuth client used by Foundry custom OAuth | Owns the redirect URI and client secret |

A single registration can be made to do both jobs, but two registrations are cleaner for permission management and production hardening.

## Values you will need at the end

Capture these values as you go:

- Tenant ID
- Resource API Application (client) ID
- Resource API Application ID URI
- Delegated scope name and full scope string
- Client Application (client) ID
- Client secret value
- Foundry-provided redirect URI
- Auth URL
- Token URL
- Refresh URL

## Part 1 - Register the resource API app

### Step 1: Create the app registration

1. Sign in to `https://entra.microsoft.com`.
2. Go to **Entra ID** > **App registrations** > **New registration**.
3. Name the app `kong-mcp-gateway-api`.
4. Choose **Single tenant** unless you have a firm multi-tenant requirement.
5. Do **not** configure a redirect URI for this API app.
6. Select **Register**.

Record:

- **Application (client) ID** -> this becomes the API app ID
- **Directory (tenant) ID** -> this becomes the tenant ID used throughout the config

### Step 2: Expose the API

1. Open the new API app.
2. Go to **Expose an API**.
3. Select **Add** next to **Application ID URI**.
4. Accept or set a URI such as:
   - `api://<resource-api-client-id>`
5. Save it.

### Step 3: Add a delegated scope

Create a delegated scope for Foundry users, for example:

- **Scope name:** `MCP.Use`
- **Who can consent:** `Admins and users`
- **Admin consent display name:** `Use Kong MCP gateway tools`
- **Admin consent description:** `Allow the application to call the Kong MCP gateway on behalf of the signed-in user.`
- **User consent display name:** `Use Kong MCP gateway tools`
- **User consent description:** `Allow this tool connection to call the Kong MCP gateway with your identity.`
- **State:** `Enabled`

The full scope string becomes:

- `api://<resource-api-client-id>/MCP.Use`

### Step 4: Optional app role

If you might later add service-to-service clients or non-user flows, optionally add an app role now, for example `MCP.Access`. It is not required for the first user-delegated passthrough demo.

## Part 2 - Register the Foundry OAuth client app

### Step 5: Create the client app registration

1. Go to **App registrations** > **New registration**.
2. Name the app `foundry-kong-mcp-client`.
3. Choose **Single tenant**.
4. Under **Redirect URI**, choose **Web** only after you have a redirect URI from Foundry. If you do not have it yet, create the app first and return later to add it.
5. Select **Register**.

Record:

- **Application (client) ID** -> this is the **Client ID** you will enter in Foundry custom OAuth settings

### Step 6: Add the Foundry redirect URI

After creating the custom OAuth connection in Foundry, copy the redirect URI that Foundry generates.

Then in the client app:

1. Go to **Authentication**.
2. Select **Add a platform** if needed and choose **Web**.
3. Add the Foundry redirect URI exactly as shown.
4. Save the changes.

Important:

- The redirect URI must match exactly.
- If you have separate dev/test/prod Foundry environments, register each redirect URI explicitly.

### Step 7: Create a client secret

1. Go to **Certificates & secrets**.
2. Under **Client secrets**, select **New client secret**.
3. Use an operator-friendly name such as `foundry-oauth-demo`.
4. Choose the shortest practical lifetime for the demo.
5. Save and copy the **secret value** immediately.

Record:

- **Client secret value**

Treat the secret as a secret from this point onward.

### Step 8: Grant delegated API permission

In the client app:

1. Go to **API permissions** > **Add a permission**.
2. Choose **My APIs**.
3. Select `kong-mcp-gateway-api`.
4. Choose **Delegated permissions**.
5. Select `MCP.Use`.
6. Add the permission.

Then add standard OIDC delegated permissions if they are not already present or requested dynamically:

- `openid`
- `profile`
- `offline_access`

`offline_access` is strongly recommended so Foundry can refresh tokens without forcing repeated sign-in.

### Step 9: Grant admin consent if desired

If your tenant prefers centralized consent:

1. Stay on **API permissions**.
2. Select **Grant admin consent for <tenant>**.
3. Confirm.

This is optional for a small demo if user consent is allowed, but it reduces sign-in friction.

## Part 3 - Build the OAuth endpoint values

Use the **tenant ID** from the API or client registration.

### Auth URL

`https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/authorize`

### Token URL

`https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token`

### Refresh URL

Use the same value as the token URL:

`https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token`

### Scopes string for Foundry

Use a single space-delimited string:

`openid profile offline_access api://<resource-api-client-id>/MCP.Use`

## Permissions Guidance

### Required for this gateway

- Custom delegated API scope: `MCP.Use`
- OIDC identity scopes: `openid profile`
- Refresh scope: `offline_access`

### Not required for the first demo

- Microsoft Graph delegated permissions
- Mail, Files, Teams, or SharePoint permissions
- Multi-tenant exposure

The gateway is its own protected API, so no Microsoft 365 permission set is needed unless a later downstream tool truly depends on it.

## How to get each required value

| Value | Where to find it |
| --- | --- |
| Tenant ID | App registration overview or tenant overview |
| Resource API client ID | `kong-mcp-gateway-api` overview |
| Application ID URI | `kong-mcp-gateway-api` > Expose an API |
| Full scope string | Application ID URI + `/MCP.Use` |
| Client ID | `foundry-kong-mcp-client` overview |
| Client secret | `foundry-kong-mcp-client` > Certificates & secrets |
| Redirect URI | Foundry custom OAuth setup screen after configuration |
| Auth/Token URLs | Derived from tenant ID |

## Security Considerations

1. **Use single-tenant unless you truly need more.** It reduces accidental audience and consent sprawl.
2. **Do not use a Microsoft-owned audience.** Use your own `api://...` audience so Foundry can send tokens to the custom MCP endpoint.
3. **Store the client secret outside the repo.** Use Key Vault or another approved secret store.
4. **Rotate the client secret on a schedule.** For the POC, document who owns rotation and where the secret is updated in Foundry.
5. **Separate environments.** Create distinct app registrations for dev/test/prod if this moves beyond a demo.
6. **Least privilege.** Do not add Microsoft Graph or other permissions unless a later tool explicitly needs them.
7. **Protect logs.** Never log the raw access token or client secret.

## Final Output Checklist

Before moving to Kong configuration, you should have:

- [ ] Tenant ID
- [ ] Resource API app registration
- [ ] Application ID URI set
- [ ] `MCP.Use` delegated scope created
- [ ] Client app registration
- [ ] Foundry redirect URI added to the client app
- [ ] Client secret created and stored securely
- [ ] Client app granted delegated permission to `MCP.Use`
- [ ] Scope string documented for Foundry
- [ ] Auth URL, Token URL, and Refresh URL recorded
