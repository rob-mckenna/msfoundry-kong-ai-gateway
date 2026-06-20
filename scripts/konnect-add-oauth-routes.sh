#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="$ROOT_DIR/scripts/.generated/konnect"
mkdir -p "$GENERATED_DIR"

CONTROL_PLANE_ID=""
ENTRA_TENANT_ID=""
ENTRA_CLIENT_ID=""
KONNECT_PAT="${KONNECT_PAT:-}"
REGION="${KONNECT_REGION:-us}"
DRY_RUN=0
OAUTH_SERVICE_NAME="mcp-oauth-service"
OAUTH_SSE_ROUTE_NAME="mcp-oauth-sse"
OAUTH_MESSAGES_ROUTE_NAME="mcp-oauth-messages"
OAUTH_MESSAGES_PATH="/mcp/oauth/messages"

usage() {
  cat <<'EOF'
Usage: bash scripts/konnect-add-oauth-routes.sh [options]

Options:
  --pat <token>               Konnect PAT. Falls back to KONNECT_PAT.
  --control-plane-id <id>     Target control plane ID.
  --entra-tenant-id <id>      Microsoft Entra tenant ID.
  --entra-client-id <id>      Microsoft Entra Resource API client ID.
  --dry-run                   Print the intended route/plugin changes.
  --help                      Show this help text.
EOF
}

log() { echo "[INFO] $*" >&2; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

api_base_for_region() {
  case "$1" in
    us|eu|au|in|me) printf 'https://%s.api.konghq.com' "$1" ;;
    *) fail "Unsupported region '$1'." ;;
  esac
}

api_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local response_file="$GENERATED_DIR/last-konnect-response.json"
  local status

  if [[ -n "$body" ]]; then
    status=$(curl -sS -o "$response_file" -w "%{http_code}" -X "$method" \
      "$KONNECT_API_BASE$path" \
      -H "Authorization: Bearer $KONNECT_PAT" \
      -H "Content-Type: application/json" \
      --data "$body")
  else
    status=$(curl -sS -o "$response_file" -w "%{http_code}" -X "$method" \
      "$KONNECT_API_BASE$path" \
      -H "Authorization: Bearer $KONNECT_PAT")
  fi

  if [[ ! "$status" =~ ^2 ]]; then
    cat "$response_file" >&2 || true
    fail "Konnect API call failed with HTTP $status for $path"
  fi

  cat "$response_file"
}

json_find_id_by_name() {
  python - "$1" <<'PY'
import json
import sys

target = sys.argv[1]
payload = json.load(sys.stdin)
items = payload.get("data", payload if isinstance(payload, list) else [])
match = next((item for item in items if item.get("name") == target), None)
print((match or {}).get("id", ""))
PY
}

build_route_payload() {
  python - "$@" <<'PY'
import json
import sys

name, service_id, path, method = sys.argv[1:5]
print(json.dumps({
    "name": name,
    "service": {"id": service_id},
    "paths": [path],
    "methods": [method, "OPTIONS"],
    "strip_path": False,
    "preserve_host": False,
}))
PY
}

build_service_payload() {
  python - "$@" <<'PY'
import json
import sys

name, host, protocol, port = sys.argv[1:5]
print(json.dumps({
    "name": name,
    "host": host,
    "protocol": protocol,
    "port": int(port),
}))
PY
}

build_oidc_plugin_payload() {
  python - "$@" <<'PY'
import json
import sys

tenant_id, client_id, route_id = sys.argv[1:4]
issuer = f"https://login.microsoftonline.com/{tenant_id}/v2.0"
print(json.dumps({
    "name": "openid-connect",
    "route": {"id": route_id},
    "config": {
        "issuer": issuer,
        "client_id": [client_id],
        "auth_methods": ["bearer"],
        "audience_required": [f"api://{client_id}"],
        "scopes": [],
        "scopes_required": [],
        "bearer_token_param_type": ["header"],
        "consumer_optional": False,
        "upstream_headers_claims": ["oid", "preferred_username", "name"],
        "upstream_headers_names": ["x-user-oid", "x-user-upn", "x-user-name"],
    }
}))
PY
}

build_pre_function_payload() {
  python - "$@" <<'PY'
import json
import sys

route_id = sys.argv[1]
lines = sys.argv[2:]
print(json.dumps({
    "name": "pre-function",
    "route": {"id": route_id},
    "config": {
        "access": lines,
    }
}))
PY
}

build_cors_payload() {
  python - "$@" <<'PY'
import json
import sys

route_id, method, exposed_header = sys.argv[1:4]
config = {
    "origins": ["*"],
    "methods": [method, "OPTIONS"],
    "headers": ["Accept", "Authorization", "Content-Type"],
    "credentials": True,
    "max_age": 3600,
}
if exposed_header:
    config["exposed_headers"] = [exposed_header]
print(json.dumps({
    "name": "cors",
    "route": {"id": route_id},
    "config": config,
}))
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pat)
      KONNECT_PAT="${2:-}"
      shift 2
      ;;
    --control-plane-id)
      CONTROL_PLANE_ID="${2:-}"
      shift 2
      ;;
    --entra-tenant-id)
      ENTRA_TENANT_ID="${2:-}"
      shift 2
      ;;
    --entra-client-id)
      ENTRA_CLIENT_ID="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ -n "$KONNECT_PAT" ]] || fail "Provide --pat or set KONNECT_PAT."
[[ -n "$CONTROL_PLANE_ID" ]] || fail "--control-plane-id is required."
[[ -n "$ENTRA_TENANT_ID" ]] || fail "--entra-tenant-id is required."
[[ -n "$ENTRA_CLIENT_ID" ]] || fail "--entra-client-id is required."

require_command curl
require_command python
require_command kongctl

KONNECT_API_BASE="$(api_base_for_region "$REGION")"
export KONGCTL_DEFAULT_KONNECT_PAT="$KONNECT_PAT"

if [[ "$DRY_RUN" -eq 0 ]]; then
  kongctl get me >/dev/null
fi

services_json="$(api_request GET "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/services")"
MCP_SERVICE_ID="$(printf '%s' "$services_json" | json_find_id_by_name "mcp-service")"
[[ -n "$MCP_SERVICE_ID" ]] || fail "The mcp-service service was not found. Run the sync script first."
OAUTH_SERVICE_ID="$(printf '%s' "$services_json" | json_find_id_by_name "$OAUTH_SERVICE_NAME")"
MCP_SERVICE_HOST="$(printf '%s' "$services_json" | python -c 'import json,sys; payload=json.load(sys.stdin); items=payload.get("data", []); match=next((item for item in items if item.get("name")=="mcp-service"), {}); print(match.get("host",""))')"
MCP_SERVICE_PROTOCOL="$(printf '%s' "$services_json" | python -c 'import json,sys; payload=json.load(sys.stdin); items=payload.get("data", []); match=next((item for item in items if item.get("name")=="mcp-service"), {}); print(match.get("protocol",""))')"
MCP_SERVICE_PORT="$(printf '%s' "$services_json" | python -c 'import json,sys; payload=json.load(sys.stdin); items=payload.get("data", []); match=next((item for item in items if item.get("name")=="mcp-service"), {}); print(match.get("port",""))')"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Would create $OAUTH_SERVICE_NAME mirroring mcp-service ($MCP_SERVICE_ID) for auth isolation."
  log "Would create /mcp/oauth/sse and /mcp/oauth/messages routes on $OAUTH_SERVICE_NAME."
  log "Would attach pre-function path rewrites, openid-connect bearer validation, and route-level CORS."
  exit 0
fi

if [[ -z "$OAUTH_SERVICE_ID" ]]; then
  service_payload="$(build_service_payload "$OAUTH_SERVICE_NAME" "$MCP_SERVICE_HOST" "$MCP_SERVICE_PROTOCOL" "$MCP_SERVICE_PORT")"
  OAUTH_SERVICE_ID="$(api_request POST "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/services" "$service_payload" | python -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
fi

routes_json="$(api_request GET "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/routes")"
oauth_sse_route_id="$(printf '%s' "$routes_json" | json_find_id_by_name "$OAUTH_SSE_ROUTE_NAME")"
oauth_messages_route_id="$(printf '%s' "$routes_json" | json_find_id_by_name "$OAUTH_MESSAGES_ROUTE_NAME")"

if [[ -z "$oauth_sse_route_id" ]]; then
  route_payload="$(build_route_payload "$OAUTH_SSE_ROUTE_NAME" "$OAUTH_SERVICE_ID" "/mcp/oauth/sse" "GET")"
  oauth_sse_route_id="$(api_request POST "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/routes" "$route_payload" | python -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
fi

if [[ -z "$oauth_messages_route_id" ]]; then
  route_payload="$(build_route_payload "$OAUTH_MESSAGES_ROUTE_NAME" "$OAUTH_SERVICE_ID" "/mcp/oauth/messages" "POST")"
  oauth_messages_route_id="$(api_request POST "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/routes" "$route_payload" | python -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
fi

plugins_json="$(api_request GET "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/plugins")"
get_plugin_id_for_route() {
  python - "$1" "$2" <<'PY'
import json
import sys

route_id = sys.argv[1]
plugin_name = sys.argv[2]
payload = json.load(sys.stdin)
items = payload.get("data", payload if isinstance(payload, list) else [])
match = next((item for item in items if item.get("name") == plugin_name and (item.get("route") or {}).get("id") == route_id), None)
print((match or {}).get("id", ""))
PY
}

has_plugin_for_route() {
python - "$1" "$2" <<'PY'
import json
import sys

route_id = sys.argv[1]
plugin_name = sys.argv[2]
payload = json.load(sys.stdin)
items = payload.get("data", payload if isinstance(payload, list) else [])
match = next((item for item in items if item.get("name") == plugin_name and (item.get("route") or {}).get("id") == route_id), None)
print("1" if match else "")
PY
}

if [[ -z "$(printf '%s' "$plugins_json" | has_plugin_for_route "$oauth_sse_route_id" "pre-function")" ]]; then
plugin_payload="$(build_pre_function_payload "$oauth_sse_route_id" "kong.service.request.set_path('/mcp/sse')" "kong.service.request.set_header('x-external-mcp-messages-path', '$OAUTH_MESSAGES_PATH')")"
api_request POST "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/plugins" "$plugin_payload" >/dev/null
fi

if [[ -z "$(printf '%s' "$plugins_json" | has_plugin_for_route "$oauth_messages_route_id" "pre-function")" ]]; then
plugin_payload="$(build_pre_function_payload "$oauth_messages_route_id" "kong.service.request.set_path('/mcp/messages')")"
api_request POST "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/plugins" "$plugin_payload" >/dev/null
fi

oauth_sse_oidc_plugin_id="$(printf '%s' "$plugins_json" | get_plugin_id_for_route "$oauth_sse_route_id" "openid-connect")"
if [[ -z "$oauth_sse_oidc_plugin_id" ]]; then
plugin_payload="$(build_oidc_plugin_payload "$ENTRA_TENANT_ID" "$ENTRA_CLIENT_ID" "$oauth_sse_route_id")"
api_request POST "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/plugins" "$plugin_payload" >/dev/null
else
plugin_payload="$(build_oidc_plugin_payload "$ENTRA_TENANT_ID" "$ENTRA_CLIENT_ID" "$oauth_sse_route_id" | python -c 'import json,sys; payload=json.load(sys.stdin); print(json.dumps({"config": payload["config"]}))')"
api_request PATCH "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/plugins/$oauth_sse_oidc_plugin_id" "$plugin_payload" >/dev/null
fi

oauth_messages_oidc_plugin_id="$(printf '%s' "$plugins_json" | get_plugin_id_for_route "$oauth_messages_route_id" "openid-connect")"
if [[ -z "$oauth_messages_oidc_plugin_id" ]]; then
plugin_payload="$(build_oidc_plugin_payload "$ENTRA_TENANT_ID" "$ENTRA_CLIENT_ID" "$oauth_messages_route_id")"
api_request POST "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/plugins" "$plugin_payload" >/dev/null
else
plugin_payload="$(build_oidc_plugin_payload "$ENTRA_TENANT_ID" "$ENTRA_CLIENT_ID" "$oauth_messages_route_id" | python -c 'import json,sys; payload=json.load(sys.stdin); print(json.dumps({"config": payload["config"]}))')"
api_request PATCH "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/plugins/$oauth_messages_oidc_plugin_id" "$plugin_payload" >/dev/null
fi

if [[ -z "$(printf '%s' "$plugins_json" | has_plugin_for_route "$oauth_sse_route_id" "cors")" ]]; then
  plugin_payload="$(build_cors_payload "$oauth_sse_route_id" "GET" "X-Auth-Token")"
  api_request POST "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/plugins" "$plugin_payload" >/dev/null
fi

if [[ -z "$(printf '%s' "$plugins_json" | has_plugin_for_route "$oauth_messages_route_id" "cors")" ]]; then
  plugin_payload="$(build_cors_payload "$oauth_messages_route_id" "POST" "")"
  api_request POST "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/plugins" "$plugin_payload" >/dev/null
fi

log "OAuth routes created."
log "Validate with:"
log "  GET /mcp/oauth/sse"
log "  POST /mcp/oauth/messages?sessionId=..."
