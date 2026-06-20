#Requires -Version 7
<#
.SYNOPSIS
    Patches the openid-connect plugin on the OAuth MCP routes to set the
    correct Entra issuer URL so Kong can auto-discover the JWKS and validate
    token signatures.

    Error this fixes:
        "No credentials found for given 'iss'"
    Root cause:
        The `issuer` field was missing or incorrect on the OIDC plugins, so
        Kong could not fetch the public key material needed to verify tokens.

.PARAMETER Pat
    Konnect PAT.  Defaults to $env:KONNECT_PAT.

.PARAMETER ControlPlaneId
    Konnect control-plane ID.  Defaults to the project control plane.

.PARAMETER Issuer
    Entra v2.0 OIDC issuer URL.  Defaults to the tenant in entra-oauth-config.json:
    https://login.microsoftonline.com/e500988a-f788-4f81-b1ba-e3ad7cd66171/v2.0

.PARAMETER Region
    Konnect geo-region (us/eu/au/in/me).  Defaults to $env:KONNECT_REGION or 'us'.

.EXAMPLE
    $env:KONNECT_PAT = '<token>'
    .\scripts\fix-oidc-issuer.ps1

.EXAMPLE
    .\scripts\fix-oidc-issuer.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Pat            = $env:KONNECT_PAT,
    [string]$ControlPlaneId = '1933cbf7-093d-4e84-a6d7-8e553c34c9a7',
    [string]$Issuer         = 'https://login.microsoftonline.com/e500988a-f788-4f81-b1ba-e3ad7cd66171/v2.0',
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

$targetRoutes = @('mcp-oauth-sse', 'mcp-oauth-messages')

Write-Info "Control plane : $ControlPlaneId"
Write-Info "Target routes : $($targetRoutes -join ', ')"
Write-Info "Issuer to set : $Issuer"
Write-Info ""

# ── Fetch all plugins and routes (handle up to 1000 in one page) ─────────────
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

# ── Find OIDC plugins on those routes and update the issuer ──────────────────
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

    $currentIssuer = $oidc.config.issuer
    Write-Info "Route '$routeName' — plugin $($oidc.id)"
    Write-Info "  Current issuer : $(if ($currentIssuer) { $currentIssuer } else { '<not set>' })"
    Write-Info "  Target issuer  : $Issuer"

    if ($currentIssuer -eq $Issuer) {
        Write-Ok "Plugin $($oidc.id) already has the correct issuer — no change needed."
        continue
    }

    if ($PSCmdlet.ShouldProcess("plugin $($oidc.id) on route '$routeName'", "PUT issuer = $Issuer")) {
        # Konnect v2 does not support PATCH on plugin entities — GET full object,
        # update issuer, PUT the whole thing back.
        $full = Invoke-K -Method GET -Path "/v2/control-planes/$ControlPlaneId/core-entities/plugins/$($oidc.id)"
        $full.config.issuer = $Issuer

        # Build PUT body — omit read-only / server-managed fields.
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
        Write-Ok "Updated plugin $($result.id) — issuer = $($result.config.issuer)"
        $patched++
    }
}

Write-Info ""
if ($patched -gt 0) {
    Write-Ok "$patched plugin(s) updated."
    Write-Info "Kong will now auto-discover JWKS from:"
    Write-Info "  $Issuer/.well-known/openid-configuration"
    Write-Info ""
    Write-Info "Test with a valid Entra bearer token:"
    Write-Info "  curl -H 'Authorization: Bearer <token>' https://<kong-host>/mcp/oauth/sse"
} elseif ($targetRouteIds.Count -gt 0) {
    Write-Ok "All plugins already had the correct issuer — no updates needed."
}
