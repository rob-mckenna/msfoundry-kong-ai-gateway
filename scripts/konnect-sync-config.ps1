[CmdletBinding()]
param(
    [string]$Pat = $env:KONNECT_PAT,
    [Parameter(Mandatory = $true)]
    [string]$ControlPlaneId,
    [string]$ConfigFile = 'kong.yaml',
    [string]$Region = $(if ($env:KONNECT_REGION) { $env:KONNECT_REGION } else { 'us' }),
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

function Invoke-KonnectApi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $headers = @{ Authorization = "Bearer $Pat" }
    Invoke-RestMethod -Method $Method -Uri "$script:KonnectApiBase$Path" -Headers $headers
}

if ([string]::IsNullOrWhiteSpace($Pat)) {
    Fail 'Provide -Pat or set KONNECT_PAT.'
}

Require-Command 'curl'
Require-Command 'kongctl'

$configPath = if ([System.IO.Path]::IsPathRooted($ConfigFile)) { $ConfigFile } else { Join-Path $root $ConfigFile }
if (-not (Test-Path $configPath)) {
    Fail "Config file not found: $ConfigFile"
}

$script:KonnectApiBase = Get-KonnectApiBase $Region
$env:KONGCTL_DEFAULT_KONNECT_PAT = $Pat

Write-Info 'Validating Kong Konnect authentication...'
if (-not $DryRun) {
    & kongctl get me | Out-Null
}

$controlPlane = Invoke-KonnectApi -Method GET -Path "/v2/control-planes/$ControlPlaneId"
if (-not $controlPlane.name) {
    Fail "Unable to resolve control plane name from ID $ControlPlaneId"
}

$manifestPath = Join-Path $generatedDir "kongctl-sync-$ControlPlaneId.yaml"
@"
control_planes:
  - ref: target-control-plane
    name: "$($controlPlane.name)"
    _deck:
      files:
        - "$configPath"
      flags:
        - "--konnect-addr=$script:KonnectApiBase"
        - "--konnect-control-plane-name=$($controlPlane.name)"
"@ | Set-Content -Path $manifestPath

Write-Info "Generated kongctl sync manifest at $manifestPath"
if ($DryRun) {
    Write-Info 'Running kongctl plan only...'
    & kongctl plan -f $manifestPath
    return
}

Write-Info 'Syncing gateway configuration into Konnect via kongctl...'
& kongctl sync -f $manifestPath

Write-Info 'Validating core entities exist in the control plane...'
[void](Invoke-KonnectApi -Method GET -Path "/v2/control-planes/$ControlPlaneId/core-entities/services")
[void](Invoke-KonnectApi -Method GET -Path "/v2/control-planes/$ControlPlaneId/core-entities/routes")
[void](Invoke-KonnectApi -Method GET -Path "/v2/control-planes/$ControlPlaneId/core-entities/consumers")

if ($env:GATEWAY_BASE_URL) {
    Write-Info "Running the existing JWT regression suite against $($env:GATEWAY_BASE_URL)"
    & bash (Join-Path $root 'test\test-mcp-gateway.sh')
} else {
    Write-Info 'Skipping live JWT route validation because GATEWAY_BASE_URL is not set.'
}

Write-Info "Konnect config sync complete for control plane '$($controlPlane.name)'."
