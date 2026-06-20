#Requires -Version 7
<#
.SYNOPSIS
    Comprehensive one-shot fix for the openid-connect plugin config on both
    OAuth MCP routes.  Sets all three validation fields that have been causing
    cascading 401/403 errors:

      1. issuer          — Entra v2.0 endpoint; required for JWKS discovery.
      2. audience_required — Both formats Entra can issue (api:// and bare GUID).
      3. scopes_required — Cleared (no scope enforcement); Foundry access tokens
                           do not include the scopes Kong was checking.

    Error sequence this fixes:
        "No credentials found for given 'iss'"    ← issuer mismatch / missing
        "required audience were not found [...]"  ← audience_required bare-GUID-only
        "scopes required but no scopes found"     ← leftover scopes_required value

.PARAMETER Pat
    Konnect PAT.  Defaults to $env:KONNECT_PAT.

.PARAMETER ControlPlaneId
    Konnect control-plane ID.  Defaults to the project control plane.

.PARAMETER Region
    Konnect geo-region (us/eu/au/in/me).  Defaults to $env:KONNECT_REGION or 'us'.

.EXAMPLE
    $env:KONNECT_PAT = '<token>'
    .\scripts\fix-oidc-full.ps1

.EXAMPLE
    .\scripts\fix-oidc-full.ps1 -WhatIf
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

# ── Canonical correct values ──────────────────────────────────────────────────
$tenantId       = 'e500988a-f788-4f81-b1ba-e3ad7cd66171'
$resourceAppId  = 'd50b1d91-8be2-48cd-9615-3fbba4e04a2b'
$correctIssuer  = "https://login.microsoftonline.com/$tenantId/v2.0"
# Entra user-delegated tokens (Foundry) use the App ID URI format; client_credentials tokens
# use the bare GUID.  Accept both so either flow works.
$correctAudience = @("api://$resourceAppId", $resourceAppId)
# Access tokens from Foundry's user-delegated flow do not carry the scopes that
# Kong was checking.  Clear scopes_required so token passes validation.
$correctScopes  = @()

$targetRoutes   = @('mcp-oauth-sse', 'mcp-oauth-messages')

Write-Info "Control plane    : $ControlPlaneId"
Write-Info "Target routes    : $($targetRoutes -join ', ')"
Write-Info "issuer           : $correctIssuer"
Write-Info "audience_required: $($correctAudience | ConvertTo-Json -Compress)"
Write-Info "scopes_required  : [] (cleared)"
Write-Info ""

# ── Fetch all plugins and routes ─────────────────────────────────────────────
$pluginsResp = Invoke-K -Method GET -Path "/v2/control-planes/$ControlPlaneId/core-entities/plugins?size=1000"
$allPlugins  = $pluginsResp.data

$routesResp  = Invoke-K -Method GET -Path "/v2/control-planes/$ControlPlaneId/core-entities/routes?size=1000"
$allRoutes   = $routesResp.data

$targetRouteIds = @{}
foreach ($r in $allRoutes) {
    if ($targetRoutes -contains $r.name) {
        $targetRouteIds[$r.name] = $r.id
        Write-Info "Found route '$($r.name)' → $($r.id)"
    }
}

if ($targetRouteIds.Count -eq 0) {
    Fail "Neither target route found in control plane $ControlPlaneId.  Have the OAuth routes been created yet?"
}

# ── Apply fixes ───────────────────────────────────────────────────────────────
$patched = 0
foreach ($routeName in $targetRoutes) {
    if (-not $targetRouteIds.ContainsKey($routeName)) {
        Write-Warn "Route '$routeName' not found — skipping."
        continue
    }
    $routeId = $targetRouteIds[$routeName]

    $oidc = $allPlugins | Where-Object { $_.name -eq 'openid-connect' -and $_.route.id -eq $routeId } | Select-Object -First 1
    if (-not $oidc) {
        Write-Warn "No openid-connect plugin on route '$routeName' ($routeId) — skipping."
        continue
    }

    Write-Info "Route '$routeName' — plugin $($oidc.id)"
    Write-Info "  Current issuer           : $(if ($oidc.config.issuer) { $oidc.config.issuer } else { '<not set>' })"
    Write-Info "  Current audience_required: $($oidc.config.audience_required | ConvertTo-Json -Compress)"
    Write-Info "  Current scopes_required  : $($oidc.config.scopes_required | ConvertTo-Json -Compress)"

    if ($PSCmdlet.ShouldProcess("plugin $($oidc.id) on route '$routeName'", "PUT issuer + audience_required + scopes_required")) {
        # GET full canonical plugin object to preserve all other config fields.
        # Konnect v2 requires PUT (no PATCH) — must send the complete object.
        $full = Invoke-K -Method GET -Path "/v2/control-planes/$ControlPlaneId/core-entities/plugins/$($oidc.id)"

        # Apply all three corrections atomically.
        $full.config.issuer            = $correctIssuer
        $full.config.audience_required = $correctAudience
        $full.config.scopes_required   = $correctScopes

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

        $result = Invoke-K -Method PUT -Path "/v2/control-planes/$ControlPlaneId/core-entities/plugins/$($oidc.id)" -Body $putBody

        Write-Ok "Updated plugin $($result.id):"
        Write-Ok "  issuer           = $($result.config.issuer)"
        Write-Ok "  audience_required = $($result.config.audience_required | ConvertTo-Json -Compress)"
        Write-Ok "  scopes_required  = $($result.config.scopes_required | ConvertTo-Json -Compress)"
        $patched++
    }
}

Write-Info ""
if ($patched -gt 0) {
    Write-Ok "$patched plugin(s) updated."
    Write-Info ""
    Write-Info "What Kong will now accept:"
    Write-Info "  - Issuer  : $correctIssuer (v2.0 Entra tokens)"
    Write-Info "  - Audience: api://$resourceAppId  OR  $resourceAppId"
    Write-Info "  - Scopes  : no enforcement (any valid token passes)"
    Write-Info ""
    Write-Info "Test with a Foundry bearer token:"
    Write-Info "  curl -H 'Authorization: Bearer <token>' \"
    Write-Info "       https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/oauth/sse"
    Write-Info ""
    Write-Info "If you want to re-enable scope enforcement later, set:"
    Write-Info "  scopes_required = ['MCP.Use']"
}
