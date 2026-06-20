#Requires -Version 7
<#
.SYNOPSIS
    Adds x-custom-auth-headers to the CORS allowed headers on mcp-key-service.
    Fixes MCP Inspector v0.22.0 "Request header field x-custom-auth-headers is
    not allowed by Access-Control-Allow-Headers in preflight response".

.PARAMETER Pat
    Konnect PAT.  Defaults to $env:KONNECT_PAT.

.PARAMETER ControlPlaneId
    Defaults to the project control plane.

.PARAMETER Region
    Konnect geo-region.  Defaults to $env:KONNECT_REGION or 'us'.

.PARAMETER GatewayUrl
    External gateway base URL for post-fix verification.

.EXAMPLE
    $env:KONNECT_PAT = '<token>'
    .\scripts\fix-cors-add-inspector-header.ps1
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

$KeyServiceId = 'dcb01bd5-b259-41ec-87a9-25c9b75bacc2'   # mcp-key-service
$targetHeader = 'x-custom-auth-headers'

# ── Locate the service-level CORS plugin ──────────────────────────────────────
Write-Info "Fetching plugins..."
$allPlugins = @()
$page = "$cpBase/plugins?size=1000"
do {
    $resp       = Invoke-K -Method GET -Path $page
    $allPlugins += $resp.data
    $page        = if ($resp.next) { $resp.next -replace "^https://[^/]+" } else { $null }
} while ($page)

$corsPlugin = $allPlugins |
    Where-Object { $_.name -eq 'cors' -and $_.service.id -eq $KeyServiceId -and -not $_.route } |
    Select-Object -First 1

if (-not $corsPlugin) { Fail "No service-level CORS plugin on mcp-key-service. Run fix-cors-key-routes.ps1 first." }

Write-Info "CORS plugin     : $($corsPlugin.id)"
Write-Info "Current headers : $($corsPlugin.config.headers | ConvertTo-Json -Compress)"

if ($corsPlugin.config.headers -contains $targetHeader) {
    Write-Ok "'$targetHeader' already present — nothing to do."
    exit 0
}

# ── GET full object → add header → PUT ────────────────────────────────────────
if ($PSCmdlet.ShouldProcess("CORS plugin $($corsPlugin.id)", "add '$targetHeader' to headers")) {
    $full = Invoke-K -Method GET -Path "$cpBase/plugins/$($corsPlugin.id)"

    $full.config.headers = @($full.config.headers) + $targetHeader

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

    Write-Ok "Updated headers : $($result.config.headers | ConvertTo-Json -Compress)"
}

# ── Verify preflight ──────────────────────────────────────────────────────────
Write-Info ""
Write-Info "Waiting 10s for dataplane push..."
Start-Sleep -Seconds 10

Write-Info "OPTIONS preflight /mcp/key/sse (simulating MCP Inspector v0.22.0)..."
try {
    $r = Invoke-WebRequest -Method OPTIONS `
        -Uri "$GatewayUrl/mcp/key/sse" `
        -Headers @{
            'Origin'                         = 'http://localhost:6274'
            'Access-Control-Request-Method'  = 'GET'
            'Access-Control-Request-Headers' = "X-API-Key,$targetHeader"
        } -SkipHttpErrorCheck -TimeoutSec 15

    Write-Info "  Status : $($r.StatusCode)"
    $r.Headers.GetEnumerator() |
        Where-Object { $_.Key -match 'Access-Control' } |
        ForEach-Object { Write-Info "  $($_.Key): $($_.Value)" }

    $allowedHeaders = $r.Headers['Access-Control-Allow-Headers']
    if ($allowedHeaders -match [regex]::Escape($targetHeader)) {
        Write-Ok "  ✅ '$targetHeader' is in Allow-Headers — MCP Inspector preflight will pass"
    } else {
        Write-Warn "  ⚠️  '$targetHeader' not yet visible in Allow-Headers — dataplane may still be pushing. Retry in ~30s."
    }
} catch {
    Write-Warn "  Preflight request failed: $_"
}
