# Kong Konnect Automation Plan

This document separates the Konnect cutover into **what Rob can automate now** and **what still needs a human in the loop**.

> **Important naming note:** Kong's current Konnect CLI binary is `kongctl`. The scripts in this repo keep the `konnect-*` naming for readability, but they validate auth with `kongctl` and use Konnect APIs/Azure CLI underneath.

## Part 1: Automation Matrix

| Step | Can Automate? | Tool | Script | Notes |
| --- | --- | --- | --- | --- |
| Create Konnect account / accept ToS | No | Konnect portal | n/a | Requires browser sign-up, email verification, and org ownership decisions. |
| Generate PAT / sPAT | No | Konnect portal | n/a | Token creation is still a portal action; scripts only consume the token. |
| Install Konnect CLI | Partial | `kongctl` installer / release ZIP | n/a | One-time operator task; documented below. |
| Authenticate to Konnect | Yes | `kongctl` + PAT | All scripts | Scripts use `KONNECT_PAT` / `--pat` and validate with `kongctl get me`. |
| Create control plane | Yes | Konnect API | `scripts/konnect-setup.*` | Idempotent: reuses an existing control plane by name if it already exists. |
| Provision data plane client certs | Yes | OpenSSL + Konnect API + Azure CLI | `scripts/konnect-setup.*` | The scripted path generates a client keypair locally, registers the public cert with Konnect, and stores cert/key in Key Vault. |
| Store certs in Key Vault | Yes | Azure CLI | `scripts/konnect-setup.*` | Uploads `kong-cluster-cert` and `kong-cluster-key`. |
| Convert/sync `kong.yaml` into Konnect | Yes | `kongctl` `_deck` bridge | `scripts/konnect-sync-config.*` | No standalone `deck` command is required; `kongctl sync` drives the gateway-entity sync. |
| Validate synced services/routes/consumers | Yes | Konnect API | `scripts/konnect-sync-config.*` | Confirms core entities exist after sync. |
| Regression-test JWT MCP routes | Partial | Existing test suite | `scripts/konnect-sync-config.*` | Automated if `GATEWAY_BASE_URL` is set; otherwise run after dataplane deploy. |
| Add `/mcp/oauth/*` routes | Yes | Konnect API | `scripts/konnect-add-oauth-routes.*` | Creates the new OAuth route family only; preserves existing JWT routes. |
| Configure `openid-connect` on OAuth routes | Yes | Konnect API | `scripts/konnect-add-oauth-routes.*` | Script applies bearer-token validation with Entra issuer/audience settings and leaves scope enforcement off for Foundry compatibility. |
| Update Kong runtime for Konnect dataplane mode | Yes | `az acr build` + Bicep | `scripts/deploy-konnect-dataplane.*` | Uses `Dockerfile.konnect` and `infra/main-konnect.bicep`. |
| Build image and deploy ACA revision | Yes | Azure CLI | `scripts/deploy-konnect-dataplane.*` | Reuses the existing ACR + ACA environment from this repo. |
| Verify ACA revision health | Yes | Azure CLI + `curl` | `scripts/deploy-konnect-dataplane.*` | Checks revision health and `/status`. |
| Verify data plane shows **Connected** in Konnect | Partial | Konnect portal / CLI | manual checkpoint | Script validates prerequisites; operator should still confirm the Konnect node flips to **Connected** after deploy. |
| Test OAuth browser consent flow | No | Browser + Entra | n/a | Requires interactive user sign-in and consent. |
| Entra app registration automation | Partial | Azure CLI (optional enhancement) | not included | Possible later, but not part of this first Konnect automation pass. |

## Part 2: Prerequisites

Before running any automation, make sure Rob has:

1. **Konnect CLI (`kongctl`) installed**
   - macOS:
     ```bash
     brew install --cask kong/kongctl/kongctl
     ```
   - Linux:
     ```bash
     curl -fsSL https://get.konghq.com/kongctl | sh
     ```
   - Windows:
     - Download the latest `kongctl.exe` from:
       `https://github.com/Kong/kongctl/releases`
     - Add the extracted folder to `PATH`
   - Verify:
     ```bash
     kongctl version --full
     ```

2. **A Konnect account and organization**
   - Manual portal step.

3. **A Personal Access Token (PAT)**
   - Manual portal step.
   - Export once per shell:
     ```bash
     export KONNECT_PAT="<your-pat>"
     ```
     ```powershell
     $env:KONNECT_PAT = "<your-pat>"
     ```

4. **Azure CLI authenticated**
   ```bash
   az login
   az account set --subscription "<subscription-id-or-name>"
   ```

5. **Existing Azure infrastructure already deployed**
   - Resource group `rg-kong-aca`
   - ACR
   - ACA environment
   - Existing Mock API + MCP Server workloads
   - Key Vault that the Kong Container App can read via managed identity

6. **OpenSSL available**
   - Needed by the setup scripts to generate a data plane client certificate/key pair.

7. **Existing gateway config available**
   - Default assumption: `kong.yaml` at the repo root.

## Part 3: Automation Workflow

### Recommended order of operations

1. **Manual setup only once**
   - Create Konnect account
   - Generate PAT
   - Install `kongctl`

2. **Provision Konnect control plane + client certs**
   ```bash
   bash scripts/konnect-setup.sh \
     --keyvault-name <kv-name> \
     --control-plane-name kong-aca-poc
   ```
   ```powershell
   .\scripts\konnect-setup.ps1 `
     -KeyVaultName <kv-name> `
     -ControlPlaneName kong-aca-poc
   ```
   **Checkpoint:** confirm the generated connection-details JSON file contains:
   - control plane ID
   - control plane endpoint
   - telemetry endpoint

3. **Deploy Kong in Konnect data plane mode**
   ```bash
   bash scripts/deploy-konnect-dataplane.sh \
     --image-tag 1.12-konnect \
     --control-plane-endpoint <cp-endpoint> \
     --telemetry-endpoint <tp-endpoint> \
     --keyvault-name <kv-name>
   ```
   **Checkpoint:** `/status` returns healthy and the new ACA revision is live.

4. **Sync the current JWT gateway config**
   ```bash
   export GATEWAY_BASE_URL="https://<gateway-fqdn>"
   bash scripts/konnect-sync-config.sh \
     --control-plane-id <control-plane-id> \
     --config-file kong.yaml
   ```
   **Checkpoint:** `mcp-service`, `/mcp/sse`, `/mcp/messages`, `poc-user`, and the JWT credential all exist in Konnect.

5. **Regression-test the current JWT path**
   ```bash
   bash test/test-mcp-gateway.sh
   ```
   **Checkpoint:** existing `/mcp/*` flow still passes before adding OAuth.

6. **Add OAuth routes**
   ```bash
   bash scripts/konnect-add-oauth-routes.sh \
     --control-plane-id <control-plane-id> \
     --entra-tenant-id <tenant-id> \
     --entra-client-id <resource-api-client-id>
   ```
   **Checkpoint:** `/mcp/oauth/sse` and `/mcp/oauth/messages` exist and have `openid-connect` attached.

7. **Manual OAuth validation**
   - Acquire an Entra token for `api://<resource-api-client-id>`
   - Test `GET /mcp/oauth/sse`
   - Test `POST /mcp/oauth/messages?sessionId=...`
   - Confirm browser-based consent behavior with a real user

### Script dependencies

| Script | Depends on |
| --- | --- |
| `konnect-setup.*` | PAT, `kongctl`, Azure CLI, Key Vault |
| `deploy-konnect-dataplane.*` | Successful `konnect-setup.*`, existing ACA infra |
| `konnect-sync-config.*` | Successful dataplane deploy, control plane ID |
| `konnect-add-oauth-routes.*` | Successful config sync so `mcp-service` already exists |

### Validation checkpoints

1. **Authentication checkpoint**
   - `kongctl get me` succeeds.
2. **Control plane checkpoint**
   - setup script writes connection details file.
3. **Secret checkpoint**
   - `kong-cluster-cert` and `kong-cluster-key` exist in Key Vault.
4. **Deployment checkpoint**
   - ACA revision is healthy.
   - `curl https://<gateway>/status` succeeds.
5. **JWT regression checkpoint**
   - `bash test/test-mcp-gateway.sh` passes.
6. **OAuth checkpoint**
   - OAuth routes exist in Konnect.
   - `openid-connect` is attached only to the OAuth route family.

## Recommended operator pattern

1. Run each script once with `--dry-run`.
2. Run it again without `--dry-run`.
3. Complete the checkpoint before moving to the next script.

That keeps the cutover reversible and avoids mixing Konnect, Azure, and OAuth changes in one jump.
