# Kong AI Gateway POC for Microsoft Foundry

Developer-focused proof of concept for running **Kong 3.7 in DB-less mode on Azure Container Apps** as an **AI Gateway** in front of **Azure OpenAI (GPT-4.1)**. Kong validates a client JWT, then swaps it for an Azure managed identity token before proxying the request upstream.

> [!WARNING]
> **POC / demo only.** This repo is intentionally simple and is **not production-ready**. Rotate the demo JWT secret, harden auth, and formalize secret management before any real use.

## Architecture

```text
Client
  |
  | 1) POST /chat
  |    Authorization: Bearer <client JWT>
  v
Kong 3.7 on Azure Container Apps (DB-less, declarative config)
  |
  | 2) jwt plugin validates HS256 token
  |    issuer (iss): kong-poc
  |
  | 3) post-function plugin calls ACA managed identity endpoint
  |    and fetches an access token for https://cognitiveservices.azure.com/
  |
  | 4) Kong replaces Authorization header with:
  |    Bearer <managed identity token>
  v
Azure OpenAI (GPT-4.1)
  |
  v
Response returned through Kong to client
```

### Current deployment target

- **Resource group:** `rg-kong-aca`
- **Region:** `eastus2`
- **Gateway FQDN:** `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io`
- **Runtime:** Azure Container Apps with **system-assigned managed identity**
- **Auth to Azure OpenAI:** `Cognitive Services OpenAI User` role on the target Azure OpenAI resource
- **API key storage:** none

## Prerequisites

- Azure CLI (`az`) with access to create resource groups, ACR, and Container Apps
- An Azure subscription selected in Azure CLI
- Bash shell to run `scripts/deploy-simple.sh`
- **Windows Git Bash:** set `MSYS_NO_PATHCONV=1` for manual Azure CLI commands if needed (the deploy script exports it)
- Python 3 for generating a demo JWT during testing
- An Azure OpenAI resource reachable by Kong

Login and choose a subscription:

```bash
az login
az account set --subscription "<your-subscription-id-or-name>"
```

## Quick Start / Deployment

This repo uses a **4-phase manual deployment** script:

1. Provision **ACR**, **Log Analytics**, and **Container App Environment**
2. Build the Kong image in **ACR cloud build** (`az acr build`) — **no local Docker required**
3. Build and deploy the internal **Mock API** and **MCP Server** Container Apps
4. Deploy the **Kong Container App** with its custom image

Run:

```bash
bash scripts/deploy-simple.sh
```

After deployment, grant the Container App's managed identity access to Azure OpenAI if you have not already:

```bash
RG="rg-kong-aca"
APP_NAME="kongai-gw"
OPENAI_RG="<azure-openai-resource-group>"
OPENAI_ACCOUNT="<azure-openai-account-name>"

PRINCIPAL_ID=$(az containerapp show -g "$RG" -n "$APP_NAME" --query identity.principalId -o tsv)
OPENAI_ID=$(az cognitiveservices account show -g "$OPENAI_RG" -n "$OPENAI_ACCOUNT" --query id -o tsv)

az role assignment create \
  --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" \
  --scope "$OPENAI_ID"
```

## Testing

### 1) Generate a demo JWT

The current declarative config expects:

- **issuer (`iss`)**: `kong-poc`
- **algorithm**: `HS256`
- **secret**: `poc-secret-change-me`

Generate a token with Python 3 (standard library only):

```bash
python - <<'PY'
import base64, hashlib, hmac, json, time

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

header = {"alg": "HS256", "typ": "JWT"}
payload = {
    "iss": "kong-poc",
    "sub": "poc-user",
    "exp": int(time.time()) + 3600
}
secret = b"poc-secret-change-me"

signing_input = ".".join([
    b64url(json.dumps(header, separators=(",", ":")).encode()),
    b64url(json.dumps(payload, separators=(",", ":")).encode())
]).encode()

signature = hmac.new(secret, signing_input, hashlib.sha256).digest()
print(signing_input.decode() + "." + b64url(signature))
PY
```

### 2) Send a test request

```bash
FQDN="https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io"
TOKEN="<paste-jwt-here>"

curl -i "$FQDN/chat" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4.1",
    "messages": [
      { "role": "user", "content": "Reply with: gateway ok" }
    ]
  }'
```

If your Azure OpenAI deployment name differs from `gpt-4.1`, replace the `model` value accordingly.

## Phase 4 — Microsoft Foundry Integration

This phase documents how to point a Foundry MCP-capable client at the deployed Kong gateway. Foundry product surfaces can label the settings differently, so use the values below when configuring a custom MCP server or external tool connector.

### Microsoft Foundry Integration

#### Prerequisites

- A Foundry workspace and project where custom MCP server registration is allowed
- A Foundry client or agent surface that supports **SSE-based MCP** connections
- Outbound HTTPS connectivity from Foundry to:
  - `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/sse`
  - `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/messages`
- A way to provision and store a bearer token for the gateway
- Agreement that the current auth model is **POC only**:
  - issuer: `kong-poc`
  - algorithm: `HS256`
  - secret: `poc-secret-change-me`

#### Configuration Steps

1. **Configure the MCP endpoint in Foundry**
   - Register the Kong MCP Gateway SSE endpoint:
     - `https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/sse`
   - Set the transport to **Server-Sent Events (SSE)**.
   - Do not hardcode a session-specific `/mcp/messages` URL up front; the SSE bootstrap flow returns the `sessionId` that Foundry must use.
2. **Set up authentication**
   - Provision a JWT signed with the POC secret and `iss=kong-poc`.
   - Configure Foundry to send `Authorization: Bearer <token>` when opening `GET /mcp/sse`.
   - Ensure the same bearer token is also sent on subsequent `POST /mcp/messages?sessionId=<uuid>` calls.
   - For production, replace the shared secret model with managed key storage and the auth mechanism required by your Foundry environment.
3. **Register the MCP server**
   - After the SSE connection opens, Foundry should:
     - read the bootstrap event containing the message endpoint
     - send `initialize`
     - send `notifications/initialized`
     - send `tools/list`
   - Successful registration exposes the gateway tools to the Foundry agent/session.

#### Available Tools

- `get_weather(location: string)` — returns mock weather data for the requested city
- `calculate(operation: string, a: number, b: number)` — performs `add`, `subtract`, or `multiply`

#### Testing

- First validate the gateway directly with:
  - `bash test/test-mcp-gateway.sh`
- Then validate from Foundry:
  1. Connect to the MCP server
  2. Confirm `tools/list` returns `get_weather` and `calculate`
  3. Ask Foundry to invoke:
     - `get_weather` with a prompt such as “What is the weather in Seattle?”
     - `calculate` with a prompt such as “Multiply 6 and 7.”

#### Expected Behavior

- Foundry should show a successful MCP connection and tool discovery result.
- `get_weather` should return structured weather fields including `location`, `temperature`, `condition`, `humidity`, and `timestamp`.
- `calculate` should return `operation`, `a`, `b`, and `result`.
- When the Foundry experience supports tool-aware answers, the model should incorporate the tool result into its response.

#### Troubleshooting

- **401 / 403 from `/mcp/sse` or `/mcp/messages`:** confirm the JWT is unexpired, signed with `poc-secret-change-me`, and uses `iss=kong-poc`.
- **SSE opens but tools never load:** Foundry may not be sending follow-up `POST /mcp/messages?sessionId=...` requests or may be omitting the bearer token on those requests.
- **404 `Unknown MCP session`:** the `sessionId` from the SSE bootstrap was not preserved or the SSE session closed before the POST request was sent.
- **Timeouts or stalled tool calls:** verify the client supports SSE transports and that `/mcp/sse` and `/mcp/messages` remain routed through Kong.
- **Protocol mismatch:** validate that the Foundry MCP client supports the same JSON-RPC-over-SSE pattern used by this gateway.

For the full guide, see:

- `docs/foundry-integration.md`
- `docs/architecture.md`

## Project Structure

```text
.
├── Dockerfile                  # Kong 3.7 image with custom entrypoint for managed identity env capture
├── docs/
│   ├── architecture.md         # End-to-end architecture, deployment flow, and key decisions
│   └── foundry-integration.md  # Detailed Microsoft Foundry integration guide
├── kong.yaml                   # Declarative Kong config: consumer, service, route, plugins
├── infra/
│   ├── acr.bicep               # Phase 1 infra: ACR, Log Analytics, Container App Environment
│   ├── main.bicep              # Kong Container App deploy: probes, ACR auth, runtime env
│   ├── mock-api.bicep          # Internal Mock API Container App
│   └── mcp-server.bicep        # Internal MCP Server Container App
├── mock-api/                   # Internal mock REST API used by the MCP server
├── mcp-server/                 # MCP-over-SSE server that wraps mock-api endpoints as tools
├── scripts/
│   └── deploy-simple.sh        # 4-phase manual deployment script
└── .github/
    └── workflows/
        └── deploy.yml          # CI/CD workflow (planned / being created in parallel; may be absent here)
```

## Configuration

### `kong.yaml`

The gateway is fully declarative and currently defines:

- `_format_version: "2.1"` for Kong compatibility with nested JWT credentials
- One **POC consumer**: `poc-user`
- One **JWT credential**:
  - key / issuer: `kong-poc`
  - algorithm: `HS256`
- One **service**: `chat`
- One **route**: `POST /chat`
- Service-level plugins:
  - `jwt` for client token validation
  - `post-function` for managed identity token fetch + bearer injection
  - `rate-limiting`
  - `cors`

Common edits:

- **Change the upstream model endpoint:** update `services[].url`
- **Add routes:** append entries under `services[].routes`
- **Adjust auth behavior:** edit the service-level `jwt` plugin config
- **Tune request handling:** update rate limiting or CORS plugin settings

### `Dockerfile`

The image:

- Starts from `kong:3.7`
- Copies `kong.yaml` into `/etc/kong/kong.yaml`
- Runs Kong in **DB-less** mode
- Enables `KONG_UNTRUSTED_LUA=on` for the post-function plugin
- Captures `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` before nginx startup so Lua can retrieve managed identity tokens

## Security Notes

- **POC secret in repo:** `poc-secret-change-me` must be rotated before any shared or non-local use
- **Managed identity only:** this design avoids storing Azure OpenAI API keys in Kong or Container App secrets
- **Role assignment required:** the Container App identity needs `Cognitive Services OpenAI User` on the target Azure OpenAI resource
- **Demo auth only:** HS256 shared-secret JWTs are acceptable for this POC, but not the long-term auth strategy
- **Future hardening needed:** add real secret management, production identity boundaries, observability, and CI/CD policy gates before broader rollout
