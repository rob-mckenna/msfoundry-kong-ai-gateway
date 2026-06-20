# Kong AI Gateway — Microsoft Foundry POC

> ⚠️ **POC / demo only.** Not production-ready. Rotate the demo credentials, harden auth, and formalise secret management before any real use.

Kong 3.7 running in DB-less mode on **Azure Container Apps**, acting as an **AI Gateway** in front of **Azure OpenAI** and an **MCP-over-SSE server** wired to Microsoft Foundry. Kong handles all three authentication models (JWT, API Key, OAuth), swaps client credentials for a managed identity token when calling Azure OpenAI, and routes Foundry tool invocations to an internal MCP server.

---

## ⚡ Quick Start

1. **Prerequisites:** Install required tools — see [Setup Guide](docs/repo-setup.md)
2. **Configure:** Run `.\scripts\setup-repo.ps1` (creates credential files, checks tooling)
3. **Deploy:** Run `bash scripts/deploy-simple.sh` (4-phase cloud build + infra deploy)
4. **Test:** Run `bash test/test-mcp-gateway.sh` — expect `10/10 PASS`
5. **Explore:** Try the [MCP Inspector](docs/mcp-inspector-setup.md) or connect from [Microsoft Foundry](docs/foundry-final-configuration.md)

---

## 🗺️ Architecture

```text
External Clients / Microsoft Foundry
          │
          │ HTTPS
          ▼
┌─────────────────────────────────────────────────┐
│        Kong 3.7 Gateway (ACA — public)           │
│                                                  │
│  POST /chat ──────────────────────────────────► Azure OpenAI (GPT-4.1)
│    └─ jwt plugin validates HS256 token           │ ↑ managed identity token
│    └─ post-function fetches MI token             │
│                                                  │
│  GET  /mcp/sse          (JWT)                    │
│  POST /mcp/messages     (JWT)                    │
│  GET  /mcp/key/sse      (API Key)      ─────────►  MCP Server (ACA — internal)
│  POST /mcp/key/messages (API Key)                       │
│  GET  /mcp/oauth/sse    (Entra OAuth)                   ▼
│  POST /mcp/oauth/msgs   (Entra OAuth)           Mock API (ACA — internal)
│                                                  (weather, calculate)
└─────────────────────────────────────────────────┘
          │
          ▼
  Kong Konnect (control plane — optional)
  Azure Container Registry (image store)
  Log Analytics (unified logging)
```

---

## ✨ Features

| Feature | Status |
|---|---|
| 🔒 **JWT authentication** (`/mcp/sse`, `/mcp/messages`, `/chat`) | ✅ Validated |
| 🔑 **API Key authentication** (`/mcp/key/sse`, `/mcp/key/messages`) | ✅ Validated |
| 🪪 **OAuth / Entra passthrough** (`/mcp/oauth/sse`, `/mcp/oauth/messages`) | ✅ Configured |
| 🤖 **Azure OpenAI proxy** via managed identity (no stored API keys) | ✅ Validated |
| 🛠️ **MCP Gateway** — Foundry-compatible SSE + JSON-RPC tool server | ✅ Validated |
| 📦 **Kong Konnect integration** — control plane with ACA data plane | ✅ Configured |
| 🏗️ **Infrastructure as Code** — Bicep, ACR cloud builds, no local Docker | ✅ Validated |
| 🔄 **GitHub Actions CI/CD** — OIDC federated identity, staged deploy | ✅ Configured |
| 🧪 **Automated test suite** — Bash + PowerShell, 10 gateway tests | ✅ Validated |

---

## 🧩 Components

| Component | Role | Location |
|---|---|---|
| **Kong Gateway** | Public ingress, auth enforcement, proxy | `kong.yaml`, `Dockerfile`, `infra/main.bicep` |
| **MCP Server** | SSE transport + tool registration for Foundry | `mcp-server/` |
| **Mock API** | Internal demo backend (`get_weather`, `calculate`) | `mock-api/` |
| **Azure OpenAI** | LLM upstream for `/chat` | External — accessed via managed identity |
| **Azure Container Registry** | Stores all container images | `infra/acr.bicep` |
| **Container Apps Environment** | Shared runtime and internal DNS | `infra/acr.bicep` |
| **Kong Konnect** | Optional control plane (needed for OAuth plugin) | `docs/kong-konnect-setup.md` |

---

## 🔐 Authentication Paths

<details>
<summary><strong>Path 1 — JWT Bearer Token</strong> (baseline)</summary>

- **Routes:** `GET /mcp/sse`, `POST /mcp/messages`, `POST /chat`
- **How:** `Authorization: Bearer <HS256-JWT>` — issuer `kong-poc`, secret `poc-secret-change-me`
- **Generate:** `.\scripts\generate-foundry-jwt.ps1`
- **Guide:** [Foundry Integration](docs/foundry-integration.md)

</details>

<details>
<summary><strong>Path 2 — API Key</strong> (simplest for tooling)</summary>

- **Routes:** `GET /mcp/key/sse`, `POST /mcp/key/messages`
- **How:** `X-API-Key: <key>` header — key stored in `api-key-config.json`
- **Setup:** [Foundry Key Auth Setup](docs/foundry-key-auth-setup.md)
- **Recommended for:** MCP Inspector, local dev, Foundry POC connections

</details>

<details>
<summary><strong>Path 3 — OAuth / Entra ID</strong> (identity passthrough)</summary>

- **Routes:** `GET /mcp/oauth/sse`, `POST /mcp/oauth/messages`
- **How:** Entra-issued access token validated at Kong via OIDC/JWKS; verified claims forwarded downstream
- **Requires:** Kong Konnect (`openid-connect` enterprise plugin)
- **Setup:** [Entra App Registration](docs/entra-app-registration.md) → [OAuth Config](docs/kong-oauth-config.md)
- **Requires:** `entra-oauth-config.json` populated from template

</details>

---

## 🚀 Deployment

### Prerequisites

See [docs/repo-setup.md](docs/repo-setup.md) for the full tool list. Quick summary:

| Tool | Required for |
|---|---|
| `az` (Azure CLI) | All deployments |
| `git` | Source control |
| `node` / `npm` | MCP server runtime + tests |
| `python` / `python3` | JWT generation |
| Bash (Git Bash on Windows) | Deploy + test scripts |

```powershell
# First-time setup — checks tools, creates credential file stubs
.\scripts\setup-repo.ps1

# Also download deck and kongctl (needed for Konnect path)
.\scripts\setup-repo.ps1 -InstallTools
```

### Deploy to Azure

The deploy script runs four phases — no local Docker required (images build in ACR):

```bash
# Phase 1: ACR + Log Analytics + Container Apps Environment
# Phase 2: Build Kong image in ACR cloud build
# Phase 2.5: Build + deploy Mock API (internal)
# Phase 2.6: Build + deploy MCP Server (internal)
# Phase 3: Deploy Kong Container App with custom image

bash scripts/deploy-simple.sh
```

After deploy, grant the Kong managed identity access to Azure OpenAI:

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

### Kong Konnect deployment (OAuth path)

To enable OAuth you need Kong Konnect. See [Kong Konnect Quick Start](docs/kong-konnect-quickstart.md).

```powershell
# 1. Set up Konnect control plane + Key Vault cert
.\scripts\konnect-setup.ps1 -Pat $env:KONNECT_PAT -KeyVaultName <kv>

# 2. Deploy Konnect-backed ACA data plane
.\scripts\deploy-konnect-dataplane.ps1

# 3. Sync existing gateway config into Konnect
.\scripts\konnect-sync-config.ps1 -Pat $env:KONNECT_PAT

# 4. Add OAuth route family + openid-connect plugin
.\scripts\konnect-add-oauth-routes.ps1 -Pat $env:KONNECT_PAT
```

---

## 🧪 Testing

```bash
# Full MCP gateway test suite (10 tests — JWT + chat)
bash test/test-mcp-gateway.sh

# PowerShell variant
.\test\test-mcp-gateway.ps1
```

### MCP Inspector (interactive)

```bash
# API Key (simplest)
npx @modelcontextprotocol/inspector sse \
  "https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/key/sse" \
  --header "X-API-Key: <your-key>"

# JWT
npx @modelcontextprotocol/inspector sse \
  "https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/sse" \
  --header "Authorization: Bearer <your-jwt>"
```

Full guide: [MCP Inspector Setup](docs/mcp-inspector-setup.md)

### Manual JWT generation

```bash
# PowerShell
.\scripts\generate-foundry-jwt.ps1

# Bash
bash scripts/generate-foundry-jwt.sh
```

---

## 🔌 MCP Tools

Two tools are exposed through the gateway to Foundry agents:

| Tool | Description | Parameters |
|---|---|---|
| `get_weather` | Returns mock weather for a city | `location: string` |
| `calculate` | Performs arithmetic | `operation: add\|subtract\|multiply`, `a: number`, `b: number` |

---

## 🗂️ Documentation Index

### Setup

| Doc | Purpose |
|---|---|
| [repo-setup.md](docs/repo-setup.md) | Prerequisites, first-time setup, credential files |
| [squad-automated-setup.md](docs/squad-automated-setup.md) | Automated setup via Squad agents |
| [foundry-setup-guide.md](docs/foundry-setup-guide.md) | Microsoft Foundry project setup |
| [foundry-final-configuration.md](docs/foundry-final-configuration.md) | Final Foundry connection config steps |
| [foundry-key-auth-setup.md](docs/foundry-key-auth-setup.md) | API Key auth setup for Foundry |

### Konnect

| Doc | Purpose |
|---|---|
| [kong-konnect-quickstart.md](docs/kong-konnect-quickstart.md) | Fastest path to a running Konnect data plane |
| [kong-konnect-setup.md](docs/kong-konnect-setup.md) | Full Konnect setup walkthrough |
| [kong-konnect-automation.md](docs/kong-konnect-automation.md) | Script-based automation for Konnect |
| [konnect-automation-checklist.md](docs/konnect-automation-checklist.md) | Step-by-step Konnect cutover checklist |
| [kong-yaml-to-konnect.md](docs/kong-yaml-to-konnect.md) | Migrating from DB-less `kong.yaml` to Konnect |
| [kong-konnect-troubleshooting.md](docs/kong-konnect-troubleshooting.md) | Konnect-specific troubleshooting |

### OAuth / Entra

| Doc | Purpose |
|---|---|
| [entra-app-registration.md](docs/entra-app-registration.md) | Creating Entra app registrations |
| [kong-oauth-config.md](docs/kong-oauth-config.md) | Configuring `openid-connect` plugin in Konnect |
| [oauth-implementation-plan.md](docs/oauth-implementation-plan.md) | OAuth design decisions and phasing |
| [oauth-implementation-phases.md](docs/oauth-implementation-phases.md) | Phase-by-phase OAuth implementation guide |
| [oauth-testing.md](docs/oauth-testing.md) | How to test the OAuth route family |

### Architecture & Reference

| Doc | Purpose |
|---|---|
| [architecture.md](docs/architecture.md) | End-to-end system architecture, data flows, component map |
| [foundry-integration.md](docs/foundry-integration.md) | Detailed Foundry MCP integration guide |
| [foundry-auth-analysis.md](docs/foundry-auth-analysis.md) | Auth model analysis and trade-offs |
| [key-auth-migration-plan.md](docs/key-auth-migration-plan.md) | Migration plan from JWT to API Key baseline |
| [poc-completion-status.md](docs/poc-completion-status.md) | Current POC status and remaining steps |

### Testing & Debugging

| Doc | Purpose |
|---|---|
| [mcp-inspector-setup.md](docs/mcp-inspector-setup.md) | Using MCP Inspector for local tool testing |
| [test/README.md](test/README.md) | Test suite overview |

---

## 📁 Project Structure

```text
.
├── Dockerfile                      # Kong 3.7 DB-less with managed identity env capture
├── Dockerfile.konnect              # Kong 3.7 variant for Konnect data plane
├── kong.yaml                       # Declarative gateway config (DB-less baseline)
├── konnect-connection.json.template  # Konnect control plane connection template
├── api-key-config.json.template    # API Key credential template
├── entra-oauth-config.json.template  # Entra OAuth config template
│
├── infra/
│   ├── acr.bicep                   # Phase 1: ACR + Log Analytics + ACA Environment
│   ├── main.bicep                  # Kong Container App
│   ├── mock-api.bicep              # Mock API Container App (internal)
│   └── mcp-server.bicep            # MCP Server Container App (internal)
│
├── mcp-server/                     # MCP-over-SSE server (Node.js 22, @modelcontextprotocol/sdk)
├── mock-api/                       # Internal REST backend (Express.js, weather + calculate)
│
├── scripts/
│   ├── setup-repo.ps1              # Onboarding: tool checks, credential file stubs, binary downloads
│   ├── deploy-simple.sh            # 4-phase Azure deploy (no local Docker)
│   ├── konnect-setup.ps1 / .sh     # Konnect control plane + Key Vault cert setup
│   ├── konnect-sync-config.ps1/.sh # Sync kong.yaml into Konnect
│   ├── konnect-add-oauth-routes.ps1/.sh  # Add OAuth route family
│   ├── konnect-add-key-auth-routes.ps1   # Add API Key route family
│   ├── deploy-konnect-dataplane.ps1/.sh  # ACA data plane for Konnect
│   ├── generate-foundry-jwt.ps1/.sh      # JWT generation helper
│   └── start-mcp-inspector.ps1    # Launch MCP Inspector with auth
│
├── test/
│   ├── test-mcp-gateway.sh         # Bash test suite (10 tests)
│   └── test-mcp-gateway.ps1        # PowerShell test suite
│
├── docs/                           # Full documentation (see Documentation Index above)
│
└── .github/
    └── workflows/
        └── deploy.yml              # CI/CD: OIDC + staged build + deploy
```

---

## 🤝 Contributing

### Adding a feature

1. Read [architecture.md](docs/architecture.md) first — understand the three-layer flow (Kong → MCP Server → Mock API).
2. New MCP tools go in `mock-api/server.js` (REST endpoint) and `mcp-server/server.js` (tool registration).
3. New Kong routes go in `kong.yaml` (DB-less) **or** via a `scripts/konnect-add-*.ps1` script (Konnect).
4. New Bicep changes follow the two-phase pattern: `infra/acr.bicep` for environment infra, `infra/main.bicep` (or a new `infra/*.bicep`) for apps.

### Testing expectations

- All PRs should pass `bash test/test-mcp-gateway.sh` (10/10) before merge.
- When adding a new route, add a matching test case in `test/test-mcp-gateway.sh` and `test/test-mcp-gateway.ps1`.
- Run both the Bash and PowerShell variants before marking a PR ready.

### Security practices

- **Never commit secrets.** `api-key-config.json`, `entra-oauth-config.json`, and `konnect-connection.json` are gitignored — keep them that way.
- Rotate `poc-secret-change-me` before any shared deployment.
- New Konnect automation scripts must source credentials from environment variables or Key Vault, not from repo files.
- See [Security Notes in repo-setup.md](docs/repo-setup.md#security-notes) for gitignore rationale and rotation cadence.

---

## 📋 Current Status

| Area | Status |
|---|---|
| Kong Gateway + ACA deployment | ✅ Complete |
| Azure OpenAI `/chat` proxy | ✅ Validated |
| JWT MCP route family | ✅ Validated (10/10) |
| API Key MCP route family | ✅ Validated |
| OAuth MCP route family | ✅ Configured, pending Foundry end-to-end |
| Konnect control plane | ✅ Configured |
| Microsoft Foundry connection | ⏳ Pending manual Foundry setup |

Full status: [docs/poc-completion-status.md](docs/poc-completion-status.md)

---

## 🏷️ Credits

**Squad team**

| Role | Agent | Responsibility |
|---|---|---|
| 📝 DevRel / Docs | McManus | Documentation, guides, onboarding |
| 🏗️ Infrastructure | Keaton | Architecture decisions, Konnect design |
| ⚙️ Kong Config | Fenster | Route config, plugin decisions |
| 🔄 Orchestration | Scribe | Session logging, decision archiving |

**Key dependencies**

- [Kong 3.7](https://docs.konghq.com/) — DB-less API gateway
- [Kong Konnect](https://konghq.com/products/kong-konnect) — control plane (OAuth path)
- [@modelcontextprotocol/sdk](https://github.com/modelcontextprotocol/typescript-sdk) — MCP server runtime
- [Azure Container Apps](https://learn.microsoft.com/azure/container-apps/) — managed serverless containers
- [Azure OpenAI](https://learn.microsoft.com/azure/ai-services/openai/) — GPT-4.1 upstream

---

## 🔒 Security Notes

- `poc-secret-change-me` is an intentional placeholder — **rotate before any shared use**
- The Container App uses **system-assigned managed identity** — no Azure OpenAI API keys are stored anywhere
- All internal services (MCP Server, Mock API) have **internal-only ACA ingress** — never internet-exposed
- For credential rotation cadence and gitignore rationale, see [repo-setup.md](docs/repo-setup.md#security-notes)
