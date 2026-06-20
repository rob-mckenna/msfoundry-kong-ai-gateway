# MCP Gateway Test Scripts

These scripts validate the deployed Kong MCP Gateway using the raw SSE transport flow:

1. Open `GET /mcp/sse`
2. Extract the `sessionId` from the SSE bootstrap event
3. Send JSON-RPC messages to `POST /mcp/messages?sessionId=...`
4. Verify the actual results on the SSE stream

## Prerequisites

- `curl`
- **Bash script:** Bash + Python 3
- **PowerShell script:** PowerShell 5.1+ or PowerShell 7+
- Access to the deployed gateway
- A valid gateway JWT configuration (defaults match this repo):
  - `JWT_ISSUER=kong-poc`
  - `JWT_SECRET=poc-secret-change-me`

> The Bash script generates HS256 JWTs with the Python standard library. No third-party `jwt` package is required.

## Files

- `test-mcp-gateway.sh` — Bash / Git Bash version
- `test-mcp-gateway.ps1` — PowerShell version using `Start-Job` for the SSE stream

## What the suite covers

- Valid JWT accepted
- Invalid JWT rejected
- SSE connectivity
- `sessionId` extraction from the SSE bootstrap event
- MCP `initialize`
- MCP `tools/list`
- MCP `tools/call` for `get_weather`
- MCP `tools/call` for `calculate`
- Azure OpenAI `POST /chat`
- Error handling for missing `sessionId` and invalid JSON

## Configuration

Both scripts support these environment variables:

- `GATEWAY_BASE_URL` — defaults to `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io`
- `OPENAI_MODEL` — defaults to `gpt-4.1`
- `JWT_ISSUER` — defaults to `kong-poc`
- `JWT_SECRET` — defaults to `poc-secret-change-me`
- `JWT_SUBJECT` — defaults to `poc-user`
- `JWT_TTL_SECONDS` — defaults to `3600`
- `SSE_TIMEOUT_SECONDS` — defaults to `20`
- `MESSAGE_TIMEOUT_SECONDS` — defaults to `60`
- `CHAT_TIMEOUT_SECONDS` — defaults to `60`
- `JWT_TOKEN` — optional explicit token override
- `INVALID_JWT_TOKEN` — optional invalid-token override
- `KEEP_TEST_ARTIFACTS=1` — keep scratch files under `test/.tmp-mcp-gateway-*`

## OAuth route family validation

The Konnect OAuth passthrough routes are:

- `GET /mcp/oauth/sse`
- `POST /mcp/oauth/messages`

These routes are protected by the Kong `openid-connect` plugin and expect a
real Microsoft Entra access token for the custom MCP audience. The gateway
validates issuer/signature/audience and does not require the `scp` claim for
the current Foundry POC.

### Automated checks

The following checks can be run now without a browser sign-in:

| Check | Expected | Actual |
| --- | --- | --- |
| `GET /mcp/oauth/sse` without `Authorization` | `401 Unauthorized` | `401 Unauthorized` |
| `OPTIONS /mcp/oauth/sse` from `https://foundry.azure.microsoft.com` | `200 OK` with CORS headers | `200 OK`; `Access-Control-Allow-Origin`, `...-Methods`, and `...-Headers` returned |
| `GET /mcp/oauth/sse` with `Bearer invalid-entra-token` | `401 Unauthorized` | `401 Unauthorized` |
| `GET /mcp/oauth/sse` with the existing HS256 JWT | `401 Unauthorized` | `401 Unauthorized` |
| `POST /mcp/oauth/messages?sessionId=test-session` without token | `401 Unauthorized` | `401 Unauthorized` |
| Existing JWT regression suite | `10/10` pass | `10/10` pass |

### Manual OAuth token testing guide

Real user-token validation still requires a browser-driven OAuth flow.

1. Get a user token with MSAL.js, Postman, or another interactive OAuth client.
2. Request the custom MCP scope if your client supports it:
   - `api://d50b1d91-8be2-48cd-9615-3fbba4e04a2b/MCP.Use`
3. Complete user sign-in and consent if prompted.
4. Paste the resulting access token into the request:

```powershell
$OAUTH_TOKEN = "<paste-token-from-browser>"
curl -N -H "Authorization: Bearer $OAUTH_TOKEN" https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/oauth/sse
```

Expected result:

- The SSE connection opens successfully.
- The bootstrap event advertises the OAuth message path.
- The downstream MCP server receives verified user headers such as:
  - `x-user-oid`
  - `x-user-upn`
  - `x-user-name`

Why this part is manual:

- Browser sign-in and consent are required for a real delegated user token.
- A client secret alone is not enough for user identity passthrough testing.
- In Foundry, Foundry performs this OAuth flow on the user's behalf.

### Dual-auth route comparison

| Route family | Endpoints | Token type | Automated status |
| --- | --- | --- | --- |
| JWT / key-based POC | `/mcp/sse`, `/mcp/messages` | HS256 JWT (`iss=kong-poc`) | Working; regression suite passes |
| OAuth passthrough | `/mcp/oauth/sse`, `/mcp/oauth/messages` | Microsoft Entra user access token | Route and rejection behavior verified; real success path pending manual browser test |

## Foundry-specific validation scenarios

These scripts do not automate Foundry itself, but they validate the exact gateway behavior Foundry depends on.

### How Foundry would authenticate

- Foundry should send `Authorization: Bearer <jwt>` on both:
  - `GET /mcp/sse`
  - `POST /mcp/messages?sessionId=<uuid>`
- For the current POC, the token must use:
  - `iss=kong-poc`
  - `HS256`
  - secret `poc-secret-change-me`

### Expected tool invocation pattern

Foundry should follow the same sequence used by the test suite:

1. Open `GET /mcp/sse`
2. Read the bootstrap event and extract `sessionId`
3. Send `initialize`
4. Send `notifications/initialized`
5. Send `tools/list`
6. Send `tools/call` for `get_weather` or `calculate`

### Validation steps for Foundry integration

1. Run `bash test/test-mcp-gateway.sh` to confirm the gateway baseline is healthy.
2. Register `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/sse` as the Foundry MCP endpoint.
3. Provide the same JWT auth header Foundry will use in production-like testing.
4. Confirm Foundry discovers both tools.
5. Trigger at least these two scenarios from Foundry:
   - weather request for a city such as Seattle
   - calculation request such as multiply 6 by 7
6. Verify Foundry receives structured tool results and can incorporate them into its response.

## Run the Bash script

```bash
bash test/test-mcp-gateway.sh
```

Git Bash on Windows:

```bash
export MSYS_NO_PATHCONV=1
bash test/test-mcp-gateway.sh
```

Override the model if your Azure OpenAI deployment name differs:

```bash
OPENAI_MODEL=my-model-name bash test/test-mcp-gateway.sh
```

## Run the PowerShell script

```powershell
powershell -ExecutionPolicy Bypass -File .\test\test-mcp-gateway.ps1
```

Or with overrides:

```powershell
$env:OPENAI_MODEL = "my-model-name"
powershell -ExecutionPolicy Bypass -File .\test\test-mcp-gateway.ps1
```

## Expected output

Example:

```text
[PASS] Invalid JWT is rejected by /mcp/sse
[PASS] SSE endpoint accepts a valid JWT
[PASS] SSE handshake returns a sessionId
[PASS] MCP initialize returns server metadata
[PASS] tools/list returns get_weather and calculate
[PASS] tools/call get_weather returns structured weather data
[PASS] tools/call calculate returns the expected result
[PASS] Missing sessionId is rejected with HTTP 400
[PASS] Invalid JSON is rejected with an error response
[PASS] Azure OpenAI /chat returns a valid completion

Passed: 10
Failed: 0
```

## Troubleshooting

### 401 / 403 responses

- Confirm `JWT_ISSUER` and `JWT_SECRET`
- If you supply `JWT_TOKEN`, make sure `iss=kong-poc` and the token is not expired

### SSE connects but no `sessionId` appears

- Verify Kong still routes both `/mcp/sse` and `/mcp/messages`
- Check whether SSE buffering/timeouts regressed in the gateway deployment

### `tools/list` or `tools/call` times out

- The SSE handshake may have succeeded while the companion `/mcp/messages` route failed
- Retry with `KEEP_TEST_ARTIFACTS=1` and inspect the captured files in `test/.tmp-mcp-gateway-*`
- In Foundry scenarios, also confirm the bearer token is sent on the POST leg, not just the initial SSE request

### `/chat` fails but MCP passes

- Confirm `OPENAI_MODEL` matches the deployed Azure OpenAI model name
- Verify the gateway still has Azure OpenAI access and the managed identity configuration has not regressed
