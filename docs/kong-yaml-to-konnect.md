# Mapping `kong.yaml` to Konnect

This guide translates the current DB-less declarative file into the Konnect entities Rob needs to recreate before moving the ACA gateway into data plane mode.

## Core difference

| DB-less today | Konnect target |
| --- | --- |
| `kong.yaml` is the source of truth | Konnect control plane is the source of truth |
| config is baked into the image | config is pushed from portal/API to the data plane |
| `KONG_DECLARATIVE_CONFIG` points at a local file | no declarative file is required at runtime |
| rollback = restore prior file/image | rollback = restore prior control plane config or prior ACA revision |

## Current file inventory

The current `kong.yaml` defines:

- one consumer: `poc-user`
- one JWT secret for shared POC auth
- service `chat`
- service `mcp-service`
- route `chat-route`
- route `mcp-sse-route`
- route `mcp-messages-route`
- plugins: `jwt`, `post-function`, `rate-limiting`, `cors`

## Mapping overview

| `kong.yaml` concept | Current example | Konnect entity |
| --- | --- | --- |
| `consumers[]` | `poc-user` | Consumer |
| `jwt_secrets[]` | `key=kong-poc`, `secret=poc-secret-change-me` | Consumer -> JWT credential |
| `services[]` | `chat`, `mcp-service` | Gateway Service |
| `routes[]` | `/chat`, `/mcp/sse`, `/mcp/messages` | Route |
| `plugins[]` under service | `jwt`, `cors`, `post-function`, `rate-limiting` | Plugin attached to service or route |

## Side-by-side translation

### 1. Consumer mapping

#### Current declarative snippet

```yaml
consumers:
  - username: poc-user
    jwt_secrets:
      - key: kong-poc
        secret: poc-secret-change-me
        algorithm: HS256
```

#### Konnect translation

1. Create consumer **poc-user**.
2. Add a **JWT credential** to that consumer.
3. Set:
   - key / issuer identifier: `kong-poc`
   - secret: `poc-secret-change-me`
   - algorithm: `HS256`

#### Why it matters

The existing MCP tests and Foundry POC assume `iss=kong-poc` and the shared HMAC secret. If the consumer credential is missing or mismatched, the Konnect data plane will return `401/403` on the existing JWT route family.

### 2. `mcp-service` mapping

#### Current declarative snippet

```yaml
- name: mcp-service
  url: https://kongai-mcp-server.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io
```

#### Konnect translation

Create a Gateway Service:

- Name: `mcp-service`
- Protocol/host/path: same upstream ACA internal HTTPS URL
- Notes: keep the upstream unchanged so the cutover only changes control-plane ownership, not backend topology

### 3. MCP route mapping

#### Current declarative snippet

```yaml
routes:
  - name: mcp-sse-route
    paths: ['/mcp/sse']
    methods: [GET, OPTIONS]
  - name: mcp-messages-route
    paths: ['/mcp/messages']
    methods: [POST, OPTIONS]
```

#### Konnect translation

Create two routes under `mcp-service`:

| Route | Path | Methods | Notes |
| --- | --- | --- | --- |
| `mcp-sse-route` | `/mcp/sse` | `GET`, `OPTIONS` | SSE bootstrap |
| `mcp-messages-route` | `/mcp/messages` | `POST`, `OPTIONS` | JSON-RPC POST leg |

Keep `strip_path=false` behavior equivalent if the UI/API exposes it, because the MCP server already expects those public paths.

### 4. JWT plugin mapping

#### Current declarative snippet

```yaml
- name: jwt
  config:
    claims_to_verify:
      - exp
    uri_param_names:
      - jwt
    key_claim_name: iss
    secret_is_base64: false
```

#### Konnect translation

Attach a `jwt` plugin to `mcp-service` or to the two MCP routes.

Set the same behavior:

- verify `exp`
- key claim name = `iss`
- HMAC secret is plain text, not base64
- keep header-based `Authorization: Bearer` usage aligned with the existing test suite

**Recommendation:** attach it only to the JWT route family, not globally, so `/mcp/oauth/*` can use `openid-connect` independently.

### 5. CORS plugin mapping for MCP routes

#### Current declarative snippet

```yaml
- name: cors
  config:
    methods: [GET, POST, OPTIONS]
    headers: [Accept, Content-Type, Authorization, Cache-Control, Connection]
    exposed_headers: [Content-Type, Cache-Control, Connection]
    credentials: true
```

#### Konnect translation

Recreate the same CORS policy on the MCP route family:

- methods: `GET`, `POST`, `OPTIONS`
- allow headers: `Accept`, `Content-Type`, `Authorization`, `Cache-Control`, `Connection`
- expose headers: `Content-Type`, `Cache-Control`, `Connection`
- credentials: `true`

This is important for SSE browser/client behavior and for parity with the current route setup.

### 6. Future OAuth route mapping

The current file does not include OAuth routes, but Konnect should add them as **new entities**, not by overloading the JWT routes.

| New Konnect entity | Purpose |
| --- | --- |
| `mcp-oauth-sse-route` | `GET /mcp/oauth/sse` |
| `mcp-oauth-messages-route` | `POST /mcp/oauth/messages` |
| `openid-connect` plugin | validates Entra access tokens |

### 7. `chat` service mapping

#### Current declarative snippet

The `chat` service currently includes:

- upstream Azure OpenAI URL
- `jwt` plugin
- `post-function` plugin to swap client auth for managed identity
- `rate-limiting`
- `cors`
- route `/chat`

#### Konnect translation

If the `/chat` endpoint is still part of the demo, recreate all of those entities in Konnect too:

| Current item | Konnect equivalent |
| --- | --- |
| `chat` service | Gateway Service `chat` |
| `/chat` route | Route `chat-route` |
| service-scoped `jwt` | `jwt` plugin on the service or route |
| `post-function` Lua | `post-function` plugin on the service |
| `rate-limiting` | `rate-limiting` plugin |
| `cors` | `cors` plugin |

### 8. Plugin placement guidance

| Plugin | Best scope for this repo | Why |
| --- | --- | --- |
| `jwt` for `/mcp/*` | route family or `mcp-service` | keep current JWT behavior isolated |
| `openid-connect` for `/mcp/oauth/*` | OAuth routes only | avoids mixed auth errors |
| `cors` | route family or service | mirror current browser/SSE posture |
| `post-function` | `chat` service only | it is only needed for Azure OpenAI token swap |
| `rate-limiting` | `chat` service | current repo uses it there only |

## Example translation checklist

### Required before Konnect cutover

- [ ] Create consumer `poc-user`
- [ ] Create JWT credential `kong-poc`
- [ ] Create `mcp-service`
- [ ] Create `mcp-sse-route`
- [ ] Create `mcp-messages-route`
- [ ] Reapply `jwt`
- [ ] Reapply `cors`
- [ ] Recreate `chat` service stack if still needed
- [ ] Export/snapshot Konnect config
- [ ] Only then switch ACA to data plane mode

## Recommended rollback translation

If something breaks after migration:

1. compare the live Konnect service/route/plugin objects to the original `kong.yaml`
2. restore missing consumer/plugin settings first
3. if parity cannot be restored quickly, roll back the ACA revision to the previous DB-less image

## Quick reference

| If you see this in `kong.yaml` | Create this in Konnect |
| --- | --- |
| `username` | Consumer |
| `jwt_secrets` | Consumer JWT credential |
| `name` + `url` under `services` | Gateway Service |
| `paths` + `methods` under `routes` | Route |
| `plugins` block | Plugin attachment on service/route |

Konnect can later export backup configuration, but during steady-state operation the portal/API replaces the declarative file as the control-plane source of truth.
