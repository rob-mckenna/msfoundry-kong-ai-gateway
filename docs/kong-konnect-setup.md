# Kong Konnect Setup Guide

This guide shows how to move the current **Kong OSS 3.7 DB-less deployment on Azure Container Apps (ACA)** to **Kong Konnect control plane + self-managed data plane** so Rob can keep the current JWT-backed `/mcp/*` routes and add Konnect-managed OAuth routes with the Enterprise `openid-connect` plugin.

> Scope: documentation only. Do **not** create the Konnect account, do **not** deploy changes, and do **not** paste real certificates into source control.

## Automated setup

If you want the scripted path, start here before reading the full manual guide:

1. Review `docs/kong-konnect-automation.md`
2. Use `docs/konnect-automation-checklist.md` as the runbook
3. Run the scripts in this order:
   1. `scripts/konnect-setup.sh` / `.ps1`
   2. `scripts/deploy-konnect-dataplane.sh` / `.ps1`
   3. `scripts/konnect-sync-config.sh` / `.ps1`
   4. `scripts/konnect-add-oauth-routes.sh` / `.ps1`

**Manual-only steps remain:**

- create the Konnect account
- generate the PAT
- complete browser-based OAuth sign-in / consent testing

**Quick start for automation**

```bash
# 1) Control plane + Key Vault secrets
bash scripts/konnect-setup.sh --keyvault-name <kv-name>

# 2) Deploy Kong as a Konnect dataplane
bash scripts/deploy-konnect-dataplane.sh \
  --image-tag 1.12-konnect \
  --control-plane-endpoint <cp-endpoint> \
  --telemetry-endpoint <tp-endpoint> \
  --keyvault-name <kv-name>

# 3) Sync the existing gateway entities
export GATEWAY_BASE_URL="https://<gateway-fqdn>"
bash scripts/konnect-sync-config.sh --control-plane-id <control-plane-id>

# 4) Add the OAuth route family
bash scripts/konnect-add-oauth-routes.sh \
  --control-plane-id <control-plane-id> \
  --entra-tenant-id <tenant-id> \
  --entra-client-id <resource-api-client-id>
```

> The scripts use the current Konnect CLI binary name, `kongctl`, plus Konnect APIs and Azure CLI under the hood.

## Current starting point

- Runtime: Kong OSS 3.7 on ACA
- Mode: DB-less with `kong.yaml`
- Existing MCP auth: JWT on `/mcp/sse` and `/mcp/messages`
- Build/deploy path: Dockerfile + `az acr build` + `infra/main.bicep`
- Goal state: Konnect-managed configuration with ACA-hosted self-managed data plane

## Target architecture

```text
Konnect Control Plane (SaaS)
  - gateway configuration
  - analytics / telemetry metadata
  - openid-connect plugin management
           ^
           | mTLS over 443
           v
Kong Data Plane on Azure Container Apps
  - proxies /chat, /mcp/*, /mcp/oauth/*
  - receives config from Konnect
  - no local declarative config file
           |
           v
Internal ACA backends
  - MCP Server
  - Mock API
  - Azure OpenAI
```

---

## Part 1 - Account setup

### 1. Create the Konnect account

1. Open Kong Konnect sign-up.
2. Register with the team email you want tied to the organization owner role.
3. Verify the email address.
4. Sign in to the Konnect portal.
5. When prompted for a region/geo, choose **US** for this project because the workloads run in **Azure East US 2**.
6. Create the organization.

**Recommended org naming:**

- Organization: `rob-mckenna-poc`
- Control plane group prefix: `aca-eastus2`
- Environment tag/label: `poc`, `demo`, or `shared`

[Screenshot: Konnect sign-up or first-run wizard showing geo selection and organization name entry]

### 2. Organization setup checklist

Immediately after account creation:

1. Confirm the owner account can reach **API Gateway / Gateway Manager**.
2. Add at least one backup org admin.
3. Turn on MFA/SSO if your company policy requires it.
4. Generate a personal access token only if you plan to automate via Konnect APIs or decK.
5. Record the chosen geo in the runbook because Konnect objects are geo-specific.

### 3. Free tier / trial planning notes

Use the following working assumptions for this POC and re-check Kong pricing before production procurement:

| Item | POC planning limit |
| --- | --- |
| Services | 5 |
| Throughput | 100 requests/second |
| Control planes | 1 |
| Data plane instances | 2 |
| Analytics retention | 30 days |
| Fit | good for demo / POC |

### 4. What free/trial is good for vs. what paid adds

**Good enough for this repo:**

- One Konnect control plane
- ACA-hosted self-managed data plane
- Existing `/mcp/*` routes plus one OAuth route family
- Portal-based configuration and validation
- Enough analytics to confirm traffic and auth behavior

**Reasons to move to paid/enterprise later:**

- More services or higher RPS
- More than one shared environment
- Longer analytics retention
- Enterprise support / procurement controls
- Production HA, multi-team governance, or strict compliance needs

---

## Part 2 - Control plane creation

### 1. Create the control plane

1. In Konnect, open **API Gateway**.
2. Choose **Control Planes**.
3. Click **New Control Plane**.
4. Select the gateway manager control plane option for a self-managed data plane.
5. Name it using an environment-aware convention.

**Recommended name:** `aca-eastus2-mcp-poc-cp`

**Why this name works:** it encodes hosting platform, region, workload, purpose, and environment.

[Screenshot: New Control Plane dialog with name, description, and region/geo selector]

### 2. Region selection

- If the portal asks for a **geo**, choose **US**.
- If it asks for a more specific Azure region for managed gateway features, choose **Virginia (`eastus2`)** because it aligns with the current ACA deployment region.
- Keep all related Konnect gateway objects in the same geo.

### 3. Capture the connection details

After the control plane is created:

1. Open the control plane.
2. Click **Add Data Plane**.
3. Choose the **Docker** or **Linux** installation path because ACA runs a containerized Kong instance.
4. Copy or download the generated values:
   - control plane endpoint
   - telemetry endpoint
   - cluster certificate
   - cluster private key
   - any SNI/server-name values shown in the install script
5. Save the generated snippet to a secure operator note outside the repo.

**You need these values later:**

```text
KONG_ROLE=data_plane
KONG_DATABASE=off
KONG_CLUSTER_CONTROL_PLANE=<cp-id>.us.cp0.konghq.com:443
KONG_CLUSTER_TELEMETRY_ENDPOINT=<cp-id>.us.tp0.konghq.com:443
KONG_CLUSTER_CERT=<pem>
KONG_CLUSTER_CERT_KEY=<pem>
```

**Also expect Konnect-generated installs to include or imply:**

```text
KONG_CLUSTER_MTLS=pki
KONG_KONNECT_MODE=on
KONG_LUA_SSL_TRUSTED_CERTIFICATE=system
```

### 4. Save credentials securely

Do not store the certificate, key, or PAT in:

- `kong.yaml`
- Bicep parameter files committed to git
- Dockerfile `ENV` lines
- shell history
- wiki pages with broad access

Use **Azure Key Vault** as the system of record and inject secrets into ACA at deploy time.

---

## Part 3 - Certificate management

### 1. Download the cluster certificate and private key

From **Add Data Plane** in Konnect:

1. Copy the PEM-encoded cluster certificate.
2. Copy the PEM-encoded private key.
3. Save them to secure local files only long enough to upload them to Key Vault.
4. Delete local working copies after upload.

Use placeholders in documentation and scripts:

```text
-----BEGIN CERTIFICATE-----
<konnect-cluster-cert>
-----END CERTIFICATE-----
```

```text
-----BEGIN PRIVATE KEY-----
<konnect-cluster-private-key>
-----END PRIVATE KEY-----
```

### 2. Recommended approach: Azure Key Vault

Store the cert and key as separate Key Vault secrets.

Example upload commands:

```powershell
$vault = '<your-key-vault-name>'

az keyvault secret set --vault-name $vault --name kong-cluster-cert --file .\kong-cluster-cert.pem
az keyvault secret set --vault-name $vault --name kong-cluster-key  --file .\kong-cluster-key.pem
```

Then grant the Kong Container App managed identity read access:

- Azure RBAC role: **Key Vault Secrets User**
- Scope: the Key Vault resource

### 3. Alternative: ACA inline secrets

If Key Vault is temporarily unavailable, you can store the same values as Container App secrets.

Use this only for short-lived POC work because it is weaker operationally:

- secret lifecycle is tied to the app revision/configuration
- manual rotation is easier to miss
- access boundaries are usually broader than Key Vault

### 4. Security best practices

- Keep cert and key in separate secret objects.
- Restrict Key Vault access to the ACA managed identity and a minimal operator group.
- Never paste the private key into repo files, issue comments, or screenshots.
- Prefer one control plane credential set per environment.
- Record who owns rotation and who validates post-rotation connectivity.

### 5. Rotation considerations

Treat the Konnect client certificate as a managed secret with a recurring rotation runbook. For this project, adopt a **90-day review/rotation cadence** so ACA secret refresh, rollback, and validation steps stay operationally routine.

1. Generate or retrieve the replacement certificate material from Konnect.
2. Upload new values to Key Vault under the same secret names or a versioned naming pattern.
3. Restart or roll a new ACA revision so Kong reloads the secret material.
4. Confirm the data plane returns to **Connected** status.
5. Re-run JWT and OAuth smoke tests.

**Important ACA note:** secret changes do not become active until the Container App revision is refreshed or restarted.

---

## Part 4 - Dockerfile changes

### 1. What changes when moving from DB-less to Konnect data plane mode

**Current model:**

- `kong.yaml` baked into the image
- `KONG_DECLARATIVE_CONFIG=/etc/kong/kong.yaml`
- Kong starts with local config only

**Target model:**

- no declarative config file required at runtime
- Kong starts as a **data plane**
- configuration is pulled from Konnect over mTLS

### 2. Before / after comparison

#### Current Dockerfile shape

```dockerfile
FROM kong:3.7
COPY kong.yaml /etc/kong/kong.yaml

ENV KONG_DATABASE=off \
    KONG_DECLARATIVE_CONFIG=/etc/kong/kong.yaml \
    KONG_PROXY_ACCESS_LOG=/dev/stdout \
    KONG_ADMIN_ACCESS_LOG=/dev/stdout \
    KONG_PROXY_ERROR_LOG=/dev/stderr \
    KONG_ADMIN_ERROR_LOG=/dev/stderr \
    KONG_STATUS_LISTEN=0.0.0.0:8100 \
    KONG_ADMIN_LISTEN=off \
    KONG_UNTRUSTED_LUA=on
```

#### Konnect data plane target shape

```dockerfile
FROM kong/kong-gateway:3.7

ENV KONG_ROLE=data_plane \
    KONG_DATABASE=off \
    KONG_CLUSTER_MTLS=pki \
    KONG_KONNECT_MODE=on \
    KONG_LUA_SSL_TRUSTED_CERTIFICATE=system \
    KONG_PROXY_ACCESS_LOG=/dev/stdout \
    KONG_ADMIN_ACCESS_LOG=/dev/stdout \
    KONG_PROXY_ERROR_LOG=/dev/stderr \
    KONG_ADMIN_ERROR_LOG=/dev/stderr \
    KONG_STATUS_LISTEN=0.0.0.0:8100 \
    KONG_ADMIN_LISTEN=off \
    KONG_UNTRUSTED_LUA=on
```

### 3. What to remove

Remove these DB-less-specific elements:

- `COPY kong.yaml /etc/kong/kong.yaml`
- `KONG_DECLARATIVE_CONFIG=/etc/kong/kong.yaml`
- any `RUN` validation step that assumes the declarative file exists

### 4. What to add

Provide the Konnect values through ACA environment variables and secret refs, not hard-coded image values:

```text
KONG_CLUSTER_CONTROL_PLANE
KONG_CLUSTER_TELEMETRY_ENDPOINT
KONG_CLUSTER_CERT
KONG_CLUSTER_CERT_KEY
```

### 5. What stays the same

These repo-specific behaviors can stay:

- status port `8100`
- `KONG_ADMIN_LISTEN=off`
- stdout/stderr logging
- ACA health probes against `/status`
- current custom timeout/buffering env vars for SSE
- the managed-identity wrapper entrypoint if `/chat` continues to use the `post-function` plugin

### 6. Important image note

To use `openid-connect`, do **not** stay on the OSS `kong:3.7` image. Use the Konnect-compatible/Kong Gateway Enterprise image family provided by Kong for self-managed data planes.

---

## Part 5 - Bicep infrastructure updates

### 1. Add new deployment parameters

Expect to add parameters such as:

```bicep
param keyVaultName string
param kongClusterControlPlane string
param kongClusterTelemetryEndpoint string
```

Optionally add:

```bicep
param kongClusterServerName string = ''
param kongClusterTelemetryServerName string = ''
```

### 2. Use Key Vault-backed ACA secrets

Recommended pattern:

```bicep
resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' existing = {
  name: keyVaultName
}

secrets: [
  {
    name: 'kong-cluster-cert'
    keyVaultUrl: '${keyVault.properties.vaultUri}secrets/kong-cluster-cert'
    identity: 'system'
  }
  {
    name: 'kong-cluster-key'
    keyVaultUrl: '${keyVault.properties.vaultUri}secrets/kong-cluster-key'
    identity: 'system'
  }
]
```

### 3. Add data plane env vars

```bicep
env: [
  {
    name: 'KONG_ROLE'
    value: 'data_plane'
  }
  {
    name: 'KONG_DATABASE'
    value: 'off'
  }
  {
    name: 'KONG_CLUSTER_MTLS'
    value: 'pki'
  }
  {
    name: 'KONG_KONNECT_MODE'
    value: 'on'
  }
  {
    name: 'KONG_LUA_SSL_TRUSTED_CERTIFICATE'
    value: 'system'
  }
  {
    name: 'KONG_CLUSTER_CONTROL_PLANE'
    value: kongClusterControlPlane
  }
  {
    name: 'KONG_CLUSTER_TELEMETRY_ENDPOINT'
    value: kongClusterTelemetryEndpoint
  }
  {
    name: 'KONG_CLUSTER_CERT'
    secretRef: 'kong-cluster-cert'
  }
  {
    name: 'KONG_CLUSTER_CERT_KEY'
    secretRef: 'kong-cluster-key'
  }
]
```

### 4. Managed identity requirements

The current system-assigned managed identity can remain in place.

Add or confirm:

- ACR pull access still exists.
- Key Vault access exists for `get` on secrets via Azure RBAC.
- Operators understand that new ACA revisions may be needed after secret changes.

### 5. Updated env var list

**Keep:**

- `KONG_PROXY_ACCESS_LOG`
- `KONG_PROXY_ERROR_LOG`
- `KONG_STATUS_LISTEN`
- `KONG_ADMIN_LISTEN`
- `KONG_UNTRUSTED_LUA`
- `KONG_PROXY_BUFFERING`
- `KONG_NGINX_HTTP_PROXY_BUFFERING`
- `KONG_NGINX_PROXY_PROXY_SEND_TIMEOUT`
- `KONG_NGINX_PROXY_PROXY_READ_TIMEOUT`

**Remove:**

- `KONG_DECLARATIVE_CONFIG`

**Add:**

- `KONG_ROLE`
- `KONG_CLUSTER_MTLS`
- `KONG_KONNECT_MODE`
- `KONG_LUA_SSL_TRUSTED_CERTIFICATE`
- `KONG_CLUSTER_CONTROL_PLANE`
- `KONG_CLUSTER_TELEMETRY_ENDPOINT`
- `KONG_CLUSTER_CERT`
- `KONG_CLUSTER_CERT_KEY`

---

## Part 6 - Migration strategy

### 1. Inventory the current declarative config

Before touching ACA, inventory what the current `kong.yaml` contains:

- consumer: `poc-user`
- JWT credential: issuer/key `kong-poc`
- service: `chat`
- service: `mcp-service`
- routes:
  - `/chat`
  - `/mcp/sse`
  - `/mcp/messages`
- plugins:
  - `jwt`
  - `cors`
  - `rate-limiting`
  - `post-function`

Use `docs/kong-yaml-to-konnect.md` as the field-by-field translation guide.

### 2. Build the Konnect config before switching the running data plane

Recommended order:

1. Create the control plane.
2. Recreate all required services/routes/plugins/consumers in Konnect.
3. Export or snapshot the Konnect config as a backup.
4. Only then deploy the ACA gateway revision in data plane mode.

### 3. Recreate the current JWT MCP behavior in Konnect

In the Konnect portal:

1. Create service `mcp-service` with the current ACA internal HTTPS URL.
2. Add route `mcp-sse-route`:
   - path `/mcp/sse`
   - methods `GET`, `OPTIONS`
3. Add route `mcp-messages-route`:
   - path `/mcp/messages`
   - methods `POST`, `OPTIONS`
4. Attach the `jwt` plugin with the same behavior:
   - verify `exp`
   - `key_claim_name=iss`
5. Attach the same CORS settings used today.
6. Create consumer `poc-user`.
7. Add a JWT credential with:
   - key `kong-poc`
   - secret `poc-secret-change-me`
   - algorithm `HS256`

If `/chat` still matters for the demo, recreate that service and its plugins too before cutover.

### 4. Map `kong.yaml` entities to Konnect entities

Use this mental model:

- `consumers[]` -> **Consumers**
- `jwt_secrets[]` -> **Consumer JWT credentials**
- `services[]` -> **Gateway Services**
- `routes[]` -> **Routes**
- `plugins[]` -> **Plugins attached to service/route/global scope**

### 5. Cutover plan

1. Finish Konnect configuration while ACA still runs the old DB-less image.
2. Build the updated Konnect data plane image in ACR.
3. Deploy a new ACA revision with Konnect env vars and Key Vault secret refs.
4. Wait for the data plane to show **Connected** in Konnect.
5. Re-run regression tests for `/mcp/*`.
6. Only after JWT baseline passes, add `/mcp/oauth/*`.

### 6. Validation for existing JWT routes

Use the current repo test suite as the regression gate:

```bash
bash test/test-mcp-gateway.sh
```

Success means:

- `/mcp/sse` still accepts a valid JWT
- `/mcp/messages` still works with the SSE-issued `sessionId`
- the existing tools still respond

### 7. Rollback plan

**Config rollback only:**

- remove or disable newly added Konnect routes/plugins
- restore the last exported Konnect config snapshot
- keep the ACA data plane attached

**Platform rollback:**

- deploy or activate the previous ACA revision that still uses the DB-less image and baked-in `kong.yaml`
- leave the Konnect control plane in place for a later retry

---

## Part 7 - OAuth route configuration

### 1. Create a separate OAuth route family

Keep the existing JWT routes unchanged and add a new route family:

- `GET /mcp/oauth/sse`
- `POST /mcp/oauth/messages`

This follows the team decision to run **parallel auth** instead of replacing the current JWT demo.

### 2. Create the OAuth service/route objects

Recommended Konnect shape:

1. Reuse the same upstream MCP service **or** create a second service if the MCP server needs separate public path behavior.
2. Add route `mcp-oauth-sse-route` for `/mcp/oauth/sse`.
3. Add route `mcp-oauth-messages-route` for `/mcp/oauth/messages`.
4. Apply the same SSE-friendly timeout/CORS posture used by the current MCP routes.

### 3. Add the `openid-connect` plugin

Attach `openid-connect` to the OAuth route family only.

Use Entra values similar to:

| Setting | Value |
| --- | --- |
| Issuer / discovery | `https://login.microsoftonline.com/<tenant-id>/v2.0` |
| Auth method | bearer token |
| JWKS / discovery | derived from issuer metadata |
| Audience | your custom API audience, e.g. `api://<resource-api-client-id>` |
| Required scope | `MCP.Use` |
| Token source | `Authorization: Bearer <access-token>` |

[Screenshot: Konnect plugin form for openid-connect showing issuer, bearer mode, audience, and scopes]

### 4. Configure Entra discovery and JWKS validation

Configure the plugin to:

- use the tenant-specific issuer
- validate signatures via Entra discovery/JWKS
- reject wrong audience
- reject missing `MCP.Use`
- honor token lifetime claims

Prefer stateless JWT validation over introspection for SSE workloads.

### 5. Claim-to-header mapping

Forward a minimal set of verified claims downstream. Suggested headers:

- `X-Auth-Mode: oauth`
- `X-User-Object-Id`
- `X-User-Tenant-Id`
- `X-User-Principal-Name`
- `X-User-Display-Name`
- `X-User-Scopes`

Use the plugin's claim/header mapping or a lightweight request transformation step.

### 6. Important MCP server note

The current MCP server advertises `/mcp/messages` during SSE bootstrap. For `/mcp/oauth/messages` to work cleanly, the MCP server needs one of these:

- configurable public message path support, or
- a dedicated OAuth-facing MCP server instance that advertises the OAuth message endpoint

Do not skip this check; the SSE handshake can succeed while message POSTs still fail.

---

## Part 8 - Deployment and validation

### 1. Build the updated image

When the Dockerfile is updated, keep the existing cloud build pattern:

```bash
az acr build --registry <acr-name> --image kong-ai-gw:konnect-1.0 .
```

### 2. Deploy the updated ACA revision

Deploy the Bicep change with the new Konnect parameters and Key Vault references.

After deployment, verify:

- Container App revision is healthy
- status probe on `/status` passes
- Konnect shows the node as **Connected**

### 3. Verify data plane connectivity

Success signals:

- Konnect portal shows **Connected**
- config sync completes within roughly 10 seconds after a small portal change
- Kong logs show successful clustering/config sync activity

[Screenshot: Konnect data plane node list showing Connected / Last Seen Just Now]

### 4. Test existing JWT routes first

Regression test order:

1. `bash test/test-mcp-gateway.sh`
2. manual `GET /mcp/sse` with a known-good JWT if needed
3. confirm the current Foundry key-based path still works

### 5. Test the new OAuth routes

Validate independently before Foundry:

1. acquire an Entra access token for the custom audience and `MCP.Use` scope
2. call `GET /mcp/oauth/sse`
3. confirm the SSE bootstrap advertises the OAuth message endpoint
4. call `POST /mcp/oauth/messages?sessionId=...` with the same bearer token
5. confirm claims arrive downstream via mapped headers

### 6. Monitoring checklist

- ACA logs for Kong startup, clustering, and plugin errors
- Konnect node status and config sync state
- auth-specific logs that distinguish JWT vs OAuth route usage
- analytics retention window limits if using free/trial capacity

### 7. Troubleshooting fast-path

If something fails, isolate by layer:

1. **Data plane not connected** -> control plane endpoint, certificate, or secret injection issue
2. **JWT route broken after cutover** -> missing consumer/JWT credential/plugin parity in Konnect
3. **OAuth SSE opens but POST fails** -> MCP bootstrap path mismatch
4. **OAuth 401/403** -> wrong issuer, audience, or scope

See `docs/kong-konnect-troubleshooting.md` for detailed failure handling.

---

## Recommended execution order for Rob

1. Create Konnect account and US geo org.
2. Create control plane.
3. Generate/download data plane connection values.
4. Store cert and key in Key Vault.
5. Prepare Dockerfile + Bicep changes.
6. Recreate current JWT services/routes/consumers in Konnect.
7. Deploy ACA as a Konnect data plane.
8. Re-run JWT regression suite.
9. Add `/mcp/oauth/*` routes and `openid-connect`.
10. Validate OAuth directly, then integrate with Foundry.

## Related documents

- `docs/kong-konnect-quickstart.md`
- `docs/kong-yaml-to-konnect.md`
- `docs/kong-konnect-troubleshooting.md`
- `docs/oauth-implementation-phases.md`
