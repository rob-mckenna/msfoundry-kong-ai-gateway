# Kong Konnect Quick Start

Fast path for experienced operators moving this repo from **Kong OSS DB-less** to **Konnect + self-managed data plane on ACA**.

> Goal: get the current JWT routes working under Konnect first, then add OAuth routes.

## 30-minute path

1. **Create Konnect org + control plane**
   - Geo: **US**
   - Control plane name: `aca-eastus2-mcp-poc-cp`
   - In Konnect, open **Add Data Plane** and copy:
     - `KONG_CLUSTER_CONTROL_PLANE`
     - `KONG_CLUSTER_TELEMETRY_ENDPOINT`
     - cluster cert
     - cluster key

2. **Store cluster secrets in Key Vault**

```powershell
$vault = '<key-vault-name>'
az keyvault secret set --vault-name $vault --name kong-cluster-cert --file .\kong-cluster-cert.pem
az keyvault secret set --vault-name $vault --name kong-cluster-key  --file .\kong-cluster-key.pem
```

3. **Update the image design**
   - switch from `kong:3.7` to Konnect-compatible `kong/kong-gateway:3.7`
   - remove `COPY kong.yaml`
   - remove `KONG_DECLARATIVE_CONFIG`
   - add data plane mode env vars

4. **Update Bicep env vars**

```text
KONG_ROLE=data_plane
KONG_DATABASE=off
KONG_CLUSTER_MTLS=pki
KONG_KONNECT_MODE=on
KONG_LUA_SSL_TRUSTED_CERTIFICATE=system
KONG_CLUSTER_CONTROL_PLANE=<cp-host>:443
KONG_CLUSTER_TELEMETRY_ENDPOINT=<tp-host>:443
KONG_CLUSTER_CERT -> secretRef kong-cluster-cert
KONG_CLUSTER_CERT_KEY -> secretRef kong-cluster-key
```

5. **Keep existing ACA behaviors**
   - `/status` probes on port `8100`
   - SSE timeout env vars
   - stdout/stderr logging
   - managed identity wrapper if `/chat` still uses `post-function`

6. **Recreate current config in Konnect**
   - service `mcp-service`
   - routes:
     - `GET /mcp/sse`
     - `POST /mcp/messages`
   - consumer `poc-user`
   - JWT credential:
     - key `kong-poc`
     - secret `poc-secret-change-me`
     - alg `HS256`
   - attach `jwt` + `cors`
   - recreate `/chat` service/plugins if still needed

7. **Build the new image**

```bash
az acr build --registry <acr-name> --image kong-ai-gw:konnect-1.0 .
```

8. **Deploy the ACA revision**

```bash
az deployment group create \
  --resource-group rg-kong-aca \
  --template-file infra/main.bicep \
  --parameters \
    containerImage=<acr>.azurecr.io/kong-ai-gw:konnect-1.0 \
    acrName=<acr-name> \
    containerAppEnvId=<aca-env-id> \
    keyVaultName=<key-vault-name> \
    kongClusterControlPlane=<cp-host>:443 \
    kongClusterTelemetryEndpoint=<tp-host>:443
```

9. **Wait for Konnect connectivity**
   - portal status: **Connected**
   - config sync after edits: ~10 seconds

10. **Regression test JWT baseline**

```bash
bash test/test-mcp-gateway.sh
```

11. **Decision gate: are the Entra app registrations ready?**
   - Needed now:
     - tenant ID
     - resource API app registration client ID
   - If those values are not available yet, stop here and keep the deployment on the working JWT route family:
     - `GET /mcp/sse`
     - `POST /mcp/messages`

12. **Add OAuth route family in Konnect** *(only after the Entra values are ready)*
   - `/mcp/oauth/sse`
   - `/mcp/oauth/messages`
   - attach `openid-connect`
   - issuer: `https://login.microsoftonline.com/<tenant-id>/v2.0`
   - audience: `api://<resource-api-client-id>`
   - optional requested scope: `MCP.Use`
   - gateway validates issuer/audience only; it does not reject tokens that omit `scp`

13. **Validate OAuth directly**
   - Entra token -> `GET /mcp/oauth/sse`
   - same token -> `POST /mcp/oauth/messages?sessionId=...`
   - verify claim headers

## Rollback

- **Config only:** remove `/mcp/oauth/*` or restore prior Konnect snapshot.
- **Full platform rollback:** switch back to the last ACA revision that still uses the DB-less image and baked-in `kong.yaml`.

## Keep in mind

- Konnect data planes do **not** use `kong.yaml` at runtime.
- Konnect portal/API becomes the source of truth.
- Do not cut over until the current JWT route family has been recreated in Konnect.
- The OAuth route family needs the MCP server to advertise `/mcp/oauth/messages` correctly.
