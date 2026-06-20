#Requires -Version 7
<#
.SYNOPSIS
    Fixes the MCP OAuth SSE endpoint advertisement so Foundry uses the OAuth-
    authenticated message route instead of the JWT-protected one.

    ROOT CAUSE:
    The MCP server's SSE bootstrap sends:
        event: endpoint
        data: /mcp/messages?sessionId=<id>

    Foundry follows that URL and hits the JWT-protected /mcp/messages route
    with an Entra bearer token → Kong JWT plugin rejects it with
    "No credentials found for given 'iss'".

    The pre-function on mcp-oauth-sse already sets:
        x-external-mcp-messages-path: /mcp/oauth/messages
    but the MCP server does not yet honor that header.

    FIX:
    Adds a post-function plugin (body_filter phase) to the mcp-oauth-sse route
    that rewrites the endpoint event data in-stream:
        /mcp/messages?  →  /mcp/oauth/messages?

    This is transparent to both the MCP server and Foundry.  No server code
    changes required.

    Also adds POST to the mcp-oauth-sse route's accepted methods to handle
    Foundry's streamable-HTTP transport probe (currently getting 404).

.PARAMETER Pat
    Konnect PAT.  Defaults to $env:KONNECT_PAT.

.PARAMETER ControlPlaneId
    Konnect control-plane ID.  Defaults to the project control plane.

.PARAMETER Region
    Konnect geo-region (us/eu/au/in/me).  Defaults to $env:KONNECT_REGION or 'us'.

.EXAMPLE
    $env:KONNECT_PAT = '<token>'
    .\scripts\fix-mcp-oauth-endpoint.ps1

.EXAMPLE
    .\scripts\fix-mcp-oauth-endpoint.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Pat            = $env:KONNECT_PAT,
    [string]$ControlPlaneId = '1933cbf7-093d-4e84-a6d7-8e553c34c9a7',
    [string]$Region         = $(if ($env:KONNECT_REGION) { $env:KONNECT_REGION } else { 'us' })
)

$ErrorActionPreference = 'Stop'

function Write-Info([string]$m)  { Write-Host "[INFO]  $m" }
function Write-Ok([string]$m)    { Write-Host "[OK]    $m" -ForegroundColor Green }
function Write-Warn([string]$m)  { Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Fail([string]$m)        { throw "[ERROR] $m" }

if ([string]::IsNullOrWhiteSpace($Pat)) { Fail 'Provide -Pat or set KONNECT_PAT.' }

$base    = "https://$Region.api.konghq.com"
$headers = @{ Authorization = "Bearer $Pat"; 'Content-Type' = 'application/json' }

function Invoke-K([string]$Method, [string]$Path, [object]$Body) {
    $uri = "$base$Path"
    if ($null -ne $Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers `
            -Body ($Body | ConvertTo-Json -Depth 10 -Compress)
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

# ── Lua: body_filter that rewrites the MCP endpoint event in the SSE stream ───
# Called for every response body chunk from the MCP server.
# Replaces "data: /mcp/messages?" with "data: /mcp/oauth/messages?" so
# Foundry posts to the OAuth-protected route, not the JWT-protected one.
$bodyFilterLua = @'
local chunk = ngx.arg[1]
if chunk and #chunk > 0 then
    local rewritten, n = chunk:gsub(
        "data: /mcp/messages%?",
        "data: /mcp/oauth/messages?"
    )
    if n and n > 0 then
        kong.log.notice("[mcp-oauth-rewrite] rewrote endpoint event: /mcp/messages -> /mcp/oauth/messages")
        ngx.arg[1] = rewritten
    end
end
'@

$cpBase  = "/v2/control-planes/$ControlPlaneId/core-entities"

# ── Find the mcp-oauth-sse route ──────────────────────────────────────────────
Write-Info "Fetching routes..."
$routesResp = Invoke-K -Method GET -Path "$cpBase/routes?size=1000"
$sseRoute   = $routesResp.data | Where-Object { $_.name -eq 'mcp-oauth-sse' } | Select-Object -First 1
if (-not $sseRoute) { Fail "Route 'mcp-oauth-sse' not found in control plane $ControlPlaneId." }
Write-Info "Found mcp-oauth-sse → $($sseRoute.id)"
Write-Info "  Current methods : $($sseRoute.methods | ConvertTo-Json -Compress)"

# ── Fetch all plugins ─────────────────────────────────────────────────────────
Write-Info "Fetching plugins..."
$pluginsResp = Invoke-K -Method GET -Path "$cpBase/plugins?size=1000"
$allPlugins  = $pluginsResp.data

# ── 1. Add/update body_filter post-function on mcp-oauth-sse ─────────────────
Write-Info ""
Write-Info "Step 1 — SSE endpoint event rewrite (body_filter post-function)"

# Look for an existing post-function on this route
$existingPf = $allPlugins | Where-Object {
    $_.name -eq 'post-function' -and $_.route.id -eq $sseRoute.id
} | Select-Object -First 1

if ($existingPf) {
    Write-Info "  Existing post-function found: $($existingPf.id)"
    Write-Info "  Updating body_filter phase..."

    if ($PSCmdlet.ShouldProcess("post-function $($existingPf.id)", "PUT body_filter rewrite")) {
        $full = Invoke-K -Method GET -Path "$cpBase/plugins/$($existingPf.id)"
        # Ensure body_filter array exists and contains our rewrite code
        if (-not $full.config.body_filter) {
            $full.config | Add-Member -NotePropertyName 'body_filter' -NotePropertyValue @($bodyFilterLua) -Force
        } else {
            $full.config.body_filter = @($bodyFilterLua)
        }
        $putBody = @{
            name      = $full.name
            enabled   = $full.enabled
            config    = $full.config
            protocols = $full.protocols
        }
        if ($full.route)    { $putBody.route    = @{ id = $full.route.id }    }
        if ($full.service)  { $putBody.service  = @{ id = $full.service.id }  }
        if ($full.tags)     { $putBody.tags     = $full.tags }

        $result = Invoke-K -Method PUT -Path "$cpBase/plugins/$($existingPf.id)" -Body $putBody
        Write-Ok "  Updated post-function $($result.id) with body_filter rewrite."
    }
} else {
    Write-Info "  No existing post-function — creating new one..."

    if ($PSCmdlet.ShouldProcess("mcp-oauth-sse route $($sseRoute.id)", "POST new post-function with body_filter rewrite")) {
        $result = Invoke-K -Method POST -Path "$cpBase/plugins" -Body @{
            name    = 'post-function'
            route   = @{ id = $sseRoute.id }
            enabled = $true
            config  = @{
                body_filter = @($bodyFilterLua)
            }
        }
        Write-Ok "  Created post-function $($result.id) with body_filter rewrite."
    }
}

# ── 2. Add POST to mcp-oauth-sse route methods ────────────────────────────────
Write-Info ""
Write-Info "Step 2 — Add POST to mcp-oauth-sse route methods"

$currentMethods = @($sseRoute.methods)
if ($currentMethods -contains 'POST') {
    Write-Ok "  Route already accepts POST — no change needed."
} else {
    $newMethods = @('GET', 'POST', 'OPTIONS')
    Write-Info "  Adding POST: $($currentMethods | ConvertTo-Json -Compress) → $($newMethods | ConvertTo-Json -Compress)"

    if ($PSCmdlet.ShouldProcess("mcp-oauth-sse route $($sseRoute.id)", "PUT methods to add POST")) {
        # GET full route to preserve all fields
        $fullRoute = Invoke-K -Method GET -Path "$cpBase/routes/$($sseRoute.id)"
        $fullRoute.methods = $newMethods

        $routePutBody = @{
            name          = $fullRoute.name
            paths         = $fullRoute.paths
            methods       = $fullRoute.methods
            strip_path    = $fullRoute.strip_path
            preserve_host = $fullRoute.preserve_host
            protocols     = $fullRoute.protocols
        }
        if ($fullRoute.service) { $routePutBody.service = @{ id = $fullRoute.service.id } }
        if ($fullRoute.tags)    { $routePutBody.tags    = $fullRoute.tags }

        $resultRoute = Invoke-K -Method PUT -Path "$cpBase/routes/$($sseRoute.id)" -Body $routePutBody
        Write-Ok "  Route methods updated: $($resultRoute.methods | ConvertTo-Json -Compress)"
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Info ""
Write-Ok "Done."
Write-Info ""
Write-Info "What changed:"
Write-Info "  1. post-function (body_filter) rewrites SSE endpoint event:"
Write-Info "       'data: /mcp/messages?'  →  'data: /mcp/oauth/messages?'"
Write-Info "     Foundry now posts to the OAuth-authenticated route."
Write-Info "  2. mcp-oauth-sse route now accepts POST (handles Foundry's"
Write-Info "     streamable-HTTP probe; 404 → handled by route)."
Write-Info ""
Write-Info "Expected flow after this fix:"
Write-Info "  GET  /mcp/oauth/sse          → 200  (OIDC auth)  ← already working"
Write-Info "  SSE endpoint event            → /mcp/oauth/messages?sessionId=XXX"
Write-Info "  POST /mcp/oauth/messages?... → 200  (OIDC auth on messages route)"
