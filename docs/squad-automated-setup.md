# Squad Automated Konnect Setup

## Executive Summary

**Yes — Squad can execute almost the entire Konnect setup once Rob supplies the manual prerequisites.**

The main hard boundaries are still **browser-only Konnect account creation**, **portal-only PAT generation**, and **interactive OAuth sign-in / consent validation**. Everything else is either directly executable now or executable with a small operator-provided input such as a PAT, Key Vault name, or Entra app IDs.

## Part 1: What Squad Can Do

### Capability Matrix

| Step | Can Squad Execute Directly? | What Rob Must Provide | Blockers / Notes |
| --- | --- | --- | --- |
| 1. Konnect account creation | **NO** | Create the Konnect account and org in the browser | Requires sign-up, email verification, and ToS acceptance. |
| 2. PAT generation | **NO** | Generate a Konnect PAT in the Konnect portal | Token creation is a portal action. Squad should only consume the PAT, never create or store it in repo files. |
| 3. Konnect CLI installation | **PARTIAL** | Permission to download the CLI locally | Squad can download and extract **`kongctl`** locally on Windows and use a session-local `PATH`. Persistent PATH changes should be opt-in. The older `konnect-cli-windows-amd64.zip` URL is not the current release artifact. |
| 4. Control plane setup (`konnect-setup.sh`) | **PARTIAL** | `KONNECT_PAT`, Azure auth, Key Vault name | The automation is executable, but the current setup script prompts before creating a brand-new control plane. That means Squad can run it unattended only if the control plane already exists or if the confirmation is pre-supplied in the command. |
| 5. Config migration (`konnect-sync-config.sh`) | **YES** | `KONNECT_PAT`, control plane ID | Squad can run `kongctl sync`, validate entities, and optionally run the JWT regression suite. |
| 6. OAuth routes (`konnect-add-oauth-routes.sh`) | **YES** | `KONNECT_PAT`, control plane ID, Entra tenant ID, Entra resource API client ID | Squad can create `/mcp/oauth/*` routes and attach `openid-connect`. |
| 7. Data plane deployment (`deploy-konnect-dataplane.sh`) | **YES** | Azure auth, Key Vault name, control-plane endpoints | Squad can build in ACR, deploy Bicep, and validate ACA health. |
| 8. Validation and testing | **YES** | Reachable deployed gateway | Squad can run the existing validation flow. The current Bash MCP gateway suite passed **10/10** from Rob's environment during this assessment. |
| 9. Optional: Entra app registration | **PARTIAL** | Either the app IDs, or approval to let Squad create them with Azure CLI | Azure CLI automation is feasible, but there is no checked-in script yet and the Foundry redirect URI / consent flow still involves human-owned decisions. |

### Why the answer is “Yes, with manual prerequisites”

Squad already has what it needs for the machine-executable parts:

- Bash is available.
- Azure CLI is installed and authenticated.
- `curl`, `python`, and `openssl` are installed.
- The Konnect automation scripts already exist in both Bash and PowerShell.
- The validation suite already works from this environment.

The only missing executable prerequisite in Rob's current environment is **`kongctl`**.

## Part 2: What Rob Must Provide

### Manual prerequisites

Rob must provide these before Squad can run end-to-end:

1. **Konnect account and organization**
2. **Konnect PAT**
3. **Azure Key Vault name** that should hold:
   - `kong-cluster-cert`
   - `kong-cluster-key`
4. **Approval to install `kongctl` locally** into the repo or another local tools folder
5. **Optional OAuth inputs**
   - Entra tenant ID
   - Entra resource API client ID
6. **Optional Entra automation approval**
   - If Rob wants Squad to create the Entra app registrations instead of supplying IDs
7. **Foundry redirect URI** if Squad later automates the client app registration flow

### How Rob should provide them

**Preferred:** set secrets as environment variables in the shell that launches Squad.

Examples:

```powershell
$env:KONNECT_PAT = "<set locally in terminal, not in chat>"
```

```bash
export KONNECT_PAT="<set locally in terminal, not in chat>"
```

For non-secret values, Rob can safely provide them as normal inputs:

- Key Vault name
- Control plane name
- Konnect region
- Entra tenant ID
- Entra resource API client ID

### Security considerations

- **Do not paste PATs or client secrets into chat.**
- **Do not commit secrets into the repo.**
- Keep PATs in environment variables only for the active shell/session.
- Keep certificate material in **Azure Key Vault**, not in repo files.
- If Entra client secrets are introduced later, store them in **Key Vault** as well.
- Avoid persistent machine-wide PATH edits unless Rob explicitly wants them; Squad only needs a session-local PATH or a local tool path.

## Part 3: Squad Execution Workflow

### Exact order Squad will run commands

The safest Windows-first sequence for McManus/Fenster is:

#### 0. Install `kongctl` locally for this session

```powershell
$repo = "C:\Repos\msf-kong-ai-gateway-test1"
Set-Location $repo

$cliDir = Join-Path $repo "tools\kongctl"
$zipPath = Join-Path $cliDir "kongctl_windows_amd64.zip"

New-Item -ItemType Directory -Force -Path $cliDir | Out-Null
$assetUrl = gh api repos/Kong/kongctl/releases/latest --jq '.assets[] | select(.name=="kongctl_windows_amd64.zip") | .browser_download_url'
Invoke-WebRequest -Uri $assetUrl -OutFile $zipPath
Expand-Archive -Path $zipPath -DestinationPath $cliDir -Force
Remove-Item $zipPath -Force

$env:Path = "$cliDir;$env:Path"
& (Join-Path $cliDir "kongctl.exe") version --full
az account show --query '{name:name, user:user.name, tenantId:tenantId}'
```

#### 1. Run control-plane setup

> `konnect-setup.sh` prompts before creating a new control plane, so Squad should pre-supply the confirmation for a fully unattended run.

```powershell
$env:MSYS_NO_PATHCONV = "1"
Set-Location $repo

cmd /c "echo y| bash scripts/konnect-setup.sh --keyvault-name <keyvault-name> --control-plane-name kong-aca-poc --region us"
```

#### 2. Read the generated connection details

```powershell
$details = Get-Content "$repo\scripts\.generated\konnect\kong-aca-poc-connection-details.json" | ConvertFrom-Json
$details
```

#### 3. Deploy the Konnect data plane

```powershell
bash scripts/deploy-konnect-dataplane.sh `
  --image-tag 1.12-konnect `
  --control-plane-endpoint $details.controlPlaneEndpoint `
  --telemetry-endpoint $details.telemetryEndpoint `
  --keyvault-name <keyvault-name>
```

#### 4. Capture the new gateway URL

```powershell
$gatewayFqdn = az deployment group show `
  -g rg-kong-aca `
  -n kongai-konnect-app `
  --query "properties.outputs.containerAppFqdn.value" `
  -o tsv

$env:GATEWAY_BASE_URL = "https://$gatewayFqdn"
$env:GATEWAY_BASE_URL
```

#### 5. Sync the current JWT configuration into Konnect

```powershell
bash scripts/konnect-sync-config.sh `
  --control-plane-id $details.controlPlaneId `
  --config-file kong.yaml
```

#### 6. Run the JWT regression suite

```powershell
bash test/test-mcp-gateway.sh
```

#### 7. Add the OAuth route family

```powershell
bash scripts/konnect-add-oauth-routes.sh `
  --control-plane-id $details.controlPlaneId `
  --entra-tenant-id <entra-tenant-id> `
  --entra-client-id <entra-resource-api-client-id>
```

#### 8. Run post-change validation

```powershell
curl.exe -fsS "$env:GATEWAY_BASE_URL/status"
bash test/test-mcp-gateway.sh
```

#### 9. Manual OAuth validation

Manual human-owned checks remain:

1. Acquire a real Entra access token for `api://<entra-resource-api-client-id>`
2. Open `GET /mcp/oauth/sse`
3. Use the returned `sessionId` against `POST /mcp/oauth/messages`
4. Validate real user sign-in / consent behavior in the browser or Foundry

### Validation checkpoints

Squad should not proceed past each checkpoint until it passes:

1. **CLI checkpoint**
   - `kongctl version --full`
2. **Konnect auth checkpoint**
   - `kongctl get me`
3. **Azure checkpoint**
   - `az account show`
4. **Setup checkpoint**
   - `scripts\.generated\konnect\kong-aca-poc-connection-details.json` exists
   - Key Vault has `kong-cluster-cert` and `kong-cluster-key`
5. **Deployment checkpoint**
   - ACA deployment completes
   - `GET /status` succeeds
6. **JWT checkpoint**
   - `bash test/test-mcp-gateway.sh` passes
7. **OAuth checkpoint**
   - `/mcp/oauth/sse` route exists
   - `/mcp/oauth/messages` route exists
   - `openid-connect` is attached only to the OAuth route family

### What Rob will see

Rob should expect:

- CLI download/extract logs
- Konnect auth validation
- Azure deployment/build logs from ACR and Bicep
- A generated Konnect connection-details JSON file
- Key Vault secret write confirmations
- A gateway URL for the new Konnect-backed deployment
- Pass/fail output from the MCP gateway regression suite
- Explicit notification before the manual OAuth browser test

### Expected duration

After Rob provides the prerequisites:

- Local CLI install: **2-5 minutes**
- Konnect setup + Key Vault upload: **5-10 minutes**
- ACA build/deploy: **10-15 minutes**
- Config sync + JWT regression: **5-10 minutes**
- OAuth route creation: **2-5 minutes**
- Manual OAuth validation: **5-10 minutes**

**Total:** roughly **20-30 minutes** of Squad execution, plus any manual sign-in time.

## Part 4: Safety and Rollback

### What Squad validates before proceeding

Squad should validate all of the following before making the next change:

- Konnect authentication is valid
- Azure authentication is valid
- Required Key Vault secret references exist
- The Konnect dataplane revision is healthy before config sync
- The existing JWT route family still passes before OAuth routes are added

### Rollback strategy

#### If setup fails before deployment

- Stop immediately
- Remove the partially created control plane only if Rob wants cleanup
- Delete any temporary local CLI download artifacts
- Keep the current deployed JWT gateway unchanged

#### If dataplane deployment fails

- Do **not** continue to config sync or OAuth
- Keep the current gateway as the active baseline
- Re-run the deployment after fixing Azure/Bicep/image issues

#### If config sync fails

- Stop before OAuth route creation
- Keep the current JWT baseline unchanged in production traffic until sync is corrected
- Re-run `konnect-sync-config.sh` after the manifest or entity issue is fixed

#### If OAuth route setup fails

- Leave the JWT route family untouched
- Remove only the `/mcp/oauth/*` routes or the attached `openid-connect` plugin
- Re-test the JWT baseline to confirm no regression

### Manual override points

Rob should have explicit stop/continue authority at these points:

1. After local `kongctl` install
2. After control-plane creation and Key Vault upload
3. After ACA dataplane deployment
4. After JWT regression passes
5. Before enabling or validating OAuth in a browser

## Bottom Line

**Can Squad automate the setup?** **Yes — with two hard manual inputs and one optional manual OAuth phase.**

### Rob supplies

1. Konnect account
2. Konnect PAT
3. Key Vault name
4. Optional Entra values, or permission for Squad to create them

### Squad executes

1. Install `kongctl` locally
2. Create the Konnect control plane and certificate material
3. Upload cert/key to Key Vault
4. Deploy the Konnect-backed ACA data plane
5. Sync the current JWT config
6. Run the validation suite
7. Add the OAuth routes
8. Hand off for the final browser-based OAuth validation
