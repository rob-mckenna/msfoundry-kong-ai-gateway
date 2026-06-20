# Konnect Automation Checklist

## 1. Pre-flight checklist

- [ ] Konnect account exists
- [ ] Konnect PAT created
- [ ] `kongctl version --full` works
- [ ] `az login` completed
- [ ] Correct Azure subscription selected
- [ ] Existing `rg-kong-aca` resources exist
- [ ] Key Vault exists and Kong ACA managed identity can read secrets
- [ ] `openssl` is available
- [ ] `kong.yaml` is ready for sync
- [ ] Decide whether Entra app registrations are ready for OAuth route creation
- [ ] If OAuth is in scope now, capture:
  - [ ] Tenant ID
  - [ ] Resource API app registration client ID

> If the Entra values above are not available yet, stop after the JWT baseline validation and carry the OAuth route family as a follow-up. The current `/mcp/sse` and `/mcp/messages` routes are the ready-to-test baseline.

## 2. Automated steps

### A. Preview control plane setup

```bash
bash scripts/konnect-setup.sh \
  --keyvault-name <kv-name> \
  --control-plane-name kong-aca-poc \
  --dry-run
```

- [ ] Dry-run output looks correct

### B. Create control plane + Key Vault secrets

```bash
bash scripts/konnect-setup.sh \
  --keyvault-name <kv-name> \
  --control-plane-name kong-aca-poc
```

- [ ] `scripts/.generated/konnect/<control-plane>-connection-details.json` exists
- [ ] `kong-cluster-cert` exists in Key Vault
- [ ] `kong-cluster-key` exists in Key Vault

### C. Deploy Konnect dataplane revision

```bash
bash scripts/deploy-konnect-dataplane.sh \
  --image-tag 1.12-konnect \
  --control-plane-endpoint <cp-endpoint> \
  --telemetry-endpoint <tp-endpoint> \
  --keyvault-name <kv-name>
```

- [ ] ACA deployment succeeded
- [ ] `https://<gateway>/status` is healthy
- [ ] Konnect portal shows the dataplane as **Connected**

### D. Sync existing JWT gateway config

```bash
export GATEWAY_BASE_URL="https://<gateway-fqdn>"
bash scripts/konnect-sync-config.sh \
  --control-plane-id <control-plane-id> \
  --config-file kong.yaml
```

- [ ] `mcp-service` exists in Konnect
- [ ] `/mcp/sse` route exists
- [ ] `/mcp/messages` route exists
- [ ] `poc-user` consumer exists

### E. Add OAuth routes

```bash
bash scripts/konnect-add-oauth-routes.sh \
  --control-plane-id <control-plane-id> \
  --entra-tenant-id <tenant-id> \
  --entra-client-id <resource-api-client-id>
```

- [ ] `/mcp/oauth/sse` exists
- [ ] `/mcp/oauth/messages` exists
- [ ] `openid-connect` is attached to the OAuth routes

If Entra setup is not ready yet:

- [ ] Mark OAuth route creation as **pending Entra setup**
- [ ] Record the missing values: tenant ID and resource API client ID
- [ ] Proceed with deployment/testing using the existing JWT route family only
- [ ] Re-run Step E after Entra setup is complete

## 3. Manual steps

- [ ] Create Konnect account / org
- [ ] Generate PAT in the Konnect portal
- [ ] Confirm Konnect geo selection is correct
- [ ] Verify the dataplane flips to **Connected** in Konnect
- [ ] Acquire a real Entra token for OAuth validation
- [ ] Test browser consent / sign-in experience

## 4. Validation steps

### JWT baseline

```bash
bash test/test-mcp-gateway.sh
```

- [ ] SSE bootstrap still works
- [ ] `tools/list` still works
- [ ] `calculate` and `get_weather` still work

### OAuth route family

- [ ] `GET /mcp/oauth/sse` accepts a valid Entra token
- [ ] SSE bootstrap advertises the correct public message path
- [ ] `POST /mcp/oauth/messages?sessionId=...` accepts the same token
- [ ] Wrong audience or missing `MCP.Use` scope is rejected

## 5. Rollback commands

### Roll back ACA revision

```bash
az containerapp revision list -g rg-kong-aca -n kongai-gw -o table
```

Activate the last known-good revision from before the Konnect deploy.

### Remove OAuth routes only

- Delete `mcp-oauth-sse-route`
- Delete `mcp-oauth-messages-route`
- Remove the two `openid-connect` plugin instances

### Full config rollback

- Restore the last exported/snapshotted Konnect config
- If needed, switch back to the prior DB-less ACA revision that still used the original `Dockerfile` + `kong.yaml`
