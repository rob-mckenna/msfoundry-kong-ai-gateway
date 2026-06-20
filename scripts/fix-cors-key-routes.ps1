#Requires -Version 7
<#
.SYNOPSIS
    Updates CORS configuration on the key-auth MCP routes so that browser-based
    tools like MCP Inspector (running at localhost) can connect successfully.

    Current problem:
        The service-level CORS plugin on mcp-key-service was provisioned with
        credentials=false and missing the Authorization header and X-Session-ID
        exposed header.  MCP Inspector running in a browser sends an
        OPTIONS preflight with "Origin: http://localhost:*" and requires
        Access-Control-Allow-Credentials: true to pass credentials (X-API-Key).

    What this script does:
        1. Finds the CORS plugin on the mcp-key-service (covers both routes).
        2. Updates it with browser-compatible settings.
        3. Verifies the changes were applied.
        4. Tests OPTIONS preflight and GET against the live gateway.

    Target config:
        origins         : ["*"]
        methods         : ["GET", "POST", "OPTIONS"]
        headers         : ["Content-Type", "X-API-Key", "Authorization"]
        exposed_headers : ["X-Session-ID"]
        credentials     : true
        max_age         : 3600

    NOTE on credentials + wildcard origin:
        Browsers reject Access-Control-Allow-Origin: * when
        Access-Control-Allow-Credentials: true (CORS spec restriction).
        For production, replace origins: ["*"] with explicit origins
        (e.g. ["http://localhost:6274", "http://localhost:5173"]).
        For this POC the wildcard is fine for non-browser clients and
        curl-based testing; MCP Inspector may need explicit origins for
        the preflight flow if it sends credentials.

.PARAMETER Pat
    Konnect PAT.  Defaults to $env:KONNECT_PAT.

.PARAMETER ControlPlaneId
    Konnect control-plane ID.  Defaults to the project control plane.

.PARAMETER Region
    Konnect geo-region (us/eu/au/in/me).  Defaults to $env:KONNECT_REGION or 'us'.

.PARAMETER GatewayUrl
    External gateway base URL for post-fix verification.
    Defaults to the known ACA external ingress.

.EXAMPLE
    $env:KONNECT_PAT = '<token>'
    .\scripts\fix-cors-key-routes.ps1

.EXAMPLE
    .\scripts\fix-cors-key-routes.ps1 -WhatIf
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

# ── Known entity IDs (from provisioning on 2026-06-19) ───────────────────────
$KeyServiceId       = 'dcb01bd5-b259-41ec-87a9-25c9b75bacc2'   # mcp-key-service
$KeySseRouteId      = '13ef058a-ae46-4b12-84ec-47b3dfe7ad0f'   # mcp-key-sse
$KeyMessagesRouteId = 'c0b1f5e1-7cef-4e57-aa6f-cd81139ef7d0'   # mcp-key-messages

# ── Target CORS config (browser-compatible for MCP Inspector) ─────────────────
$correctOrigins        = @('*')
$correctMethods        = @('GET', 'POST', 'OPTIONS')
$correctHeaders        = @('Content-Type', 'X-API-Key', 'Authorization')
$correctExposedHeaders = @('X-Session-ID')
$correctCredentials    = $true
$correctMaxAge         = 3600

Write-Info "Control plane  : $ControlPlaneId"
Write-Info "Service        : mcp-key-service ($KeyServiceId)"
Write-Info "Routes         : mcp-key-sse, mcp-key-messages"
Write-Info ""
Write-Info "Target CORS config:"
Write-Info "  origins         : $($correctOrigins | ConvertTo-Json -Compress)"
Write-Info "  methods         : $($correctMethods | ConvertTo-Json -Compress)"
Write-Info "  headers         : $($correctHeaders | ConvertTo-Json -Compress)"
Write-Info "  exposed_headers : $($correctExposedHeaders | ConvertTo-Json -Compress)"
Write-Info "  credentials     : $correctCredentials"
Write-Info "  max_age         : $correctMaxAge"
Write-Info ""

# ── Step 1: Fetch all plugins ─────────────────────────────────────────────────
Write-Info "Step 1 — Fetching plugins from control plane..."
$allPlugins = @()
$page       = "$cpBase/plugins?size=1000"
do {
    $resp       = Invoke-K -Method GET -Path $page
    $allPlugins += $resp.data
    $page        = if ($resp.next) { $resp.next -replace "^https://[^/]+" } else { $null }
} while ($page)

Write-Info "  Total plugins fetched: $($allPlugins.Count)"

# ── Step 2: Locate existing CORS plugins ─────────────────────────────────────
Write-Info ""
Write-Info "Step 2 — Locating existing CORS plugins..."

$corsOnService  = $allPlugins | Where-Object { $_.name -eq 'cors' -and $_.service.id -eq $KeyServiceId -and -not $_.route } | Select-Object -First 1
$corsOnSse      = $allPlugins | Where-Object { $_.name -eq 'cors' -and $_.route.id  -eq $KeySseRouteId      } | Select-Object -First 1
$corsOnMessages = $allPlugins | Where-Object { $_.name -eq 'cors' -and $_.route.id  -eq $KeyMessagesRouteId } | Select-Object -First 1

if ($corsOnService)  { Write-Info "  Found CORS on service (mcp-key-service)   : $($corsOnService.id)" }
else                 { Write-Info "  No CORS plugin on service level" }
if ($corsOnSse)      { Write-Info "  Found CORS on route  (mcp-key-sse)        : $($corsOnSse.id)" }
else                 { Write-Info "  No CORS plugin on mcp-key-sse route" }
if ($corsOnMessages) { Write-Info "  Found CORS on route  (mcp-key-messages)   : $($corsOnMessages.id)" }
else                 { Write-Info "  No CORS plugin on mcp-key-messages route" }

# ── Step 3: Build patcher helper ──────────────────────────────────────────────
function Update-CorsPlugin([string]$PluginId, [string]$Label) {
    Write-Info ""
    Write-Info "  Fetching full plugin object for $Label ($PluginId)..."
    $full = Invoke-K -Method GET -Path "$cpBase/plugins/$PluginId"

    Write-Info "  Current config:"
    Write-Info "    origins         : $($full.config.origins | ConvertTo-Json -Compress)"
    Write-Info "    methods         : $($full.config.methods | ConvertTo-Json -Compress)"
    Write-Info "    headers         : $($full.config.headers | ConvertTo-Json -Compress)"
    Write-Info "    exposed_headers : $($full.config.exposed_headers | ConvertTo-Json -Compress)"
    Write-Info "    credentials     : $($full.config.credentials)"
    Write-Info "    max_age         : $($full.config.max_age)"

    if ($PSCmdlet.ShouldProcess("CORS plugin $PluginId on $Label", 'PUT updated config')) {
        $full.config.origins         = $correctOrigins
        $full.config.methods         = $correctMethods
        $full.config.headers         = $correctHeaders
        $full.config.exposed_headers = $correctExposedHeaders
        $full.config.credentials     = $correctCredentials
        $full.config.max_age         = $correctMaxAge

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

        $result = Invoke-K -Method PUT -Path "$cpBase/plugins/$PluginId" -Body $putBody
        Write-Ok "  Updated $Label CORS plugin $($result.id)"
        Write-Ok "    origins         : $($result.config.origins | ConvertTo-Json -Compress)"
        Write-Ok "    methods         : $($result.config.methods | ConvertTo-Json -Compress)"
        Write-Ok "    headers         : $($result.config.headers | ConvertTo-Json -Compress)"
        Write-Ok "    exposed_headers : $($result.config.exposed_headers | ConvertTo-Json -Compress)"
        Write-Ok "    credentials     : $($result.config.credentials)"
        Write-Ok "    max_age         : $($result.config.max_age)"
        return $result
    }
}

function New-CorsPlugin([string]$ScopeParam, [object]$ScopeValue, [string]$Label) {
    Write-Info ""
    Write-Info "  Creating CORS plugin on $Label..."

    $body = @{
        name    = 'cors'
        enabled = $true
        config  = @{
            origins         = $correctOrigins
            methods         = $correctMethods
            headers         = $correctHeaders
            exposed_headers = $correctExposedHeaders
            credentials     = $correctCredentials
            max_age         = $correctMaxAge
        }
    }
    $body[$ScopeParam] = $ScopeValue

    if ($PSCmdlet.ShouldProcess($Label, 'POST new CORS plugin')) {
        $result = Invoke-K -Method POST -Path "$cpBase/plugins" -Body $body
        Write-Ok "  Created $Label CORS plugin $($result.id)"
        return $result
    }
}

# ── Step 4: Apply updates ─────────────────────────────────────────────────────
Write-Info ""
Write-Info "Step 4 — Applying CORS updates..."

# Update service-level CORS if present (covers both routes by inheritance)
if ($corsOnService) {
    Update-CorsPlugin -PluginId $corsOnService.id -Label 'mcp-key-service (service-level)'
} else {
    Write-Warn "No service-level CORS found — creating one on mcp-key-service..."
    New-CorsPlugin -ScopeParam 'service' -ScopeValue @{ id = $KeyServiceId } -Label 'mcp-key-service'
}

# Ensure route-level CORS on mcp-key-sse (overrides service if present, ensures explicit coverage)
if ($corsOnSse) {
    Update-CorsPlugin -PluginId $corsOnSse.id -Label 'mcp-key-sse (route-level)'
} else {
    Write-Info ""
    Write-Info "  No route-level CORS on mcp-key-sse — service-level plugin covers it."
    Write-Info "  (Skipping route-level plugin creation to avoid config duplication.)"
}

# Ensure route-level CORS on mcp-key-messages
if ($corsOnMessages) {
    Update-CorsPlugin -PluginId $corsOnMessages.id -Label 'mcp-key-messages (route-level)'
} else {
    Write-Info ""
    Write-Info "  No route-level CORS on mcp-key-messages — service-level plugin covers it."
    Write-Info "  (Skipping route-level plugin creation to avoid config duplication.)"
}

# ── Step 5: Live verification ─────────────────────────────────────────────────
Write-Info ""
Write-Info "Step 5 — Live verification (allow ~10s for Konnect dataplane push)..."
Start-Sleep -Seconds 10

$sseUrl  = "$GatewayUrl/mcp/key/sse"
$msgUrl  = "$GatewayUrl/mcp/key/messages"

Write-Info ""
Write-Info "5a — OPTIONS preflight on mcp-key-sse:"
try {
    $preflightResp = Invoke-WebRequest -Method OPTIONS -Uri $sseUrl `
        -Headers @{
            'Origin'                         = 'http://localhost:6274'
            'Access-Control-Request-Method'  = 'GET'
            'Access-Control-Request-Headers' = 'X-API-Key'
        } -SkipHttpErrorCheck
    Write-Info "  Status : $($preflightResp.StatusCode)"
    $corsHeaders = $preflightResp.Headers.Keys | Where-Object { $_ -match '^Access-Control' }
    foreach ($h in $corsHeaders) { Write-Info "  $h : $($preflightResp.Headers[$h])" }
    if ($preflightResp.StatusCode -in 200, 204) { Write-Ok "  OPTIONS preflight: PASS" }
    else { Write-Warn "  OPTIONS preflight returned $($preflightResp.StatusCode) — check key-auth on OPTIONS method" }
} catch {
    Write-Warn "  OPTIONS preflight request failed: $_"
}

Write-Info ""
Write-Info "5b — GET mcp-key-sse (no key — expecting 401 with CORS headers):"
try {
    $getResp = Invoke-WebRequest -Method GET -Uri $sseUrl `
        -Headers @{ 'Origin' = 'http://localhost:6274' } -SkipHttpErrorCheck
    Write-Info "  Status : $($getResp.StatusCode)"
    $corsHeaders2 = $getResp.Headers.Keys | Where-Object { $_ -match '^Access-Control' }
    foreach ($h in $corsHeaders2) { Write-Info "  $h : $($getResp.Headers[$h])" }
    if ($corsHeaders2.Count -gt 0) { Write-Ok "  CORS headers present on GET: PASS" }
    else { Write-Warn "  No CORS headers on GET response — CORS plugin may not be active yet" }
} catch {
    Write-Warn "  GET request failed: $_"
}

Write-Info ""
Write-Info "5c — OPTIONS preflight on mcp-key-messages:"
try {
    $msgPreflight = Invoke-WebRequest -Method OPTIONS -Uri $msgUrl `
        -Headers @{
            'Origin'                         = 'http://localhost:6274'
            'Access-Control-Request-Method'  = 'POST'
            'Access-Control-Request-Headers' = 'X-API-Key, Content-Type'
        } -SkipHttpErrorCheck
    Write-Info "  Status : $($msgPreflight.StatusCode)"
    $corsHeadersMsg = $msgPreflight.Headers.Keys | Where-Object { $_ -match '^Access-Control' }
    foreach ($h in $corsHeadersMsg) { Write-Info "  $h : $($msgPreflight.Headers[$h])" }
    if ($msgPreflight.StatusCode -in 200, 204) { Write-Ok "  OPTIONS preflight (messages): PASS" }
    else { Write-Warn "  OPTIONS preflight (messages) returned $($msgPreflight.StatusCode)" }
} catch {
    Write-Warn "  OPTIONS (messages) request failed: $_"
}

Write-Info ""
Write-Ok "=== CORS update complete ==="
Write-Info ""
Write-Info "If MCP Inspector still shows 'Failed to fetch':"
Write-Info "  1. Browsers block credentials:true + origin:* — use explicit origin if needed."
Write-Info "  2. Add 'http://localhost:6274' (or your MCP Inspector port) to origins list."
Write-Info "  3. Run this script with -WhatIf to preview without changes."
Write-Info ""
Write-Info "To add explicit localhost origins instead of wildcard, set:"
Write-Info "  origins = ['http://localhost:6274', 'http://localhost:5173', 'http://localhost:3000']"
