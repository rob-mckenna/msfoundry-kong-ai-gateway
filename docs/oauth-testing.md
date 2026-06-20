# OAuth route testing

This gateway now exposes two MCP auth families against the same backend server:

- JWT: `/mcp/sse`, `/mcp/messages`
- OAuth: `/mcp/oauth/sse`, `/mcp/oauth/messages`

The JWT family remains the shared-credential baseline. The OAuth family validates Microsoft Entra access tokens in Kong and forwards verified user claims to the MCP server.

## Entra token prerequisites

You need a delegated Entra access token for this scope:

- `api://d50b1d91-8be2-48cd-9615-3fbba4e04a2b/MCP.Use`

Issuer:

- `https://login.microsoftonline.com/e500988a-f788-4f81-b1ba-e3ad7cd66171/v2.0`

## Get an Entra token

### Azure CLI

```powershell
$token = az account get-access-token `
  --scope "api://d50b1d91-8be2-48cd-9615-3fbba4e04a2b/MCP.Use" `
  --query accessToken `
  --output tsv
```

### Verify the token

Confirm these claims before testing:

- `iss` matches the Entra issuer
- `aud` is `api://d50b1d91-8be2-48cd-9615-3fbba4e04a2b`
- `scp` includes `MCP.Use`

You can paste the token into `https://jwt.ms` for inspection.

## Test the OAuth SSE route

```powershell
$gateway = "https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io"
curl.exe -i `
  -H "Authorization: Bearer $token" `
  -H "Accept: text/event-stream" `
  "$gateway/mcp/oauth/sse"
```

Expected result:

- HTTP 200
- `text/event-stream`
- an SSE `endpoint` event pointing to `/mcp/oauth/messages?sessionId=...`

Without a bearer token, Kong should return HTTP 401.

## Test the OAuth messages route

After capturing the `sessionId` from the SSE response, send MCP JSON-RPC to the OAuth message endpoint:

```powershell
$sessionId = "<session-id-from-sse>"
$body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"oauth-smoke","version":"1.0.0"}}}'

curl.exe -i `
  -X POST `
  -H "Authorization: Bearer $token" `
  -H "Content-Type: application/json" `
  "$gateway/mcp/oauth/messages?sessionId=$sessionId" `
  --data $body
```

Expected result:

- HTTP 200
- MCP initialize response payload

## Expected upstream identity headers

Kong forwards these verified claims to the MCP server on the OAuth route family:

- `x-user-oid`
- `x-user-upn`
- `x-user-name`

Typical mappings:

- `x-user-oid` ← `oid`
- `x-user-upn` ← `preferred_username`
- `x-user-name` ← `name`

## Compare with the JWT routes

JWT route family:

- `GET /mcp/sse`
- `POST /mcp/messages`
- Authenticated with the existing shared HS256 JWT
- No per-user Entra identity

OAuth route family:

- `GET /mcp/oauth/sse`
- `POST /mcp/oauth/messages`
- Authenticated with user bearer tokens from Entra
- Per-user identity forwarded downstream by Kong

## Quick validation checklist

1. Existing `bash test/test-mcp-gateway.sh` still passes for the JWT route family.
2. `GET /mcp/oauth/sse` returns 401 without a bearer token.
3. `GET /mcp/oauth/sse` returns an SSE stream with an OAuth message endpoint when a valid Entra token is supplied.
4. `POST /mcp/oauth/messages?sessionId=...` succeeds with the same bearer token.
5. The MCP server logs show `x-user-oid`, `x-user-upn`, and `x-user-name` on OAuth traffic.
