# Microsoft Foundry Integration Guide

This guide documents the validated Phase 4 integration shape for connecting a Foundry MCP-capable client to the Kong MCP Gateway.

> [!WARNING]
> The current JWT setup is **POC only**. It uses `iss=kong-poc` and the shared secret `poc-secret-change-me` with HS256. Replace it before any production use.

## Architecture Overview

```text
Microsoft Foundry client / agent
  |
  | Authorization: Bearer <gateway JWT>
  | 1) GET /mcp/sse
  v
Kong MCP Gateway
  |
  | 2) JWT validation at Kong
  | 3) Proxy over HTTPS to internal ACA MCP server
  v
MCP Server on Azure Container Apps
  |
  | 4) GET /api/weather or POST /api/calculate
  v
Mock API on Azure Container Apps
  |
  | 5) Structured result
  v
MCP Server formats MCP tool response
  |
  | 6) SSE + JSON-RPC response through Kong
  v
Microsoft Foundry client / agent
```

## Prerequisites

- A Foundry workspace and project that allow external MCP server configuration
- A Foundry runtime that supports:
  - SSE bootstrap connections
  - JSON-RPC POST messages to a companion endpoint
  - bearer-token authentication
- Network egress from Foundry to:
  - `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/sse`
  - `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/messages`
- A token provisioning path for the Kong JWT

Because Foundry UX varies, treat the remainder of this guide as a value map rather than a click-by-click UI walkthrough.

## Authentication Flow

### Current POC lifecycle

1. A JWT is minted for Foundry with:
   - issuer: `kong-poc`
   - algorithm: `HS256`
   - secret: `poc-secret-change-me`
   - expiration: short-lived (`exp` claim required)
2. Foundry sends `Authorization: Bearer <token>` to `GET /mcp/sse`.
3. Kong validates the JWT before allowing the SSE connection.
4. The MCP SDK emits the message endpoint containing a `sessionId`.
5. Foundry reuses the same bearer token when sending `POST /mcp/messages?sessionId=<uuid>`.
6. Kong validates each follow-up message request independently.
7. Downstream traffic from Kong to the MCP server and from the MCP server to the Mock API is trusted internal traffic in the Container App Environment.

### Practical guidance

- Use short-lived tokens and refresh them outside the SSE session lifecycle.
- Make sure Foundry does not drop the `Authorization` header on the POST leg of the protocol.
- If your Foundry environment mandates a different auth method, keep the same endpoint mapping but replace the Kong plugin strategy.

## MCP Protocol Details

### Transport

- **Bootstrap:** `GET /mcp/sse`
- **Message channel:** `POST /mcp/messages?sessionId=<uuid>`
- **Protocol shape:** JSON-RPC 2.0 over SSE + HTTP POST

### Required client sequence

1. Open the SSE stream:

```http
GET /mcp/sse HTTP/1.1
Host: kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io
Authorization: Bearer <jwt>
Accept: text/event-stream
```

2. Parse the bootstrap event and extract the message endpoint:

```text
event: endpoint
data: /mcp/messages?sessionId=12345678-1234-1234-1234-123456789abc
```

3. Send `initialize`:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-03-26",
    "capabilities": {},
    "clientInfo": {
      "name": "foundry-client",
      "version": "1.0.0"
    }
  }
}
```

4. Send `notifications/initialized`
5. Send `tools/list`
6. Send `tools/call` when Foundry chooses a tool

### What Foundry needs to implement

- Persist the `sessionId` for the lifetime of the SSE stream
- Send JSON request bodies to the exact endpoint returned by the bootstrap event
- Keep the SSE stream open long enough to receive asynchronous results
- Accept structured MCP tool results, not just plain text
- Handle transport failures such as:
  - `401` unauthorized
  - `404` unknown session
  - `429` rate limited
  - `500`/`502` upstream failure

If a Foundry surface only supports stdio MCP or streamable HTTP without the legacy SSE bootstrap flow, it will need a compatible bridge layer before it can use this gateway as-is.

## Tool Schemas

## `get_weather`

### Input schema

```json
{
  "type": "object",
  "properties": {
    "location": {
      "type": "string",
      "description": "City name"
    }
  },
  "required": ["location"]
}
```

### Output schema

Representative successful payload:

```json
{
  "location": "Seattle",
  "temperature": 70,
  "condition": "Sunny",
  "humidity": 60,
  "timestamp": "2026-06-17T07:00:00.000Z"
}
```

Field notes:

- `location`: string
- `temperature`: integer-like number from the mock data set
- `condition`: string such as `Sunny`, `Cloudy`, `Rainy`, `Partly Cloudy`, or `Overcast`
- `humidity`: integer-like number
- `timestamp`: ISO 8601 timestamp

### MCP response shape

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"location\":\"Seattle\",\"temperature\":70,\"condition\":\"Sunny\",\"humidity\":60,\"timestamp\":\"2026-06-17T07:00:00.000Z\"}"
      }
    ],
    "structuredContent": {
      "location": "Seattle",
      "temperature": 70,
      "condition": "Sunny",
      "humidity": 60,
      "timestamp": "2026-06-17T07:00:00.000Z"
    }
  }
}
```

## `calculate`

### Input schema

```json
{
  "type": "object",
  "properties": {
    "operation": {
      "type": "string",
      "enum": ["add", "subtract", "multiply"]
    },
    "a": {
      "type": "number"
    },
    "b": {
      "type": "number"
    }
  },
  "required": ["operation", "a", "b"]
}
```

### Output schema

```json
{
  "operation": "multiply",
  "a": 6,
  "b": 7,
  "result": 42
}
```

### MCP response shape

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"operation\":\"multiply\",\"a\":6,\"b\":7,\"result\":42}"
      }
    ],
    "structuredContent": {
      "operation": "multiply",
      "a": 6,
      "b": 7,
      "result": 42
    }
  }
}
```

### Error behavior

- Invalid `location` input returns an error from the Mock API, which the MCP server surfaces as `isError: true`.
- Invalid `operation` or non-numeric operands return a Mock API `400`, which is also surfaced as an MCP tool error.

Representative error payload:

```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"error\":\"Failed to complete calculation\",\"details\":{\"error\":\"Invalid operation. Must be one of: add, subtract, multiply\"}}"
    }
  ],
  "isError": true
}
```

## Example Interactions

### Initialize handshake

Request:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-03-26",
    "capabilities": {},
    "clientInfo": {
      "name": "foundry-client",
      "version": "1.0.0"
    }
  }
}
```

Expected response characteristics:

- `jsonrpc` = `2.0`
- `result.serverInfo.name` = `mock-api-mcp-server`
- `result.protocolVersion` is present

### Tool discovery

Request:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list",
  "params": {}
}
```

Expected result: a `tools` array containing `get_weather` and `calculate`.

### Weather tool call

Request:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "get_weather",
    "arguments": {
      "location": "Seattle"
    }
  }
}
```

Expected behavior:

- Foundry receives structured weather data
- the returned values vary by request because the Mock API randomizes weather conditions

### Calculation tool call

Request:

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "tools/call",
  "params": {
    "name": "calculate",
    "arguments": {
      "operation": "multiply",
      "a": 6,
      "b": 7
    }
  }
}
```

Expected result:

```json
{
  "operation": "multiply",
  "a": 6,
  "b": 7,
  "result": 42
}
```

## Testing the Foundry Integration

1. Confirm the gateway baseline with `bash test/test-mcp-gateway.sh`.
2. In Foundry, register the SSE endpoint and bearer token.
3. Verify the connection reaches `initialize` and `tools/list`.
4. Trigger a weather prompt and a math prompt.
5. Confirm the Foundry response contains tool-derived content instead of a hallucinated answer.

Suggested prompts:

- “Use the weather tool to tell me the current weather in Seattle.”
- “Use the calculate tool to multiply 6 by 7.”

## Security Considerations

- **JWT rotation:** the repo secret is static and public to project contributors; move it to managed secret storage immediately for any real environment.
- **Key management:** prefer RS256 or OAuth2/OIDC-backed credentials if Foundry supports them.
- **Token scope:** use dedicated credentials for Foundry clients rather than sharing a broad demo token.
- **Transport security:** keep TLS termination at the public Kong endpoint and avoid any non-HTTPS public MCP endpoint.
- **Rate limiting:** the chat route already has a rate-limiting plugin; add equivalent per-client limits for MCP traffic before broader rollout.
- **Observability:** log connection open/close, tool name, latency, and upstream failures without logging secrets or full bearer tokens.

## Production Readiness

Before production, change the following:

1. **Replace the POC JWT secret**
   - remove `poc-secret-change-me`
   - move signing material to Azure Key Vault or the identity platform approved for Foundry
2. **Enable rate limiting policies**
   - enforce per-client or per-consumer quotas on `/mcp/sse` and `/mcp/messages`
   - plan for SSE connection concurrency limits as well as request-per-minute limits
3. **Add monitoring and alerting**
   - Container App logs and metrics
   - Application Insights or equivalent telemetry pipeline
   - alerts for 401/429/5xx spikes, tool latency, and dropped SSE sessions
4. **Consider enabling Kong Admin API for management**
   - only on an internal-only port
   - never expose it publicly
   - use it for route/plugin inspection and operational debugging
5. **Validate protocol compatibility**
   - confirm the Foundry MCP client supports the server protocol version returned by `initialize`
6. **Harden downstream trust**
   - consider auth between Kong and the MCP server if the network boundary broadens
   - introduce stronger client identity separation than the shared POC consumer

## Related Documents

- `README.md`
- `docs/architecture.md`
- `test/README.md`
- `.squad/decisions.md`
- `.squad/decisions/decisions.md`
