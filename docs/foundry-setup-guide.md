# Foundry Setup Guide for the Kong MCP Gateway

## Goal

This guide shows how to register the current Kong MCP Gateway in Microsoft Foundry using **key-based authentication** with a generated JWT.

## Before You Start

- Gateway SSE endpoint: `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/sse`
- Gateway message endpoint pattern: `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/messages?sessionId=<uuid>`
- Current tool names:
  - `get_weather`
  - `calculate`
- Auth header name: `Authorization`
- Auth header value format: `Bearer <jwt>`

Run one of the token generators first:

```bash
bash scripts/generate-foundry-jwt.sh
```

```powershell
.\scripts\generate-foundry-jwt.ps1
```

## Step 1 — Generate a JWT for Foundry

Use one of these commands:

```bash
bash scripts/generate-foundry-jwt.sh --ttl 3600 --issuer kong-poc --subject foundry-poc
```

```powershell
.\scripts\generate-foundry-jwt.ps1 -TtlSeconds 3600 -Issuer kong-poc -Subject foundry-poc
```

Copy the token output. You will paste it into the Foundry project connection as:

```text
Bearer <copied-token>
```

## Step 2 — Open your Foundry project

In the Foundry portal:

1. Open the correct **workspace**.
2. Open the target **project**.
3. Navigate to the area for **connections**, **tools**, or **external MCP servers**.

> **Screenshot placeholder:** The project landing page showing the left navigation with the section where project connections or MCP server integrations are managed.

## Step 3 — Create the project connection

Create a new connection for an external MCP server.

Use these values:

- **Server URL:** `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/sse`
- **Server label:** `kong-mcp-gateway-poc`
- **Authentication type:** `Key-based authentication`
- **Credential name:** `Authorization`
- **Credential value:** `Bearer <generated-jwt-token>`
- **Approval setting:** choose your preferred value for `require_approval` in agent usage; `true` is safer for first validation

Expected result:

- Foundry creates a **project connection** entry
- The connection receives a **project_connection_id**

> **Screenshot placeholder:** The new connection form with fields for server URL, authentication type, credential name, and credential value.

## Step 4 — Save and capture the connection ID

After saving:

1. Open the created connection details.
2. Copy the generated **project connection ID**.
3. Confirm the connection status is healthy or ready.

You will use that ID in agent configuration.

> **Screenshot placeholder:** The saved project connection details panel showing the connection name, status, and project connection ID.

## Step 5 — Configure the Foundry agent

In the agent configuration, provide the MCP tool/server metadata that points to the saved project connection.

Use values like these:

```json
{
  "server_url": "https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/sse",
  "server_label": "kong-mcp-gateway-poc",
  "require_approval": true,
  "project_connection_id": "<your-project-connection-id>"
}
```

Notes:

- `server_url` must be the **SSE endpoint**, not `/mcp/messages`
- `project_connection_id` must reference the connection created in Step 3
- `require_approval` is a policy choice; enable it for cautious rollout

> **Screenshot placeholder:** The agent editing screen showing where MCP tools or external server connections are attached to the agent.

## Step 6 — Validate the connection

Validate in this order:

1. Confirm the baseline gateway works:

   ```bash
   bash test/test-mcp-gateway.sh
   ```

2. Use the Foundry UI or test surface to connect the agent to the MCP server.
3. Verify the agent reaches initialization and tool discovery.
4. Confirm Foundry sees both tools:
   - `get_weather`
   - `calculate`

## Step 7 — Run tool-backed prompts

Use prompts such as:

- `Use the weather tool to tell me the current weather in Seattle.`
- `Use the calculate tool to multiply 6 by 7.`

Expected behavior:

- Foundry opens `GET /mcp/sse`
- Foundry receives the SSE bootstrap event with a `sessionId`
- Foundry sends JSON-RPC messages to `/mcp/messages?sessionId=...`
- Kong validates the same bearer token on both legs
- The agent returns tool-derived output instead of a model-only guess

> **Screenshot placeholder:** A successful chat transcript showing the tool invocation and the tool-derived result.

## Testing Checklist

- [ ] JWT token generated successfully
- [ ] Project connection saved with key-based auth
- [ ] `Authorization` header name entered correctly
- [ ] Credential value includes the `Bearer ` prefix
- [ ] Agent references the correct `project_connection_id`
- [ ] Foundry discovers `get_weather` and `calculate`
- [ ] Sample weather prompt succeeds
- [ ] Sample math prompt succeeds

## Troubleshooting

### 401 Unauthorized on connect

Check:

- token is not expired
- token was generated with `iss=kong-poc`
- token was signed with `poc-secret-change-me` or the current configured secret
- credential name is exactly `Authorization`
- credential value includes the `Bearer ` prefix
- Foundry sends the same header on both the SSE and message requests

### Connection saves but tool discovery fails

Check:

- `server_url` points to `/mcp/sse`
- Foundry supports the SSE bootstrap plus POST message flow
- Foundry preserves the returned `sessionId` when calling `/mcp/messages`

### Agent connects but prompts do not use tools

Check:

- the agent is actually bound to the intended `project_connection_id`
- approval requirements are satisfied
- the prompt clearly asks for weather or calculation behavior

### Token expires during testing

Generate a fresh token:

```bash
bash scripts/generate-foundry-jwt.sh --ttl 3600
```

or:

```powershell
.\scripts\generate-foundry-jwt.ps1 -TtlSeconds 3600
```

Then update the Foundry project connection credential value.

## What This Setup Automates vs. What Stays Manual

### Automated now

- JWT creation for the current Kong auth model
- repeatable operator instructions
- baseline gateway validation with the existing MCP test suite

### Still manual in Foundry

- creating the project connection in the portal
- copying the token into the credential value
- attaching the connection to an agent
- refreshing the credential when the token expires

## Next-Step Production Improvements

If this POC is successful, the next decisions are:

1. stay on shared key-based auth and automate token rotation, or
2. move to OAuth identity passthrough for per-user identity, or
3. move to Entra authentication for managed service identity and automatic token rotation
