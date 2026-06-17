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

### `/chat` fails but MCP passes

- Confirm `OPENAI_MODEL` matches the deployed Azure OpenAI model name
- Verify the gateway still has Azure OpenAI access and the managed identity configuration has not regressed
