# Repository Setup Guide

This guide covers everything a new contributor needs to get the Kong AI Gateway repo operational on their machine.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [First-Time Setup](#first-time-setup)
3. [Credential Files](#credential-files)
4. [Tool Binaries](#tool-binaries)
5. [Validating Your Setup](#validating-your-setup)
6. [Security Notes](#security-notes)

---

## Prerequisites

### Required tools (PATH accessible)

| Tool | Purpose | Install |
|------|---------|---------|
| `az` | Azure CLI — deploy infrastructure and interact with Azure resources | [Install](https://learn.microsoft.com/azure/cli/install-azure-cli) |
| `git` | Source control | [Install](https://git-scm.com/downloads) |
| `node` / `npm` | MCP Server runtime and test harness | [Install](https://nodejs.org) |
| `python` / `python3` | JWT generation via PyJWT | [Install](https://www.python.org/downloads/) |
| `openssl` | Generate API keys | Bundled with Git for Windows or available via `winget install ShiningLight.OpenSSL` |
| `curl` | Gateway smoke tests (Bash only) | Bundled with Git for Windows |

### Optional tools (needed for Konnect-managed gateway)

| Tool | Purpose | Installed by |
|------|---------|-------------|
| `deck` | Sync `kong.yaml` to Konnect | `scripts/setup-repo.ps1 -InstallTools` |
| `kongctl` | Konnect control plane management | `scripts/setup-repo.ps1 -InstallTools` |

---

## First-Time Setup

The quickest path is to run the onboarding script:

```powershell
# From the repo root:
.\scripts\setup-repo.ps1
```

The script will:
1. Check that all required tools are present and report any gaps.
2. Create the three required credential files from their `.template` counterparts.
3. Optionally download `deck` and `kongctl` to `tools/` (pass `-InstallTools`).
4. Validate the setup by verifying each file exists and has been customized.

### Manual Setup (step by step)

If you prefer to do it by hand:

#### 1. Clone the repo

```bash
git clone https://github.com/<org>/msf-kong-ai-gateway-test1
cd msf-kong-ai-gateway-test1
```

#### 2. Install Node dependencies (MCP Server and Mock API)

```bash
cd mcp-server && npm install && cd ..
cd mock-api  && npm install && cd ..
```

#### 3. Authenticate to Azure

```bash
az login
az account set --subscription "<your subscription id>"
```

#### 4. Create credential files (see next section)

---

## Credential Files

Three files are gitignored and must be created locally. Each has a `.template` counterpart in the repo root.

### `api-key-config.json`

Holds the Kong `key-auth` credential used by Foundry and MCP Inspector.

**If this is a new deployment:**

```powershell
# Generate a new API key and register it in Konnect
.\scripts\konnect-add-key-auth-routes.ps1 -Pat $env:KONNECT_PAT `
    -ControlPlaneId <cp-id> -GatewayFqdn <aca-fqdn>
# The script writes api-key-config.json automatically.
```

**If you are connecting to an existing deployment:**

1. Copy the template: `Copy-Item api-key-config.json.template api-key-config.json`
2. Get the API key from the deployment owner (do not send over email — use Azure Key Vault or a secure channel).
3. Fill in all `<placeholder>` values in `api-key-config.json`.

### `entra-oauth-config.json`

Holds the Azure Entra app registration details for the OAuth flow.

1. Copy the template: `Copy-Item entra-oauth-config.json.template entra-oauth-config.json`
2. Follow `docs/entra-app-registration.md` to create or locate the two app registrations.
3. Fill in all `<placeholder>` values, including generating a new client secret in the Entra portal.

> **Note:** The client secret in `entra-oauth-config.json` is scoped to the OAuth passthrough route (`/mcp/oauth/*`). If you only need the key-auth route (`/mcp/key/*`), you can skip this file.

### `konnect-connection.json`

Holds the Konnect control plane details. Populated automatically by `scripts/konnect-setup.ps1`.

1. Copy the template: `Copy-Item konnect-connection.json.template konnect-connection.json`
2. Run `.\scripts\konnect-setup.ps1 -Pat $env:KONNECT_PAT -KeyVaultName <kv>` to populate it.
3. Or fill in the placeholders manually if you have an existing control plane.

> **Note:** If you are only running the OSS DB-less Kong (not Konnect), you do not need this file.

---

## Tool Binaries

`deck` and `kongctl` are large binaries. They are downloaded to `tools/` which is gitignored.

```powershell
# Download both tools automatically:
.\scripts\setup-repo.ps1 -InstallTools

# Or install them manually:
# deck — https://github.com/Kong/deck/releases
# kongctl — https://github.com/Kong/kongctl/releases
```

The setup script places them at:
- `tools\deck\deck.exe`
- `tools\konnect-cli\kongctl.exe`

Existing scripts reference these paths via `$root\tools\...`.

---

## Validating Your Setup

### Verify tools

```powershell
.\scripts\setup-repo.ps1 -CheckOnly
```

### Run the MCP Gateway test suite (requires a live deployment)

```bash
# Bash
export KONG_BASE_URL=https://<your-aca-fqdn>
export JWT_SECRET=<your-jwt-secret>
bash test/test-mcp-gateway.sh

# PowerShell
$env:KONG_BASE_URL = "https://<your-aca-fqdn>"
$env:JWT_SECRET    = "<your-jwt-secret>"
.\test\test-mcp-gateway.ps1
```

Expected output: `10/10 PASS`

### Generate a JWT for manual testing

```powershell
# Uses poc-secret-change-me by default; override with KONG_JWT_SECRET env var
.\scripts\generate-foundry-jwt.ps1
```

---

## Security Notes

### What is gitignored and why

| File | Reason |
|------|--------|
| `api-key-config.json` | Live API key — treat as a password |
| `entra-oauth-config.json` | Live client secret for OAuth flow |
| `konnect-connection.json` | Control plane ID and endpoints |
| `docs/foundry-key-auth-setup.md` | Operator doc that embeds the live API key for copy-paste convenience |
| `docs/mcp-inspector-setup.md` | Operator doc with live credentials |
| `tools/` | Downloaded binary executables, not source |
| `scripts/.generated/` | Auto-generated output files |
| `node_modules/` | npm dependencies |
| `.env`, `.env.*` | Any environment variable files |

### POC credentials in tracked files

`kong.yaml` and several docs contain `poc-secret-change-me`. This is an intentional, clearly-named POC placeholder. It must be rotated before any non-local or shared deployment. See the rotation guidance in `README.md`.

### Credential rotation cadence

| Credential | Recommended rotation |
|------------|---------------------|
| Kong API key (`api-key-config.json`) | Every 90 days |
| Entra client secret | Every 12–24 months (set expiry in portal) |
| Kong JWT secret (`poc-secret-change-me`) | Before any production use |
| Konnect PAT (`KONNECT_PAT` env var) | Every 90 days |

### Never commit

- Actual API keys, tokens, or secrets — even "for testing"
- Files with `<tenant_id>`, `<client_secret>`, or similar that have been filled in
- The contents of any gitignored file

If you accidentally stage a secret, remove it immediately and rotate the credential:

```bash
git reset HEAD <file>
git checkout <file>
```

If it was already committed, rotate the credential and contact the repo owner to purge git history.
