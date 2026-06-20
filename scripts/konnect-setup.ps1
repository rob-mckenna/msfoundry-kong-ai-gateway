[CmdletBinding()]
param(
    [string]$Pat = $env:KONNECT_PAT,
    [string]$ControlPlaneName = 'kong-aca-poc',
    [string]$Region = 'us',
    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$generatedDir = Join-Path $root 'scripts\.generated\konnect'
New-Item -ItemType Directory -Force -Path $generatedDir | Out-Null

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" }
function Fail([string]$Message) { throw "[ERROR] $Message" }

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Fail "Required command not found: $Name"
    }
}

function Get-KonnectApiBase([string]$Geo) {
    switch ($Geo) {
        'us' { 'https://us.api.konghq.com' }
        'eu' { 'https://eu.api.konghq.com' }
        'au' { 'https://au.api.konghq.com' }
        'in' { 'https://in.api.konghq.com' }
        'me' { 'https://me.api.konghq.com' }
        default { Fail "Unsupported region '$Geo'." }
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

function Invoke-KonnectApi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [object]$Body
    )

    $uri = "$script:KonnectApiBase$Path"
    $headers = @{ Authorization = "Bearer $Pat" }

    if ($null -ne $Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 10)
    }

    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

if ([string]::IsNullOrWhiteSpace($Pat)) {
    Fail 'Provide -Pat or set KONNECT_PAT.'
}

Require-Command 'az'
Require-Command 'curl'
Require-Command 'openssl'
Require-Command 'kongctl'

$script:KonnectApiBase = Get-KonnectApiBase $Region
$env:KONGCTL_DEFAULT_KONNECT_PAT = $Pat

Write-Info 'Validating Kong Konnect authentication...'
Invoke-Step -Description 'kongctl get me' -Action { & kongctl get me | Out-Null }

Write-Info 'Validating Azure CLI authentication...'
Invoke-Step -Description 'az account show --output none' -Action { & az account show --output none | Out-Null }

$controlPlane = $null
if (-not $DryRun) {
    Write-Info "Looking for existing control plane '$ControlPlaneName'..."
    $controlPlanes = Invoke-KonnectApi -Method GET -Path '/v2/control-planes'
    $controlPlane = @($controlPlanes.data | Where-Object { $_.name -eq $ControlPlaneName })[0]

    if (-not $controlPlane) {
        $confirmation = Read-Host "Create control plane '$ControlPlaneName' in Konnect geo '$Region'? [y/N]"
        if ($confirmation -notmatch '^[Yy]$') {
            Fail 'Cancelled.'
        }

        $controlPlane = Invoke-KonnectApi -Method POST -Path '/v2/control-planes' -Body @{
            name = $ControlPlaneName
            description = 'ACA Konnect control plane for the Kong AI Gateway POC'
            cluster_type = 'CLUSTER_TYPE_CONTROL_PLANE'
            auth_type = 'pki_client_certs'
        }
    }
}

$controlPlaneId = if ($DryRun) { '<dry-run-control-plane-id>' } else { $controlPlane.id }
$certFile = Join-Path $generatedDir "$ControlPlaneName-cluster-cert.pem"
$keyFile = Join-Path $generatedDir "$ControlPlaneName-cluster-key.pem"
$detailsFile = Join-Path $generatedDir "$ControlPlaneName-connection-details.json"

Write-Info 'Generating a Konnect data plane client certificate...'
if (-not $DryRun) {
    Remove-Item $certFile, $keyFile -ErrorAction SilentlyContinue
}
Invoke-Step -Description "openssl req -x509 -nodes -newkey rsa:2048 -keyout $keyFile -out $certFile" -Action {
    & openssl req -x509 -nodes -newkey rsa:2048 `
        -keyout $keyFile `
        -out $certFile `
        -days 365 `
        -subj "/CN=$ControlPlaneName/O=KongAIGatewayPOC"
}

if (-not $DryRun) {
    Write-Info 'Registering the public certificate with Konnect...'
    $certBody = @{
        cert = Get-Content $certFile -Raw
    }

    $paths = @(
        "/v2/control-planes/$controlPlaneId/dp-client-certificates",
        "/v2/control-planes/$controlPlaneId/dp-certificates",
        "/v2/control-planes/$controlPlaneId/data-plane-certificates"
    )

    $registered = $false
    foreach ($path in $paths) {
        try {
            Invoke-KonnectApi -Method POST -Path $path -Body $certBody | Out-Null
            Write-Info "Registered data plane certificate via $path"
            $registered = $true
            break
        } catch {
            continue
        }
    }

    if (-not $registered) {
        Fail 'Unable to register the data plane certificate. Check the Konnect API version in your org.'
    }
}

$controlPlaneEndpoint = "$controlPlaneId.$Region.cp0.konghq.com:443"
$telemetryEndpoint = "$controlPlaneId.$Region.tp0.konghq.com:443"

Write-Info "Uploading client certificate and key to Key Vault '$KeyVaultName'..."
Invoke-Step -Description "az keyvault secret set --vault-name $KeyVaultName --name kong-cluster-cert --file $certFile" -Action {
    & az keyvault secret set --vault-name $KeyVaultName --name kong-cluster-cert --file $certFile --output none | Out-Null
}
Invoke-Step -Description "az keyvault secret set --vault-name $KeyVaultName --name kong-cluster-key --file $keyFile" -Action {
    & az keyvault secret set --vault-name $KeyVaultName --name kong-cluster-key --file $keyFile --output none | Out-Null
}

@{
    controlPlaneId = $controlPlaneId
    controlPlaneName = $ControlPlaneName
    region = $Region
    controlPlaneEndpoint = $controlPlaneEndpoint
    telemetryEndpoint = $telemetryEndpoint
    keyVaultName = $KeyVaultName
    certificateSecretName = 'kong-cluster-cert'
    certificateKeySecretName = 'kong-cluster-key'
} | ConvertTo-Json -Depth 5 | Set-Content -Path $detailsFile

if (-not $DryRun) {
    Write-Info 'Validating Key Vault secret references...'
    & az keyvault secret show --vault-name $KeyVaultName --name kong-cluster-cert --query id -o tsv | Out-Null
    & az keyvault secret show --vault-name $KeyVaultName --name kong-cluster-key --query id -o tsv | Out-Null
    Remove-Item $certFile, $keyFile -ErrorAction SilentlyContinue
}

Write-Info "Konnect setup complete. Connection details: $detailsFile"
Write-Info "Control plane endpoint: $controlPlaneEndpoint"
Write-Info "Telemetry endpoint: $telemetryEndpoint"
