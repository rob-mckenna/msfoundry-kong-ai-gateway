# Kong Konnect Troubleshooting Guide

Use this guide after the ACA gateway is moved to **Konnect control plane + self-managed data plane** mode.

## Triage order

1. **Is the ACA container healthy?**
2. **Does Konnect show the data plane as Connected?**
3. **Does the current JWT route family still work?**
4. **Does OAuth fail before SSE, during SSE, or on the POST leg?**

## Useful commands

### Azure Container Apps

```powershell
az containerapp revision list -g rg-kong-aca -n kongai-gw -o table
az containerapp logs show -g rg-kong-aca -n kongai-gw --follow
az containerapp show -g rg-kong-aca -n kongai-gw --query properties.template.containers[0].env
```

### Key Vault access checks

```powershell
az role assignment list --scope <key-vault-resource-id> --assignee <principal-id> -o table
az keyvault secret show --vault-name <key-vault-name> --name kong-cluster-cert
```

### Gateway regression test

```bash
bash test/test-mcp-gateway.sh
```

---

## 1. Data plane connection issues

### Symptom: Konnect never shows `Connected`

**Likely causes**

- wrong `KONG_CLUSTER_CONTROL_PLANE` or telemetry endpoint
- missing `KONG_KONNECT_MODE=on`
- certificate/key secret not injected
- data plane image still using the OSS build without Konnect-capable features

**What to do**

1. Confirm ACA env vars for:
   - `KONG_ROLE=data_plane`
   - `KONG_DATABASE=off`
   - `KONG_CLUSTER_MTLS=pki`
   - `KONG_KONNECT_MODE=on`
   - `KONG_CLUSTER_CONTROL_PLANE=<host>:443`
   - `KONG_CLUSTER_TELEMETRY_ENDPOINT=<host>:443`
2. Confirm the data plane is using the intended Kong Gateway Enterprise/Konnect image.
3. Check that the cert and key secret refs resolved in ACA.
4. Restart or roll a new revision after fixing secrets.

### Symptom: Data plane was connected, then went `Out of sync`

**Likely causes**

- temporary network path failure to Konnect
- incompatible config or plugin set pushed from control plane
- expired/rotated certificate not yet applied to ACA

**What to do**

1. Check Kong logs for cluster/connectivity errors.
2. Confirm the current data plane version is supported by the control plane.
3. Confirm every configured plugin exists on the data plane image.
4. Recycle the ACA revision after any secret or version fix.

---

## 2. Certificate errors

### Symptom: log shows certificate or handshake failure

**Common messages**

- `failed to connect to control plane`
- `certificate verify failed`
- `bad certificate`
- `handshake failed`

**Likely causes**

- certificate and private key do not match
- wrong PEM formatting in Key Vault
- secret version rotated in Key Vault but ACA revision not restarted
- copied the wrong cert set from the wrong control plane

**What to do**

1. Re-copy the cert and key from the correct control plane.
2. Re-upload both secrets to Key Vault.
3. Verify the ACA managed identity still has **Key Vault Secrets User**.
4. Restart the Container App revision.
5. Watch logs and Konnect node status until it reconnects.

### Symptom: Konnect control plane exists but no new config arrives

**Likely causes**

- data plane stayed online with cached config after cert expiry or connectivity loss
- only one of cert/key was updated

**What to do**

- treat cert replacement as a pair operation
- restart the data plane after both secrets are updated
- confirm the node shows **Last Seen Just Now** in Konnect

---

## 3. Configuration sync problems

### Symptom: portal changes do not appear at the gateway

**Likely causes**

- data plane disconnected or out of sync
- config push failed because a plugin is unavailable
- edited the wrong geo or wrong control plane

**What to do**

1. Verify the correct Konnect org, geo, and control plane are selected.
2. Confirm the node is **Connected**.
3. Make a trivial route description change and watch whether it syncs within ~10 seconds.
4. If not, inspect logs for plugin compatibility errors.

### Symptom: route exists in Konnect but returns 404

**Likely causes**

- route path/method mismatch versus the old `kong.yaml`
- route attached to the wrong service
- path stripping behavior changed

**What to do**

1. Compare the live Konnect route to `docs/kong-yaml-to-konnect.md`.
2. Check:
   - path
   - method
   - strip path behavior
   - service association
3. Re-run the regression suite.

---

## 4. Existing JWT route failures

### Symptom: `/mcp/sse` now returns `401` or `403`

**Likely causes**

- consumer `poc-user` missing
- JWT credential not recreated in Konnect
- `iss=kong-poc` no longer matches the configured key
- `jwt` plugin attached at the wrong scope

**What to do**

1. Verify the consumer exists.
2. Verify the JWT credential:
   - key `kong-poc`
   - secret `poc-secret-change-me`
   - `HS256`
3. Verify the `jwt` plugin is attached to the JWT route family.
4. Re-run:

```bash
bash test/test-mcp-gateway.sh
```

### Symptom: SSE connects but `tools/list` or `tools/call` fails

**Likely causes**

- `/mcp/messages` route missing or misconfigured
- CORS/timeouts not recreated
- the MCP server session bootstrap worked, but POST traffic is not reaching the backend

**What to do**

1. Confirm `/mcp/messages` exists and allows `POST` + `OPTIONS`.
2. Confirm CORS and SSE timeout settings match the pre-Konnect setup.
3. Use the existing test suite to isolate the SSE step from the POST step.

---

## 5. OAuth validation failures

### Symptom: `/mcp/oauth/sse` returns `401`

**Likely causes**

- wrong Entra issuer
- token signed for the wrong audience
- `openid-connect` plugin attached to the wrong route
- OAuth request accidentally hitting the JWT routes

**What to do**

1. Confirm the route really is `/mcp/oauth/sse`.
2. Confirm `openid-connect` is attached to the OAuth route only.
3. Confirm issuer is `https://login.microsoftonline.com/<tenant-id>/v2.0`.
4. Confirm the token audience matches the custom API audience configured in Entra.

### Symptom: `/mcp/oauth/sse` works, but `/mcp/oauth/messages` fails

**Likely causes**

- MCP server still advertises `/mcp/messages`
- client omitted bearer token on the POST leg
- OAuth POST route missing from Konnect

**What to do**

1. Inspect the SSE bootstrap event and confirm the advertised endpoint is `/mcp/oauth/messages`.
2. Ensure the client sends the same bearer token on both the SSE and POST requests.
3. Confirm the POST route exists in Konnect.

### Symptom: OAuth returns `403` instead of `401`

**Likely causes**

- the `openid-connect` plugin still has a scope requirement enabled, but the Foundry token omits `scp`
- claim mapping or policy checks reject the token after signature validation

**What to do**

- clear the plugin scope requirement for the POC (`scopes=[]`, `scopes_required=[]`)
- confirm audience and tenant are correct
- review any additional claim/consumer restrictions applied in Konnect

---

## 6. Common error-to-fix mapping

| Error / symptom | Most likely fix |
| --- | --- |
| Data plane not `Connected` | verify Konnect env vars, cert secrets, Enterprise image |
| `certificate verify failed` | replace cert/key pair and restart ACA revision |
| Config edits never appear | fix connectivity or plugin compatibility |
| `/mcp/sse` returns `401` after migration | recreate consumer + JWT credential + jwt plugin parity |
| `/mcp/oauth/sse` returns `401` | fix issuer or audience |
| OAuth SSE works but POST fails | fix advertised MCP message path or missing POST auth |
| Route returns `404` | fix path, method, or route-to-service mapping |

---

## 7. Rollback guidance

### Fast rollback: keep Konnect, remove only OAuth

Use when the data plane is healthy and JWT still works.

- disable `/mcp/oauth/*`
- remove `openid-connect`
- keep the JWT baseline intact

### Full rollback: restore DB-less revision

Use when Konnect cutover itself is unstable.

- activate or redeploy the last known-good ACA revision that uses baked-in `kong.yaml`
- leave the Konnect control plane untouched for later retry
- confirm `bash test/test-mcp-gateway.sh` passes again

---

## 8. What “good” looks like

A healthy Konnect migration has all of these:

- ACA revision is healthy
- Konnect shows **Connected** / **Last Seen Just Now**
- portal config changes appear quickly
- `bash test/test-mcp-gateway.sh` passes
- OAuth token test passes on `/mcp/oauth/*`
- logs distinguish JWT traffic from OAuth traffic without logging raw tokens
