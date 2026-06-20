#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="$ROOT_DIR/scripts/.generated/konnect"
mkdir -p "$GENERATED_DIR"

CONTROL_PLANE_NAME="kong-aca-poc"
REGION="us"
KEYVAULT_NAME=""
KONNECT_PAT="${KONNECT_PAT:-}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash scripts/konnect-setup.sh [options]

Options:
  --pat <token>                 Konnect PAT. Falls back to KONNECT_PAT.
  --control-plane-name <name>   Control plane name. Default: kong-aca-poc
  --region <geo>                Konnect geo (us, eu, au, in, me). Default: us
  --keyvault-name <name>        Azure Key Vault name that will store cluster certs.
  --dry-run                     Print planned actions without changing Konnect or Azure.
  --help                        Show this help text.
EOF
}

log() { echo "[INFO] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

confirm() {
  local prompt="$1"
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] ' >&2
    printf '%q ' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "$@"
}

api_base_for_region() {
  case "$1" in
    us|eu|au|in|me) printf 'https://%s.api.konghq.com' "$1" ;;
    *) fail "Unsupported region '$1'. Expected one of: us, eu, au, in, me." ;;
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

try_api_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local response_file="$GENERATED_DIR/last-konnect-response.json"
  local status

  set +e
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
  set -e

  if [[ "$status" =~ ^2 ]]; then
    cat "$response_file"
    return 0
  fi
  return 1
}

json_filter_control_plane_by_name() {
  python - "$1" <<'PY'
import json
import sys

target = sys.argv[1]
payload = json.load(sys.stdin)
items = payload.get("data", payload if isinstance(payload, list) else [])
match = next((item for item in items if item.get("name") == target), None)
print(json.dumps(match or {}))
PY
}

json_get_field() {
  python - "$1" <<'PY'
import json
import sys

field = sys.argv[1]
payload = json.load(sys.stdin)
value = payload.get(field, "")
if isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
PY
}

create_json_payload() {
  python - "$@" <<'PY'
import json
import sys

name = sys.argv[1]
description = sys.argv[2]
print(json.dumps({
    "name": name,
    "description": description,
    "cluster_type": "CLUSTER_TYPE_CONTROL_PLANE",
    "auth_type": "pki_client_certs"
}))
PY
}

create_cert_payload() {
  python - "$1" <<'PY'
import json
import pathlib
import sys

cert_path = pathlib.Path(sys.argv[1])
print(json.dumps({"cert": cert_path.read_text(encoding="utf-8")}))
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pat)
      KONNECT_PAT="${2:-}"
      shift 2
      ;;
    --control-plane-name)
      CONTROL_PLANE_NAME="${2:-}"
      shift 2
      ;;
    --region)
      REGION="${2:-}"
      shift 2
      ;;
    --keyvault-name)
      KEYVAULT_NAME="${2:-}"
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
[[ -n "$KEYVAULT_NAME" ]] || fail "--keyvault-name is required."

require_command curl
require_command openssl
require_command python
require_command az
require_command kongctl

KONNECT_API_BASE="$(api_base_for_region "$REGION")"
export KONGCTL_DEFAULT_KONNECT_PAT="$KONNECT_PAT"

log "Validating Kong Konnect authentication..."
if [[ "$DRY_RUN" -eq 0 ]]; then
  kongctl get me >/dev/null
fi

log "Validating Azure CLI authentication..."
if [[ "$DRY_RUN" -eq 0 ]]; then
  az account show --output none
fi

log "Looking for existing control plane '$CONTROL_PLANE_NAME'..."
if [[ "$DRY_RUN" -eq 1 ]]; then
  CONTROL_PLANE_ID="<dry-run-control-plane-id>"
else
  existing_cp_json="$(api_request GET "/v2/control-planes" | json_filter_control_plane_by_name "$CONTROL_PLANE_NAME")"
  CONTROL_PLANE_ID="$(printf '%s' "$existing_cp_json" | json_get_field id)"

  if [[ -z "$CONTROL_PLANE_ID" ]]; then
    confirm "Create control plane '$CONTROL_PLANE_NAME' in Konnect geo '$REGION'?" || fail "Cancelled."
    cp_payload="$(create_json_payload "$CONTROL_PLANE_NAME" "ACA Konnect control plane for the Kong AI Gateway POC")"
    created_cp_json="$(api_request POST "/v2/control-planes" "$cp_payload")"
    CONTROL_PLANE_ID="$(printf '%s' "$created_cp_json" | json_get_field id)"
  else
    log "Reusing existing control plane ID: $CONTROL_PLANE_ID"
  fi
fi

CERT_FILE="$GENERATED_DIR/${CONTROL_PLANE_NAME}-cluster-cert.pem"
KEY_FILE="$GENERATED_DIR/${CONTROL_PLANE_NAME}-cluster-key.pem"
DETAILS_FILE="$GENERATED_DIR/${CONTROL_PLANE_NAME}-connection-details.json"

log "Generating a Konnect data plane client certificate..."
if [[ "$DRY_RUN" -eq 0 ]]; then
  rm -f "$CERT_FILE" "$KEY_FILE"
fi
run openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$KEY_FILE" \
  -out "$CERT_FILE" \
  -days 365 \
  -subj "/CN=${CONTROL_PLANE_NAME}/O=KongAIGatewayPOC"

log "Registering the public certificate with the control plane..."
if [[ "$DRY_RUN" -eq 0 ]]; then
  cert_payload="$(create_cert_payload "$CERT_FILE")"
  registered=0
  for path in \
    "/v2/control-planes/$CONTROL_PLANE_ID/dp-client-certificates" \
    "/v2/control-planes/$CONTROL_PLANE_ID/dp-certificates" \
    "/v2/control-planes/$CONTROL_PLANE_ID/data-plane-certificates"
  do
    if try_api_request POST "$path" "$cert_payload" >/dev/null; then
      log "Registered data plane certificate via $path"
      registered=1
      break
    fi
  done
  [[ "$registered" -eq 1 ]] || fail "Unable to register the data plane certificate. Check the Konnect API version in your org."
fi

CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ID}.${REGION}.cp0.konghq.com:443"
TELEMETRY_ENDPOINT="${CONTROL_PLANE_ID}.${REGION}.tp0.konghq.com:443"

log "Uploading client certificate and key to Azure Key Vault '$KEYVAULT_NAME'..."
run az keyvault secret set --vault-name "$KEYVAULT_NAME" --name kong-cluster-cert --file "$CERT_FILE" --output none
run az keyvault secret set --vault-name "$KEYVAULT_NAME" --name kong-cluster-key --file "$KEY_FILE" --output none

cat > "$DETAILS_FILE" <<EOF
{
  "controlPlaneId": "$CONTROL_PLANE_ID",
  "controlPlaneName": "$CONTROL_PLANE_NAME",
  "region": "$REGION",
  "controlPlaneEndpoint": "$CONTROL_PLANE_ENDPOINT",
  "telemetryEndpoint": "$TELEMETRY_ENDPOINT",
  "keyVaultName": "$KEYVAULT_NAME",
  "certificateSecretName": "kong-cluster-cert",
  "certificateKeySecretName": "kong-cluster-key"
}
EOF

if [[ "$DRY_RUN" -eq 0 ]]; then
  log "Validating that the Key Vault secrets exist..."
  az keyvault secret show --vault-name "$KEYVAULT_NAME" --name kong-cluster-cert --query id -o tsv >/dev/null
  az keyvault secret show --vault-name "$KEYVAULT_NAME" --name kong-cluster-key --query id -o tsv >/dev/null

  rm -f "$CERT_FILE" "$KEY_FILE"
fi

log "Konnect setup complete."
log "Connection details: $DETAILS_FILE"
log "Control plane endpoint: $CONTROL_PLANE_ENDPOINT"
log "Telemetry endpoint: $TELEMETRY_ENDPOINT"
