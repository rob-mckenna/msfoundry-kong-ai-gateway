#Requires -Version 7
<#
.SYNOPSIS
    Replaces the wildcard CORS origin on the mcp-key-service with explicit
    localhost origins so that MCP Inspector (running in a browser) can connect
    with credentials.

    WHY THE WILDCARD FAILS IN BROWSERS:
        credentials: true + Access-Control-Allow-Origin: * is rejected by every
        browser (CORS spec).  When Kong sees a pattern-matched origin it echoes
        the actual request Origin back instead of the wildcard, satisfying the
        browser's requirement that the Allow-Origin value be a specific origin.

    ORIGINS CONFIGURED:
        "http://localhost:6274"   — MCP Inspector default port
        "http://127.0.0.1:6274"  — IP-literal form (some tools use this)
        "http://localhost:*"      — Kong 3.x glob: matches any localhost port

    Kong matches the incoming Origin header against these patterns in order.
    On a match it responds with Access-Control-Allow-Origin: <exact-request-origin>
    and Access-Control-Allow-Credentials: true — browsers accept this.

.PARAMETER Pat
    Konnect PAT.  Defaults to $env:KONNECT_PAT.

.PARAMETER ControlPlaneId
    Konnect control-plane ID.  Defaults to the project control plane.

.PARAMETER Region
    Konnect geo-region (us/eu/au/in/me).  Defaults to $env:KONNECT_REGION or 'us'.

.PARAMETER GatewayUrl
    External gateway base URL for post-fix verification.

.EXAMPLE
    $env:KONNECT_PAT = '<token>'
    .\scripts\fix-cors-localhost.ps1

.EXAMPLE
    .\scripts\fix-cors-localhost.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Pat            = $env:KONNECT_PAT,
    [string]$ControlPlaneId = '1933cbf7-093d-4e84-a6d7-8e553c34c9a7',
    [string]$Region         = $(if ($env:KONNECT_REGION) { $env:KONNECT_REGION } else { 'us' }),
    [string]$GatewayUrl     = 'https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io'
)

$ErrorActionPreference = 'Stop'

function Write-Info([string]$m)  { Write-Host "[INFO]  $m" }
function Write-Ok([string]$m)    { Write-Host "[OK]    $m" -ForegroundColor Green }
function Write-Warn([string]$m)  { Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Fail([string]$m)        { throw "[ERROR] $m" }

if ([string]::IsNullOrWhiteSpace($Pat)) { Fail 'Provide -Pat or set $env:KONNECT_PAT.' }

$base    = "https://$Region.api.konghq.com"
$cpBase  = "/v2/control-planes/$ControlPlaneId/core-entities"
$headers = @{ Authorization = "Bearer $Pat"; 'Content-Type' = 'application/json' }

function Invoke-K([string]$Method, [string]$Path, [object]$Body) {
    $uri = "$base$Path"
    if ($null -ne $Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers `
            -Body ($Body | ConvertTo-Json -Depth 10 -Compress)
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

# ── Target config ─────────────────────────────────────────────────────────────
$KeyServiceId = 'dcb01bd5-b259-41ec-87a9-25c9b75bacc2'   # mcp-key-service

# Specific localhost origins instead of wildcard.
# Kong 3.x glob "http://localhost:*" matches any port and echoes back the exact
# request origin — browsers accept that with credentials:true.
$newOrigins = @(
    'http://localhost:6274',    # MCP Inspector default port
    'http://127.0.0.1:6274',   # IP-literal form
    'http://localhost:*'        # Kong 3.x glob — any other localhost port
)
$newMethods        = @('GET', 'POST', 'OPTIONS')
$newHeaders        = @('Content-Type', 'X-API-Key', 'Authorization')
$newExposedHeaders = @('X-Session-ID')
$newCredentials    = $true
$newMaxAge         = 3600

Write-Info "Control plane : $ControlPlaneId"
Write-Info "Service       : mcp-key-service ($KeyServiceId)"
Write-Info ""
Write-Info "New origins:"
foreach ($o in $newOrigins) { Write-Info "  - $o" }
Write-Info ""

# ── Fetch all plugins ─────────────────────────────────────────────────────────
Write-Info "Fetching plugins..."
$allPlugins = @()
$page = "$cpBase/plugins?size=1000"
do {
    $resp       = Invoke-K -Method GET -Path $page
    $allPlugins += $resp.data
    $page        = if ($resp.next) { $resp.next -replace "^https://[^/]+" } else { $null }
} while ($page)

# ── Locate the service-level CORS plugin ─────────────────────────────────────
$corsPlugin = $allPlugins |
    Where-Object { $_.name -eq 'cors' -and $_.service.id -eq $KeyServiceId -and -not $_.route } |
    Select-Object -First 1

if (-not $corsPlugin) {
    Fail "No service-level CORS plugin found on mcp-key-service ($KeyServiceId). Run fix-cors-key-routes.ps1 first to create it."
}

Write-Info "Found CORS plugin: $($corsPlugin.id)"
Write-Info "Current origins : $($corsPlugin.config.origins | ConvertTo-Json -Compress)"
Write-Info "Current credentials: $($corsPlugin.config.credentials)"
Write-Info ""

# ── Apply update (GET full object → modify → PUT) ─────────────────────────────
if ($PSCmdlet.ShouldProcess("CORS plugin $($corsPlugin.id) on mcp-key-service", 'PUT localhost origins')) {
    $full = Invoke-K -Method GET -Path "$cpBase/plugins/$($corsPlugin.id)"

    $full.config.origins         = $newOrigins
    $full.config.methods         = $newMethods
    $full.config.headers         = $newHeaders
    $full.config.exposed_headers = $newExposedHeaders
    $full.config.credentials     = $newCredentials
    $full.config.max_age         = $newMaxAge

    $putBody = @{
        name      = $full.name
        enabled   = $full.enabled
        config    = $full.config
        protocols = $full.protocols
    }
    if ($full.route)    { $putBody.route    = @{ id = $full.route.id }    }
    if ($full.service)  { $putBody.service  = @{ id = $full.service.id }  }
    if ($full.consumer) { $putBody.consumer = @{ id = $full.consumer.id } }
    if ($full.tags)     { $putBody.tags     = $full.tags }

    $result = Invoke-K -Method PUT -Path "$cpBase/plugins/$($corsPlugin.id)" -Body $putBody

    Write-Ok "CORS plugin updated: $($result.id)"
    Write-Ok "  origins         : $($result.config.origins | ConvertTo-Json -Compress)"
    Write-Ok "  methods         : $($result.config.methods | ConvertTo-Json -Compress)"
    Write-Ok "  headers         : $($result.config.headers | ConvertTo-Json -Compress)"
    Write-Ok "  exposed_headers : $($result.config.exposed_headers | ConvertTo-Json -Compress)"
    Write-Ok "  credentials     : $($result.config.credentials)"
    Write-Ok "  max_age         : $($result.config.max_age)"
}

# ── Live verification ─────────────────────────────────────────────────────────
Write-Info ""
Write-Info "Waiting 10s for Konnect dataplane push..."
Start-Sleep -Seconds 10

$testOrigin = 'http://localhost:6274'
$sseUrl     = "$GatewayUrl/mcp/key/sse"
$msgUrl     = "$GatewayUrl/mcp/key/messages"

function Test-Preflight([string]$Url, [string]$Method, [string]$Label) {
    Write-Info ""
    Write-Info "OPTIONS preflight — $Label"
    try {
        $r = Invoke-WebRequest -Method OPTIONS -Uri $Url `
            -Headers @{
                'Origin'                         = $testOrigin
                'Access-Control-Request-Method'  = $Method
                'Access-Control-Request-Headers' = 'X-API-Key,Content-Type'
            } -SkipHttpErrorCheck -TimeoutSec 15
        Write-Info "  Status : $($r.StatusCode)"
        $r.Headers.GetEnumerator() |
            Where-Object { $_.Key -match 'Access-Control|Vary' } |
            ForEach-Object { Write-Info "  $($_.Key): $($_.Value)" }

        $allowOrigin = $r.Headers['Access-Control-Allow-Origin']
        $allowCreds  = $r.Headers['Access-Control-Allow-Credentials']

        if ($allowOrigin -eq $testOrigin -and $allowCreds -eq 'true') {
            Write-Ok "  ✅ Preflight PASS — specific origin + credentials:true"
        } elseif ($allowOrigin -eq '*') {
            Write-Warn "  ⚠️  Allow-Origin is still wildcard — Konnect push may be pending. Retry in ~30s."
        } else {
            Write-Warn "  ⚠️  Unexpected Allow-Origin: $allowOrigin"
        }
    } catch {
        Write-Warn "  Request failed: $_"
    }
}

Test-Preflight -Url $sseUrl -Method 'GET'  -Label '/mcp/key/sse'
Test-Preflight -Url $msgUrl -Method 'POST' -Label '/mcp/key/messages'

Write-Info ""
Write-Ok "=== fix-cors-localhost complete ==="
Write-Info ""
Write-Info "If MCP Inspector still fails:"
Write-Info "  1. Wait ~30s for the dataplane to pick up the change and retry."
Write-Info "  2. Check the port MCP Inspector is using and add it explicitly:"
Write-Info "     e.g. http://localhost:5173  or  http://localhost:3000"
Write-Info "  3. To add more ports, re-run this script after editing \$newOrigins."
