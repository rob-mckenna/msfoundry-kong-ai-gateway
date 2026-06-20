#Requires -Version 7
<#
.SYNOPSIS
    Patches the openid-connect plugin on the OAuth MCP routes to accept both
    audience formats that Microsoft Entra can issue:
      - api://d50b1d91-8be2-48cd-9615-3fbba4e04a2b  (what Entra actually issues)
      - d50b1d91-8be2-48cd-9615-3fbba4e04a2b        (bare GUID — legacy config)

.PARAMETER Pat
    Konnect PAT.  Defaults to $env:KONNECT_PAT.

.PARAMETER ControlPlaneId
    Konnect control-plane ID.  Defaults to the value in konnect-connection.json.

.PARAMETER Region
    Konnect geo-region (us/eu/au/in/me).  Defaults to $env:KONNECT_REGION or 'us'.

.EXAMPLE
    $env:KONNECT_PAT = '<token>'
    .\scripts\fix-oidc-audience.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Pat            = $env:KONNECT_PAT,
    [string]$ControlPlaneId = '1933cbf7-093d-4e84-a6d7-8e553c34c9a7',
    [string]$Region         = $(if ($env:KONNECT_REGION) { $env:KONNECT_REGION } else { 'us' })
)

$ErrorActionPreference = 'Stop'

function Write-Info([string]$m) { Write-Host "[INFO]  $m" }
function Write-Ok([string]$m)   { Write-Host "[OK]    $m" -ForegroundColor Green }
function Fail([string]$m)       { throw "[ERROR] $m" }

if ([string]::IsNullOrWhiteSpace($Pat)) { Fail 'Provide -Pat or set KONNECT_PAT.' }

$base    = "https://$Region.api.konghq.com"
$headers = @{ Authorization = "Bearer $Pat"; 'Content-Type' = 'application/json' }

function Invoke-K([string]$Method, [string]$Path, [object]$Body) {
    $uri = "$base$Path"
    if ($null -ne $Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body ($Body | ConvertTo-Json -Depth 10 -Compress)
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

$resourceAppId  = 'd50b1d91-8be2-48cd-9615-3fbba4e04a2b'
$newAudiences   = @("api://$resourceAppId", $resourceAppId)
$targetRoutes   = @('mcp-oauth-sse', 'mcp-oauth-messages')

Write-Info "Control plane : $ControlPlaneId"
Write-Info "Target routes : $($targetRoutes -join ', ')"
Write-Info "New audiences : $($newAudiences -join ', ')"
Write-Info ""

# ── Fetch all plugins (may be paginated; handle up to 1000 in one page) ──────
$pluginsResp = Invoke-K -Method GET -Path "/v2/control-planes/$ControlPlaneId/core-entities/plugins?size=1000"
$allPlugins  = $pluginsResp.data

# ── Fetch all routes to resolve names → IDs ───────────────────────────────────
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

# ── Find OIDC plugins on those routes ────────────────────────────────────────
$patched = 0
foreach ($routeName in $targetRoutes) {
    if (-not $targetRouteIds.ContainsKey($routeName)) {
        Write-Host "[WARN]  Route '$routeName' not found — skipping." -ForegroundColor Yellow
        continue
    }
    $routeId = $targetRouteIds[$routeName]

    $oidc = $allPlugins | Where-Object { $_.name -eq 'openid-connect' -and $_.route.id -eq $routeId } | Select-Object -First 1
    if (-not $oidc) {
        Write-Host "[WARN]  No openid-connect plugin on route '$routeName' ($routeId) — skipping." -ForegroundColor Yellow
        continue
    }

    $currentAud = $oidc.config.audience_required
    Write-Info "Route '$routeName' — plugin $($oidc.id)"
    Write-Info "  Current audience_required : $($currentAud | ConvertTo-Json -Compress)"
    Write-Info "  Patching to               : $($newAudiences | ConvertTo-Json -Compress)"

    if ($PSCmdlet.ShouldProcess("plugin $($oidc.id) on route '$routeName'", "PUT audience_required")) {
        # Konnect v2 does not support PATCH on plugin entities — must PUT the full object.
        # GET the canonical full object so we don't lose any fields, then overwrite
        # audience_required and PUT it back.
        $full = Invoke-K -Method GET -Path "/v2/control-planes/$ControlPlaneId/core-entities/plugins/$($oidc.id)"
        $full.config.audience_required = $newAudiences

        # Strip read-only / server-managed fields that Konnect rejects in PUT bodies.
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
        Write-Ok "Updated plugin $($result.id) — audience_required = $($result.config.audience_required | ConvertTo-Json -Compress)"
        $patched++
    }
}

Write-Info ""
if ($patched -gt 0) {
    Write-Ok "$patched plugin(s) updated.  Kong will now accept tokens with aud 'api://$resourceAppId' OR '$resourceAppId'."
} else {
    Write-Host "[WARN]  No plugins were updated (check warnings above)." -ForegroundColor Yellow
}
