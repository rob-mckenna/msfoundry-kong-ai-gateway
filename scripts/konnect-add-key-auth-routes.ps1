#Requires -Version 7
<#
.SYNOPSIS
    Phase 1 of the key-auth migration: adds key-auth protected MCP routes
    alongside the existing JWT routes using a dedicated mcp-key-service.

    Architecture:
      - mcp-key-service → same MCP server URL as mcp-service
        Service-level plugins: key-auth, cors
      - Route: mcp-key-sse      → GET/POST/OPTIONS /mcp/key/sse
        Route-level plugins: post-function (body_filter SSE rewrite),
                             request-transformer (URI /mcp/key/sse → /mcp/sse)
      - Route: mcp-key-messages → POST/OPTIONS /mcp/key/messages
        Route-level plugins: request-transformer (URI /mcp/key/messages → /mcp/messages)
      - Consumer: foundry-mcp-client with key-auth credential

    WHY mcp-key-service (not mcp-service):
      The existing mcp-service has a service-level JWT plugin. Adding key-auth
      routes directly to mcp-service would cause the JWT plugin (priority 1005)
      to run before key-auth (priority 1003) and reject all requests without
      a valid JWT. A dedicated service avoids this conflict.

    REQUEST FLOW:
      Foundry → GET  /mcp/key/sse     [X-API-Key: …]
             → Kong key-auth validates key against foundry-mcp-client credential
             → request-transformer rewrites URI to /mcp/sse
             → MCP server receives GET /mcp/sse ← unaware of /key prefix
             → SSE stream: "data: /mcp/messages?sessionId=XXX"
             → post-function body_filter rewrites to "data: /mcp/key/messages?sessionId=XXX"
             → Foundry POSTs to /mcp/key/messages (key-auth protected) ✓

    Existing JWT routes (/mcp/sse, /mcp/messages) are left untouched.

.PARAMETER Pat
    Konnect PAT.  Defaults to $env:KONNECT_PAT.

.PARAMETER ControlPlaneId
    Konnect control-plane ID.  Defaults to the project control plane.

.PARAMETER Region
    Konnect geo-region (us/eu/au/in/me).  Defaults to $env:KONNECT_REGION or 'us'.

.PARAMETER ApiKey
    The API key credential to provision for foundry-mcp-client.
    If omitted, a 64-char hex key is generated automatically.

.PARAMETER SaveKeyTo
    File path to write the generated/provided API key config JSON.
    Defaults to 'api-key-config.json' in the repo root.
    This file is listed in .gitignore — do not commit it.

.PARAMETER Force
    Re-create entities that already exist rather than skipping them.

.EXAMPLE
    $env:KONNECT_PAT = '<token>'
    .\scripts\konnect-add-key-auth-routes.ps1

.EXAMPLE
    .\scripts\konnect-add-key-auth-routes.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Pat            = $env:KONNECT_PAT,
    [string]$ControlPlaneId = '1933cbf7-093d-4e84-a6d7-8e553c34c9a7',
    [string]$Region         = $(if ($env:KONNECT_REGION) { $env:KONNECT_REGION } else { 'us' }),
    [string]$ApiKey         = '',
    [string]$SaveKeyTo      = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$McpServerUrl  = 'https://kongai-mcp-server.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io'
$KeyServiceName = 'mcp-key-service'
$SseRouteName   = 'mcp-key-sse'
$MsgRouteName   = 'mcp-key-messages'
$ConsumerName   = 'foundry-mcp-client'
$GwBase         = 'https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io'

function Write-Info([string]$m)  { Write-Host "[INFO]  $m" }
function Write-Ok([string]$m)    { Write-Host "[OK]    $m" -ForegroundColor Green }
function Write-Warn([string]$m)  { Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Fail([string]$m)        { throw "[ERROR] $m" }

if ([string]::IsNullOrWhiteSpace($Pat)) {
    Fail 'Provide -Pat or set $env:KONNECT_PAT before running this script.'
}

# ── API key generation / validation ──────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Info "No -ApiKey provided — generating a 64-char hex key..."
    $rng    = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    $ApiKey = ([System.BitConverter]::ToString($rng) -replace '-', '').ToLower()
    Write-Info "Generated key: $ApiKey"
} else {
    Write-Info "Using provided API key (length: $($ApiKey.Length))"
}

# ── Key output file ───────────────────────────────────────────────────────────
$repoRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($SaveKeyTo)) {
    $SaveKeyTo = Join-Path $repoRoot 'api-key-config.json'
}

# ── Konnect helpers ───────────────────────────────────────────────────────────
$base    = "https://$Region.api.konghq.com"
$headers = @{
    Authorization  = "Bearer $Pat"
    'Content-Type' = 'application/json'
}
$cpBase  = "/v2/control-planes/$ControlPlaneId/core-entities"

function Invoke-K {
    param([string]$Method, [string]$Path, [object]$Body = $null)
    $uri = "$base$Path"
    if ($null -ne $Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers `
               -Body ($Body | ConvertTo-Json -Depth 12 -Compress)
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

# ── Body-filter Lua: rewrites SSE endpoint advertisement ─────────────────────
# MCP server sends: data: /mcp/messages?sessionId=XXX
# Must become:      data: /mcp/key/messages?sessionId=XXX (key-auth protected)
$bodyFilterLua = @'
local chunk = ngx.arg[1]
if chunk and #chunk > 0 then
    local rewritten, n = chunk:gsub(
        "data: /mcp/messages%?",
        "data: /mcp/key/messages?"
    )
    if n and n > 0 then
        kong.log.notice("[mcp-key-rewrite] rewrote endpoint event: /mcp/messages -> /mcp/key/messages")
        ngx.arg[1] = rewritten
    end
end
'@

# ─────────────────────────────────────────────────────────────────────────────
Write-Info "=== Phase 1: Key-Auth Route Setup ==="
Write-Info "Control plane : $ControlPlaneId"
Write-Info "Region        : $Region"
Write-Info ""

# ── Step 0: Validate PAT / connectivity ──────────────────────────────────────
Write-Info "Step 0 — Validating Konnect connectivity..."
try {
    $me = Invoke-K -Method GET -Path "/v2/users/me"
    Write-Ok "Connected as: $($me.full_name) ($($me.email))"
} catch {
    Fail "Konnect API call failed — check PAT and region. Error: $_"
}

# Load all entities once
$allServices = (Invoke-K -Method GET -Path "$cpBase/services?size=1000").data
$allRoutes   = (Invoke-K -Method GET -Path "$cpBase/routes?size=1000").data
$allPlugins  = (Invoke-K -Method GET -Path "$cpBase/plugins?size=1000").data
$allConsumers = (Invoke-K -Method GET -Path "$cpBase/consumers?size=1000").data

# ── Step 1: Create mcp-key-service ───────────────────────────────────────────
# Separate service from mcp-service to avoid inheriting its service-level JWT plugin.
Write-Info ""
Write-Info "Step 1 — Service: $KeyServiceName"
$svc = $allServices | Where-Object { $_.name -eq $KeyServiceName } | Select-Object -First 1

if ($svc -and -not $Force) {
    Write-Warn "Service '$KeyServiceName' already exists ($($svc.id)) — skipping."
} else {
    if ($PSCmdlet.ShouldProcess($KeyServiceName, 'Create service')) {
        if ($svc) {
            Write-Info "  Force — deleting existing service..."
            Invoke-K -Method DELETE -Path "$cpBase/services/$($svc.id)" | Out-Null
        }
        $svc = Invoke-K -Method POST -Path "$cpBase/services" -Body @{
            name = $KeyServiceName
            url  = $McpServerUrl
            tags = @('key-auth', 'mcp', 'phase1')
        }
        Write-Ok "Created $KeyServiceName → $($svc.id)"
    }
}

# ── Step 2: Consumer: foundry-mcp-client ─────────────────────────────────────
Write-Info ""
Write-Info "Step 2 — Consumer: $ConsumerName"
$consumer = $allConsumers | Where-Object { $_.username -eq $ConsumerName } | Select-Object -First 1

if ($consumer -and -not $Force) {
    Write-Warn "Consumer '$ConsumerName' already exists ($($consumer.id)) — skipping creation."
} else {
    if ($PSCmdlet.ShouldProcess($ConsumerName, 'Create consumer')) {
        if ($consumer) {
            Write-Info "  Force — deleting existing consumer..."
            Invoke-K -Method DELETE -Path "$cpBase/consumers/$($consumer.id)" | Out-Null
        }
        $consumer = Invoke-K -Method POST -Path "$cpBase/consumers" -Body @{
            username = $ConsumerName
            tags     = @('key-auth', 'foundry', 'mcp')
        }
        Write-Ok "Created consumer: $($consumer.username) → $($consumer.id)"
    }
}

# ── Step 3: Key-auth credential ───────────────────────────────────────────────
Write-Info ""
Write-Info "Step 3 — Key-auth credential for $ConsumerName"
$existingCreds = Invoke-K -Method GET -Path "$cpBase/consumers/$($consumer.id)/key-auth?size=1000"

if ($existingCreds.data.Count -gt 0 -and -not $Force) {
    Write-Warn "Consumer already has $($existingCreds.data.Count) credential(s) — skipping."
    Write-Warn "Use -Force to replace. Existing: $(($existingCreds.data | ForEach-Object { $_.id }) -join ', ')"
} else {
    if ($PSCmdlet.ShouldProcess("$ConsumerName", 'Create key-auth credential')) {
        if ($Force -and $existingCreds.data.Count -gt 0) {
            $existingCreds.data | ForEach-Object {
                Invoke-K -Method DELETE -Path "$cpBase/consumers/$($consumer.id)/key-auth/$($_.id)" | Out-Null
            }
        }
        $cred = Invoke-K -Method POST -Path "$cpBase/consumers/$($consumer.id)/key-auth" -Body @{
            key  = $ApiKey
            tags = @('foundry', 'mcp', 'phase1')
        }
        Write-Ok "Created key credential: $($cred.id)"
    }
}

# ── Step 4: Service-level plugins: key-auth + cors ───────────────────────────
Write-Info ""
Write-Info "Step 4 — Service-level plugins on $KeyServiceName"

function Ensure-ServicePlugin([string]$Name, [object]$Config) {
    $existing = $allPlugins | Where-Object { $_.name -eq $Name -and $_.service.id -eq $svc.id } | Select-Object -First 1
    if ($existing -and -not $Force) {
        Write-Warn "Plugin '$Name' already on $KeyServiceName — skipping."
        return $existing
    }
    if ($PSCmdlet.ShouldProcess("$Name on $KeyServiceName", 'Create plugin')) {
        if ($existing) { Invoke-K -Method DELETE -Path "$cpBase/plugins/$($existing.id)" | Out-Null }
        $p = Invoke-K -Method POST -Path "$cpBase/plugins" -Body @{
            name    = $Name; enabled = $true; config = $Config
            service = @{ id = $svc.id }
        }
        Write-Ok "Created service plugin '$Name' → $($p.id)"
        return $p
    }
}

Ensure-ServicePlugin -Name 'key-auth' -Config @{
    key_names        = @('X-API-Key')
    hide_credentials = $true
    key_in_header    = $true
    key_in_query     = $false
    key_in_body      = $false
    anonymous        = $null
} | Out-Null

Ensure-ServicePlugin -Name 'cors' -Config @{
    origins         = @('*')
    methods         = @('GET','POST','OPTIONS')
    headers         = @('Accept','Content-Type','X-API-Key','Cache-Control','Connection')
    exposed_headers = @('Content-Type','Cache-Control','Connection')
    credentials     = $false
    max_age         = 3600
} | Out-Null

# ── Step 5: Routes ────────────────────────────────────────────────────────────
Write-Info ""
Write-Info "Step 5 — Routes on $KeyServiceName"

function Ensure-Route([string]$Name, [string[]]$Paths, [string[]]$Methods) {
    $existing = $allRoutes | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($existing -and -not $Force) {
        Write-Warn "Route '$Name' already exists — skipping."
        return $existing
    }
    if ($PSCmdlet.ShouldProcess($Name, 'Create route')) {
        if ($existing) { Invoke-K -Method DELETE -Path "$cpBase/routes/$($existing.id)" | Out-Null }
        $r = Invoke-K -Method POST -Path "$cpBase/routes" -Body @{
            name = $Name; paths = $Paths; methods = $Methods
            strip_path = $false; preserve_host = $false
            service = @{ id = $svc.id }; tags = @('key-auth','mcp','phase1')
        }
        Write-Ok "Created route '$Name' → $($r.id)"
        return $r
    }
}

$sseRoute = Ensure-Route -Name $SseRouteName -Paths @('/mcp/key/sse')      -Methods @('GET','POST','OPTIONS')
$msgRoute = Ensure-Route -Name $MsgRouteName -Paths @('/mcp/key/messages') -Methods @('POST','OPTIONS')

# Refresh if routes existed already
if (-not $sseRoute) { $sseRoute = (Invoke-K -Method GET -Path "$cpBase/routes?size=1000").data | Where-Object { $_.name -eq $SseRouteName } | Select-Object -First 1 }
if (-not $msgRoute) { $msgRoute = (Invoke-K -Method GET -Path "$cpBase/routes?size=1000").data | Where-Object { $_.name -eq $MsgRouteName } | Select-Object -First 1 }

# Refresh plugin list for route-level operations
$allPlugins = (Invoke-K -Method GET -Path "$cpBase/plugins?size=1000").data

function Ensure-RoutePlugin([string]$Name, [object]$RouteObj, [object]$Config) {
    $existing = $allPlugins | Where-Object { $_.name -eq $Name -and $_.route.id -eq $RouteObj.id } | Select-Object -First 1
    if ($existing -and -not $Force) {
        Write-Warn "Plugin '$Name' already on '$($RouteObj.name)' — skipping."
        return $existing
    }
    if ($PSCmdlet.ShouldProcess("$Name on $($RouteObj.name)", 'Create plugin')) {
        if ($existing) { Invoke-K -Method DELETE -Path "$cpBase/plugins/$($existing.id)" | Out-Null }
        $p = Invoke-K -Method POST -Path "$cpBase/plugins" -Body @{
            name = $Name; enabled = $true; config = $Config
            route = @{ id = $RouteObj.id }
        }
        Write-Ok "Created route plugin '$Name' on '$($RouteObj.name)' → $($p.id)"
        return $p
    }
}

# ── Step 6: request-transformer (path rewrite) on both routes ────────────────
Write-Info ""
Write-Info "Step 6 — Path rewrite (request-transformer)"
Write-Info "  /mcp/key/sse      → upstream /mcp/sse"
Write-Info "  /mcp/key/messages → upstream /mcp/messages"

Ensure-RoutePlugin -Name 'request-transformer' -RouteObj $sseRoute -Config @{
    replace = @{ uri = '/mcp/sse' }
} | Out-Null

Ensure-RoutePlugin -Name 'request-transformer' -RouteObj $msgRoute -Config @{
    replace = @{ uri = '/mcp/messages' }
} | Out-Null

# ── Step 7: body_filter post-function on SSE route ───────────────────────────
Write-Info ""
Write-Info "Step 7 — SSE endpoint rewrite (body_filter post-function on $SseRouteName)"
Write-Info "  'data: /mcp/messages?' → 'data: /mcp/key/messages?'"

Ensure-RoutePlugin -Name 'post-function' -RouteObj $sseRoute -Config @{
    body_filter = @($bodyFilterLua)
} | Out-Null

# ── Step 8: Save API key config ───────────────────────────────────────────────
Write-Info ""
Write-Info "Step 8 — Saving API key config to $SaveKeyTo..."
@{
    description      = 'Kong key-auth credential for foundry-mcp-client (Phase 1 migration)'
    consumer         = $ConsumerName
    header_name      = 'X-API-Key'
    api_key          = $ApiKey
    sse_endpoint     = "$GwBase/mcp/key/sse"
    msg_endpoint     = "$GwBase/mcp/key/messages"
    created_at       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
    note             = 'DO NOT COMMIT. Listed in .gitignore. Treat as a password — rotate every 90 days.'
    foundry_connection = @{
        server_url       = "$GwBase/mcp/key/sse"
        auth_type        = 'Key-based authentication'
        credential_name  = 'X-API-Key'
        credential_value = $ApiKey
    }
} | ConvertTo-Json | Set-Content -Path $SaveKeyTo -Encoding UTF8
Write-Ok "Key config written to: $SaveKeyTo"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Phase 1 Complete — Key-Auth Routes Provisioned" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Consumer   : $ConsumerName"
Write-Host "  API Key    : $ApiKey" -ForegroundColor Yellow
Write-Host "  Header     : X-API-Key: <key>"
Write-Host ""
Write-Host "  New routes (mcp-key-service):"
Write-Host "    GET  /mcp/key/sse      → key-auth required"
Write-Host "    POST /mcp/key/messages → key-auth required"
Write-Host ""
Write-Host "  JWT routes UNCHANGED (mcp-service):"
Write-Host "    GET  /mcp/sse"
Write-Host "    POST /mcp/messages"
Write-Host ""
Write-Host "  Test commands:" -ForegroundColor Cyan
Write-Host "  # 401 (no key):"
Write-Host "  curl -s $GwBase/mcp/key/sse"
Write-Host ""
Write-Host "  # 200 + SSE stream:"
Write-Host "  curl -s -N -H 'Accept: text/event-stream' -H 'X-API-Key: $ApiKey' $GwBase/mcp/key/sse"
Write-Host ""
Write-Host "  API key also saved to: $SaveKeyTo" -ForegroundColor Yellow
Write-Host ""


.PARAMETER Pat
    Konnect PAT.  Defaults to $env:KONNECT_PAT.

.PARAMETER ControlPlaneId
    Konnect control-plane ID.  Defaults to the project control plane.

.PARAMETER Region
    Konnect geo-region (us/eu/au/in/me).  Defaults to $env:KONNECT_REGION or 'us'.

.PARAMETER ApiKey
    The API key credential to provision for foundry-mcp-client.
    If omitted, a 64-char hex key is generated automatically.

.PARAMETER SaveKeyTo
    File path to write the generated/provided API key config JSON.
    Defaults to 'api-key-config.json' in the repo root.
    This file is listed in .gitignore — do not commit it.

.PARAMETER Force
    Re-create entities that already exist rather than skipping them.

.EXAMPLE
    $env:KONNECT_PAT = '<token>'
    .\scripts\konnect-add-key-auth-routes.ps1

.EXAMPLE
    .\scripts\konnect-add-key-auth-routes.ps1 -WhatIf

.EXAMPLE
    .\scripts\konnect-add-key-auth-routes.ps1 -ApiKey 'my-custom-key' -SaveKeyTo 'C:\safe\api-key.json'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Pat            = $env:KONNECT_PAT,
    [string]$ControlPlaneId = '1933cbf7-093d-4e84-a6d7-8e553c34c9a7',
    [string]$Region         = $(if ($env:KONNECT_REGION) { $env:KONNECT_REGION } else { 'us' }),
    [string]$ApiKey         = '',
    [string]$SaveKeyTo      = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Info([string]$m)  { Write-Host "[INFO]  $m" }
function Write-Ok([string]$m)    { Write-Host "[OK]    $m" -ForegroundColor Green }
function Write-Warn([string]$m)  { Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Fail([string]$m)        { throw "[ERROR] $m" }

if ([string]::IsNullOrWhiteSpace($Pat)) {
    Fail 'Provide -Pat or set $env:KONNECT_PAT before running this script.'
}

# ── API key generation / validation ──────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Info "No -ApiKey provided — generating a 64-char hex key..."
    $rng    = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    $ApiKey = ([System.BitConverter]::ToString($rng) -replace '-', '').ToLower()
    Write-Info "Generated key: $ApiKey"
} else {
    Write-Info "Using provided API key (length: $($ApiKey.Length))"
}

# ── Key output file ───────────────────────────────────────────────────────────
$repoRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($SaveKeyTo)) {
    $SaveKeyTo = Join-Path $repoRoot 'api-key-config.json'
}

# ── Konnect helpers ───────────────────────────────────────────────────────────
$base    = "https://$Region.api.konghq.com"
$headers = @{
    Authorization  = "Bearer $Pat"
    'Content-Type' = 'application/json'
}
$cpBase  = "/v2/control-planes/$ControlPlaneId/core-entities"

function Invoke-K {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body = $null
    )
    $uri = "$base$Path"
    if ($null -ne $Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers `
               -Body ($Body | ConvertTo-Json -Depth 12 -Compress)
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

# ── Body-filter Lua: rewrites SSE endpoint advertisement ─────────────────────
# The MCP server sends:  data: /mcp/messages?sessionId=XXX
# Foundry must post to:  /mcp/key/messages?sessionId=XXX  (key-auth protected)
$bodyFilterLua = @'
local chunk = ngx.arg[1]
if chunk and #chunk > 0 then
    local rewritten, n = chunk:gsub(
        "data: /mcp/messages%?",
        "data: /mcp/key/messages?"
    )
    if n and n > 0 then
        kong.log.notice("[mcp-key-rewrite] rewrote endpoint event: /mcp/messages -> /mcp/key/messages")
        ngx.arg[1] = rewritten
    end
end
'@

# ─────────────────────────────────────────────────────────────────────────────
Write-Info "=== Phase 1: Key-Auth Route Setup ==="
Write-Info "Control plane : $ControlPlaneId"
Write-Info "Region        : $Region"
Write-Info ""

# ── Step 0: Validate PAT / connectivity ──────────────────────────────────────
Write-Info "Step 0 — Validating Konnect connectivity..."
try {
    $me = Invoke-K -Method GET -Path "/v2/users/me"
    Write-Ok "Connected as: $($me.full_name) ($($me.email))"
} catch {
    Fail "Konnect API call failed — check PAT and region. Error: $_"
}

# ── Step 1: Find the existing mcp-service ────────────────────────────────────
Write-Info ""
Write-Info "Step 1 — Finding existing mcp-service..."
$services   = Invoke-K -Method GET -Path "$cpBase/services?size=1000"
$mcpService = $services.data | Where-Object { $_.name -eq 'mcp-service' } | Select-Object -First 1
if (-not $mcpService) { Fail "Could not find 'mcp-service' in control plane $ControlPlaneId. Has the base config been synced?" }
Write-Ok "Found mcp-service → $($mcpService.id)"
Write-Info "  URL: $($mcpService.url ?? ($mcpService.protocol + '://' + $mcpService.host))"

# ── Step 2: Create consumer foundry-mcp-client ───────────────────────────────
Write-Info ""
Write-Info "Step 2 — Consumer: foundry-mcp-client"
$consumers = Invoke-K -Method GET -Path "$cpBase/consumers?size=1000"
$consumer  = $consumers.data | Where-Object { $_.username -eq 'foundry-mcp-client' } | Select-Object -First 1

if ($consumer -and -not $Force) {
    Write-Warn "Consumer 'foundry-mcp-client' already exists ($($consumer.id)) — skipping creation."
} else {
    if ($PSCmdlet.ShouldProcess('foundry-mcp-client', 'Create consumer')) {
        if ($consumer) {
            Write-Info "  Force flag set — deleting existing consumer first..."
            Invoke-K -Method DELETE -Path "$cpBase/consumers/$($consumer.id)" | Out-Null
        }
        $consumer = Invoke-K -Method POST -Path "$cpBase/consumers" -Body @{
            username = 'foundry-mcp-client'
            tags     = @('key-auth', 'foundry', 'mcp')
        }
        Write-Ok "Created consumer: $($consumer.username) → $($consumer.id)"
    }
}

# ── Step 3: Create key-auth credential on consumer ───────────────────────────
Write-Info ""
Write-Info "Step 3 — Key-auth credential for foundry-mcp-client"
$existingCreds = Invoke-K -Method GET -Path "$cpBase/consumers/$($consumer.id)/key-auth?size=1000"
$existingCred  = $existingCreds.data | Where-Object { $_.key -eq $ApiKey } | Select-Object -First 1

if ($existingCred -and -not $Force) {
    Write-Warn "Key credential already exists ($($existingCred.id)) — skipping."
} else {
    if ($existingCreds.data.Count -gt 0 -and -not $Force) {
        Write-Warn "Consumer already has $($existingCreds.data.Count) key credential(s). Use -Force to replace."
        Write-Warn "Existing key id(s): $(($existingCreds.data | ForEach-Object { $_.id }) -join ', ')"
    } else {
        if ($PSCmdlet.ShouldProcess("foundry-mcp-client/$($consumer.id)", 'Create key-auth credential')) {
            if ($Force -and $existingCreds.data.Count -gt 0) {
                Write-Info "  Force flag — deleting $($existingCreds.data.Count) existing credential(s)..."
                $existingCreds.data | ForEach-Object {
                    Invoke-K -Method DELETE -Path "$cpBase/consumers/$($consumer.id)/key-auth/$($_.id)" | Out-Null
                }
            }
            $cred = Invoke-K -Method POST -Path "$cpBase/consumers/$($consumer.id)/key-auth" -Body @{
                key  = $ApiKey
                tags = @('foundry', 'mcp', 'phase1')
            }
            Write-Ok "Created key credential: $($cred.id)"
        }
    }
}

# ── Step 4: Create routes on mcp-service ─────────────────────────────────────
Write-Info ""
Write-Info "Step 4 — Routes on mcp-service"
$routes     = Invoke-K -Method GET -Path "$cpBase/routes?size=1000"
$allRoutes  = $routes.data

function Ensure-Route {
    param([string]$Name, [string[]]$Paths, [string[]]$Methods)
    $existing = $allRoutes | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($existing -and -not $Force) {
        Write-Warn "Route '$Name' already exists ($($existing.id)) — skipping."
        return $existing
    }
    if ($PSCmdlet.ShouldProcess($Name, 'Create route')) {
        if ($existing) {
            Write-Info "  Force — deleting existing route '$Name' ($($existing.id))..."
            Invoke-K -Method DELETE -Path "$cpBase/routes/$($existing.id)" | Out-Null
        }
        $r = Invoke-K -Method POST -Path "$cpBase/routes" -Body @{
            name          = $Name
            paths         = $Paths
            methods       = $Methods
            strip_path    = $false
            preserve_host = $false
            service       = @{ id = $mcpService.id }
            tags          = @('key-auth', 'mcp', 'phase1')
        }
        Write-Ok "Created route '$Name' → $($r.id)  paths=$($Paths -join ',')  methods=$($Methods -join ',')"
        return $r
    }
    return $null
}

$sseRoute  = Ensure-Route -Name 'mcp-key-sse'      -Paths @('/mcp/key/sse')      -Methods @('GET','POST','OPTIONS')
$msgRoute  = Ensure-Route -Name 'mcp-key-messages'  -Paths @('/mcp/key/messages') -Methods @('POST','OPTIONS')

# Refresh route list for plugin lookups
$routes    = Invoke-K -Method GET -Path "$cpBase/routes?size=1000"
$allRoutes = $routes.data
if (-not $sseRoute)  { $sseRoute = $allRoutes | Where-Object { $_.name -eq 'mcp-key-sse' }      | Select-Object -First 1 }
if (-not $msgRoute)  { $msgRoute = $allRoutes | Where-Object { $_.name -eq 'mcp-key-messages' }  | Select-Object -First 1 }

# ── Step 5: key-auth plugin on both routes ────────────────────────────────────
Write-Info ""
Write-Info "Step 5 — key-auth plugin"
$pluginsResp = Invoke-K -Method GET -Path "$cpBase/plugins?size=1000"
$allPlugins  = $pluginsResp.data

$keyAuthConfig = @{
    key_names        = @('X-API-Key')
    hide_credentials = $true
    key_in_header    = $true
    key_in_query     = $false
    key_in_body      = $false
    anonymous        = $null
}

function Ensure-Plugin {
    param([string]$PluginName, [object]$RouteObj, [object]$Config)
    $routeId  = $RouteObj.id
    $existing = $allPlugins | Where-Object { $_.name -eq $PluginName -and $_.route.id -eq $routeId } | Select-Object -First 1
    if ($existing -and -not $Force) {
        Write-Warn "Plugin '$PluginName' already on route $($RouteObj.name) ($($existing.id)) — skipping."
        return $existing
    }
    if ($PSCmdlet.ShouldProcess("$PluginName on $($RouteObj.name)", 'Create plugin')) {
        if ($existing) {
            Write-Info "  Force — deleting existing plugin $($existing.id)..."
            Invoke-K -Method DELETE -Path "$cpBase/plugins/$($existing.id)" | Out-Null
        }
        $p = Invoke-K -Method POST -Path "$cpBase/plugins" -Body @{
            name    = $PluginName
            enabled = $true
            config  = $Config
            route   = @{ id = $routeId }
        }
        Write-Ok "Created plugin '$PluginName' on '$($RouteObj.name)' → $($p.id)"
        return $p
    }
    return $null
}

Ensure-Plugin -PluginName 'key-auth' -RouteObj $sseRoute -Config $keyAuthConfig | Out-Null
Ensure-Plugin -PluginName 'key-auth' -RouteObj $msgRoute -Config $keyAuthConfig | Out-Null

# ── Step 6: body_filter post-function on SSE route ───────────────────────────
Write-Info ""
Write-Info "Step 6 — SSE endpoint rewrite (body_filter post-function)"
Write-Info "  Rewrites: 'data: /mcp/messages?' → 'data: /mcp/key/messages?'"

$existingPf = $allPlugins | Where-Object { $_.name -eq 'post-function' -and $_.route.id -eq $sseRoute.id } | Select-Object -First 1

if ($existingPf -and -not $Force) {
    Write-Warn "post-function already on mcp-key-sse ($($existingPf.id)) — skipping."
} else {
    if ($PSCmdlet.ShouldProcess('mcp-key-sse', 'Create post-function body_filter rewrite')) {
        if ($existingPf) {
            Write-Info "  Force — deleting existing post-function $($existingPf.id)..."
            Invoke-K -Method DELETE -Path "$cpBase/plugins/$($existingPf.id)" | Out-Null
        }
        $pf = Invoke-K -Method POST -Path "$cpBase/plugins" -Body @{
            name    = 'post-function'
            enabled = $true
            config  = @{
                body_filter = @($bodyFilterLua)
            }
            route   = @{ id = $sseRoute.id }
        }
        Write-Ok "Created post-function $($pf.id) with body_filter rewrite."
    }
}

# ── Step 7: Save API key config ───────────────────────────────────────────────
Write-Info ""
Write-Info "Step 7 — Saving API key config..."
$keyConfig = [ordered]@{
    description    = 'Kong key-auth credential for foundry-mcp-client (Phase 1 migration)'
    consumer       = 'foundry-mcp-client'
    header_name    = 'X-API-Key'
    api_key        = $ApiKey
    sse_endpoint   = 'https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/key/sse'
    msg_endpoint   = 'https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/key/messages'
    created_at     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
    note           = 'DO NOT COMMIT. Stored in .gitignore. Treat as a password — rotate every 90 days.'
}
$keyConfig | ConvertTo-Json | Set-Content -Path $SaveKeyTo -Encoding UTF8
Write-Ok "Key config written to: $SaveKeyTo"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Phase 1 Complete — Key-Auth Routes Provisioned" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Consumer   : foundry-mcp-client"
Write-Host "  API Key    : $ApiKey" -ForegroundColor Yellow
Write-Host "  Header     : X-API-Key: <key>"
Write-Host ""
Write-Host "  New routes:"
Write-Host "    GET  /mcp/key/sse      → key-auth required"
Write-Host "    POST /mcp/key/messages → key-auth required"
Write-Host ""
Write-Host "  JWT routes UNCHANGED:"
Write-Host "    GET  /mcp/sse"
Write-Host "    POST /mcp/messages"
Write-Host ""
Write-Host "  Test commands (copy & paste):" -ForegroundColor Cyan
Write-Host ""
Write-Host "  # Should return 401 (no key):"
Write-Host "  curl -s https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/key/sse"
Write-Host ""
Write-Host "  # Should open SSE stream:"
Write-Host "  curl -s -N -H 'Accept: text/event-stream' -H 'X-API-Key: $ApiKey' https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io/mcp/key/sse"
Write-Host ""
Write-Host "  API key also saved to: $SaveKeyTo" -ForegroundColor Yellow
Write-Host ""
