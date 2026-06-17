#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

RG="rg-kong-aca"
LOCATION="eastus2"
NAME_PREFIX="kongai"
IMAGE_TAG="kong-ai-gw:1.0"
MOCK_API_IMAGE_TAG="mock-api:1.0"
INFRA_DEPLOYMENT="${NAME_PREFIX}-infra"
MOCK_API_DEPLOYMENT="${NAME_PREFIX}-mock-api"
APP_DEPLOYMENT="${NAME_PREFIX}-app"

# ---------------------------------------------------------------------------
# Phase 1: ACR + Log Analytics + Container App Environment
# ---------------------------------------------------------------------------
echo "==> [Phase 1] Creating resource group..."
az group create -n "$RG" -l "$LOCATION" --output none

echo "==> [Phase 1] Deploying ACR, Log Analytics, and Container App Environment..."
az deployment group create \
  -g "$RG" \
  -n "$INFRA_DEPLOYMENT" \
  -f infra/acr.bicep \
  -p namePrefix="$NAME_PREFIX" location="$LOCATION" \
  --mode Incremental \
  --output none

echo "==> [Phase 1] Reading deployment outputs..."
ACR_NAME=$(az deployment group show -g "$RG" -n "$INFRA_DEPLOYMENT" --query "properties.outputs.acrName.value" -o tsv)
ACR_LOGIN=$(az deployment group show -g "$RG" -n "$INFRA_DEPLOYMENT" --query "properties.outputs.acrLoginServer.value" -o tsv)
ENV_ID=$(az deployment group show -g "$RG" -n "$INFRA_DEPLOYMENT" --query "properties.outputs.containerAppEnvId.value" -o tsv)

# ---------------------------------------------------------------------------
# Phase 2: Build and push Kong image using ACR cloud build (no local Docker)
# ---------------------------------------------------------------------------
echo "==> [Phase 2] Building Kong image in ACR (cloud build — no local Docker required)..."
az acr build \
  --registry "$ACR_NAME" \
  --image "$IMAGE_TAG" \
  .

# ---------------------------------------------------------------------------
# Phase 2.5: Build Mock API image and deploy Mock API Container App
# ---------------------------------------------------------------------------
echo "==> [Phase 2.5] Building Mock API image in ACR..."
az acr build \
  --registry "$ACR_NAME" \
  --image "$MOCK_API_IMAGE_TAG" \
  ./mock-api

echo "==> [Phase 2.5] Deploying Mock API Container App..."
az deployment group create \
  -g "$RG" \
  -n "$MOCK_API_DEPLOYMENT" \
  -f infra/mock-api.bicep \
  -p namePrefix="$NAME_PREFIX" \
     location="$LOCATION" \
     containerImage="$ACR_LOGIN/$MOCK_API_IMAGE_TAG" \
     acrName="$ACR_NAME" \
     containerAppEnvId="$ENV_ID" \
  --mode Incremental \
  --output none

MOCK_API_NAME=$(az deployment group show -g "$RG" -n "$MOCK_API_DEPLOYMENT" --query "properties.outputs.containerAppName.value" -o tsv)
MOCK_API_FQDN=$(az deployment group show -g "$RG" -n "$MOCK_API_DEPLOYMENT" --query "properties.outputs.containerAppFqdn.value" -o tsv)

echo "==> Mock API deployed: $MOCK_API_NAME (internal FQDN: $MOCK_API_FQDN)"

# ---------------------------------------------------------------------------
# Phase 3: Deploy Kong Container App with the custom image
# ---------------------------------------------------------------------------
echo "==> [Phase 3] Deploying Container App with custom image $ACR_LOGIN/$IMAGE_TAG..."
az deployment group create \
  -g "$RG" \
  -n "$APP_DEPLOYMENT" \
  -f infra/main.bicep \
  -p namePrefix="$NAME_PREFIX" \
     location="$LOCATION" \
     containerImage="$ACR_LOGIN/$IMAGE_TAG" \
     acrName="$ACR_NAME" \
     containerAppEnvId="$ENV_ID" \
  --mode Incremental \
  --output none

APP_NAME=$(az deployment group show -g "$RG" -n "$APP_DEPLOYMENT" --query "properties.outputs.containerAppName.value" -o tsv)

echo ""
echo "==> Deployment complete!"
echo ""
echo "Kong Gateway:"
echo "  App Name : $APP_NAME"
echo "  FQDN     : $(az containerapp show -g "$RG" -n "$APP_NAME" --query properties.configuration.ingress.fqdn -o tsv)"
echo ""
echo "Mock API:"
echo "  App Name : $MOCK_API_NAME"
echo "  Internal : $MOCK_API_FQDN (accessible only from within Container App Environment)"

