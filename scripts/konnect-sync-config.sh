#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATED_DIR="$ROOT_DIR/scripts/.generated/konnect"
mkdir -p "$GENERATED_DIR"

CONTROL_PLANE_ID=""
CONFIG_FILE="kong.yaml"
KONNECT_PAT="${KONNECT_PAT:-}"
REGION="${KONNECT_REGION:-us}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash scripts/konnect-sync-config.sh [options]

Options:
  --pat <token>             Konnect PAT. Falls back to KONNECT_PAT.
  --control-plane-id <id>   Target control plane ID.
  --config-file <path>      Declarative config file. Default: kong.yaml
  --dry-run                 Preview the kongctl plan without applying changes.
  --help                    Show this help text.

Optional environment variables:
  KONNECT_REGION            Konnect geo. Default: us
  GATEWAY_BASE_URL          If set, runs bash test/test-mcp-gateway.sh after sync.
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
  local response_file="$GENERATED_DIR/last-konnect-response.json"
  local status

  status=$(curl -sS -o "$response_file" -w "%{http_code}" -X "$method" \
    "$KONNECT_API_BASE$path" \
    -H "Authorization: Bearer $KONNECT_PAT")

  if [[ ! "$status" =~ ^2 ]]; then
    cat "$response_file" >&2 || true
    fail "Konnect API call failed with HTTP $status for $path"
  fi

  cat "$response_file"
}

json_get_field() {
  python - "$1" <<'PY'
import json
import sys

field = sys.argv[1]
payload = json.load(sys.stdin)
value = payload.get(field, "")
if isinstance(value, (list, dict)):
    print(json.dumps(value))
else:
    print(value)
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
    --config-file)
      CONFIG_FILE="${2:-}"
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
[[ -f "$ROOT_DIR/$CONFIG_FILE" || -f "$CONFIG_FILE" ]] || fail "Config file not found: $CONFIG_FILE"

require_command curl
require_command python
require_command kongctl

CONFIG_PATH="$CONFIG_FILE"
if [[ ! -f "$CONFIG_PATH" ]]; then
  CONFIG_PATH="$ROOT_DIR/$CONFIG_FILE"
fi

KONNECT_API_BASE="$(api_base_for_region "$REGION")"
export KONGCTL_DEFAULT_KONNECT_PAT="$KONNECT_PAT"

log "Validating Kong Konnect authentication..."
if [[ "$DRY_RUN" -eq 0 ]]; then
  kongctl get me >/dev/null
fi

cp_json="$(api_request GET "/v2/control-planes/$CONTROL_PLANE_ID")"
CONTROL_PLANE_NAME="$(printf '%s' "$cp_json" | json_get_field name)"
[[ -n "$CONTROL_PLANE_NAME" ]] || fail "Unable to resolve control plane name from ID $CONTROL_PLANE_ID"

MANIFEST_PATH="$GENERATED_DIR/kongctl-sync-${CONTROL_PLANE_ID}.yaml"
cat > "$MANIFEST_PATH" <<EOF
control_planes:
  - ref: target-control-plane
    name: "$CONTROL_PLANE_NAME"
    _deck:
      files:
        - "$CONFIG_PATH"
      flags:
        - "--konnect-addr=$KONNECT_API_BASE"
        - "--konnect-control-plane-name=$CONTROL_PLANE_NAME"
EOF

log "Generated kongctl sync manifest at $MANIFEST_PATH"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "Running kongctl plan only..."
  kongctl plan -f "$MANIFEST_PATH"
  exit 0
fi

log "Syncing gateway configuration into Konnect via kongctl..."
kongctl sync -f "$MANIFEST_PATH"

log "Validating core entities exist in the control plane..."
api_request GET "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/services" >/dev/null
api_request GET "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/routes" >/dev/null
api_request GET "/v2/control-planes/$CONTROL_PLANE_ID/core-entities/consumers" >/dev/null

if [[ -n "${GATEWAY_BASE_URL:-}" ]]; then
  log "Running the existing JWT regression suite against $GATEWAY_BASE_URL"
  GATEWAY_BASE_URL="$GATEWAY_BASE_URL" bash "$ROOT_DIR/test/test-mcp-gateway.sh"
else
  log "Skipping live JWT route validation because GATEWAY_BASE_URL is not set."
fi

log "Konnect config sync complete for control plane '$CONTROL_PLANE_NAME'."
