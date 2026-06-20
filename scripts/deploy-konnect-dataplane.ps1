[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ImageTag,
    [Parameter(Mandatory = $true)]
    [string]$ControlPlaneEndpoint,
    [Parameter(Mandatory = $true)]
    [string]$TelemetryEndpoint,
    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$resourceGroup = 'rg-kong-aca'
$location = 'eastus2'
$namePrefix = 'kongai'

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" }
function Fail([string]$Message) { throw "[ERROR] $Message" }

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Fail "Required command not found: $Name"
    }
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if ($DryRun) {
        Write-Host "[DRY-RUN] $Description"
        return $null
    }

    & $Action
}

Require-Command 'az'
Require-Command 'curl'

Invoke-Step -Description 'az account show --output none' -Action {
    & az account show --output none | Out-Null
}

$acrName = (& az deployment group show -g $resourceGroup -n "$namePrefix-infra" --query "properties.outputs.acrName.value" -o tsv 2>$null)
if ([string]::IsNullOrWhiteSpace($acrName)) {
    $acrName = (& az acr list -g $resourceGroup --query "[0].name" -o tsv)
}
if ([string]::IsNullOrWhiteSpace($acrName)) {
    Fail 'Unable to discover the ACR name.'
}

$acrLogin = & az acr show -g $resourceGroup -n $acrName --query loginServer -o tsv
$envId = & az containerapp env list -g $resourceGroup --query "[0].id" -o tsv
if ([string]::IsNullOrWhiteSpace($envId)) {
    Fail 'Unable to discover the Container App Environment ID.'
}

Write-Info 'Validating Key Vault secret references...'
Invoke-Step -Description "az keyvault secret show --vault-name $KeyVaultName --name kong-cluster-cert" -Action {
    & az keyvault secret show --vault-name $KeyVaultName --name kong-cluster-cert --query id -o tsv | Out-Null
}
Invoke-Step -Description "az keyvault secret show --vault-name $KeyVaultName --name kong-cluster-key" -Action {
    & az keyvault secret show --vault-name $KeyVaultName --name kong-cluster-key --query id -o tsv | Out-Null
}

$kongImage = "kong-ai-gw:$ImageTag"
$fullImage = "$acrLogin/$kongImage"

Write-Info 'Building Konnect data plane image from Dockerfile.konnect...'
Invoke-Step -Description "az acr build --registry $acrName --image $kongImage --file $root\Dockerfile.konnect $root" -Action {
    & az acr build --registry $acrName --image $kongImage --file (Join-Path $root 'Dockerfile.konnect') $root
}

Write-Info 'Deploying ACA revision with infra/main-konnect.bicep...'
Invoke-Step -Description "az deployment group create -g $resourceGroup -n $namePrefix-konnect-app ..." -Action {
    & az deployment group create `
        -g $resourceGroup `
        -n "$namePrefix-konnect-app" `
        -f (Join-Path $root 'infra\main-konnect.bicep') `
        -p namePrefix=$namePrefix `
           location=$location `
           containerImage=$fullImage `
           acrName=$acrName `
           containerAppEnvId=$envId `
           keyVaultName=$KeyVaultName `
           kongClusterControlPlane=$ControlPlaneEndpoint `
           kongClusterTelemetryEndpoint=$TelemetryEndpoint `
        --mode Incremental `
        --output none | Out-Null
}

if ($DryRun) {
    return
}

$appName = & az deployment group show -g $resourceGroup -n "$namePrefix-konnect-app" --query "properties.outputs.containerAppName.value" -o tsv
$fqdn = & az deployment group show -g $resourceGroup -n "$namePrefix-konnect-app" --query "properties.outputs.containerAppFqdn.value" -o tsv

Write-Info 'Validating the deployed Container App revision...'
& az containerapp show -g $resourceGroup -n $appName --query "properties.latestRevisionName" -o tsv | Out-Null
& curl.exe -fsS "https://$fqdn/status" | Out-Null

Write-Info "Konnect data plane deployment complete. Gateway URL: https://$fqdn"
Write-Info 'Next step: run scripts/konnect-sync-config.ps1 and then test/test-mcp-gateway.ps1'
