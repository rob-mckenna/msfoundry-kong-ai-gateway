#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE_TAG=""
CONTROL_PLANE_ENDPOINT=""
TELEMETRY_ENDPOINT=""
KEYVAULT_NAME=""
RESOURCE_GROUP="rg-kong-aca"
LOCATION="eastus2"
NAME_PREFIX="kongai"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash scripts/deploy-konnect-dataplane.sh [options]

Options:
  --image-tag <tag>                 Required. Example: 1.12-konnect
  --control-plane-endpoint <host>   Required. Example: <cp-id>.us.cp0.konghq.com:443
  --telemetry-endpoint <host>       Required. Example: <cp-id>.us.tp0.konghq.com:443
  --keyvault-name <name>            Required. Azure Key Vault holding kong-cluster-cert/key.
  --dry-run                         Print the deployment actions without executing them.
  --help                            Show this help text.
EOF
}

log() { echo "[INFO] $*" >&2; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-tag)
      IMAGE_TAG="${2:-}"
      shift 2
      ;;
    --control-plane-endpoint)
      CONTROL_PLANE_ENDPOINT="${2:-}"
      shift 2
      ;;
    --telemetry-endpoint)
      TELEMETRY_ENDPOINT="${2:-}"
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

[[ -n "$IMAGE_TAG" ]] || fail "--image-tag is required."
[[ -n "$CONTROL_PLANE_ENDPOINT" ]] || fail "--control-plane-endpoint is required."
[[ -n "$TELEMETRY_ENDPOINT" ]] || fail "--telemetry-endpoint is required."
[[ -n "$KEYVAULT_NAME" ]] || fail "--keyvault-name is required."

require_command az
require_command curl

if [[ "$DRY_RUN" -eq 0 ]]; then
  az account show --output none
fi

ACR_NAME="$(az deployment group show -g "$RESOURCE_GROUP" -n "${NAME_PREFIX}-infra" --query "properties.outputs.acrName.value" -o tsv 2>/dev/null || true)"
if [[ -z "$ACR_NAME" ]]; then
  ACR_NAME="$(az acr list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)"
fi
[[ -n "$ACR_NAME" ]] || fail "Unable to discover the ACR name."

ACR_LOGIN="$(az acr show -g "$RESOURCE_GROUP" -n "$ACR_NAME" --query loginServer -o tsv)"
ENV_ID="$(az containerapp env list -g "$RESOURCE_GROUP" --query "[0].id" -o tsv)"
[[ -n "$ENV_ID" ]] || fail "Unable to discover the Container App Environment ID."

log "Validating Key Vault secret references..."
run az keyvault secret show --vault-name "$KEYVAULT_NAME" --name kong-cluster-cert --query id -o tsv
run az keyvault secret show --vault-name "$KEYVAULT_NAME" --name kong-cluster-key --query id -o tsv

KONG_IMAGE="kong-ai-gw:${IMAGE_TAG}"
FULL_IMAGE="$ACR_LOGIN/$KONG_IMAGE"

log "Building Konnect data plane image from Dockerfile.konnect..."
run az acr build \
  --registry "$ACR_NAME" \
  --image "$KONG_IMAGE" \
  --file "$ROOT_DIR/Dockerfile.konnect" \
  "$ROOT_DIR"

log "Deploying ACA revision with infra/main-konnect.bicep..."
run az deployment group create \
  -g "$RESOURCE_GROUP" \
  -n "${NAME_PREFIX}-konnect-app" \
  -f "$ROOT_DIR/infra/main-konnect.bicep" \
  -p namePrefix="$NAME_PREFIX" \
     location="$LOCATION" \
     containerImage="$FULL_IMAGE" \
     acrName="$ACR_NAME" \
     containerAppEnvId="$ENV_ID" \
     keyVaultName="$KEYVAULT_NAME" \
     kongClusterControlPlane="$CONTROL_PLANE_ENDPOINT" \
     kongClusterTelemetryEndpoint="$TELEMETRY_ENDPOINT" \
  --mode Incremental \
  --output none

if [[ "$DRY_RUN" -eq 1 ]]; then
  exit 0
fi

APP_NAME="$(az deployment group show -g "$RESOURCE_GROUP" -n "${NAME_PREFIX}-konnect-app" --query "properties.outputs.containerAppName.value" -o tsv)"
FQDN="$(az deployment group show -g "$RESOURCE_GROUP" -n "${NAME_PREFIX}-konnect-app" --query "properties.outputs.containerAppFqdn.value" -o tsv)"

log "Validating the deployed Container App revision..."
az containerapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" --query "properties.latestRevisionName" -o tsv >/dev/null
curl -fsS "https://$FQDN/status" >/dev/null

log "Konnect data plane deployment complete."
log "Gateway URL: https://$FQDN"
log "Next step: run bash scripts/konnect-sync-config.sh and then bash test/test-mcp-gateway.sh"
