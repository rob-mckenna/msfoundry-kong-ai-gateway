#Requires -Version 7
<#
.SYNOPSIS
    Rotates the key-auth credential for the foundry-mcp-client consumer in Kong Konnect.
    Deletes the old credential, creates a new one, and writes the updated config to api-key-config.json.

.DESCRIPTION
    Safe rotation flow:
      1. Validate PAT / Konnect connectivity
      2. Look up the foundry-mcp-client consumer
      3. List existing key-auth credentials
      4. DELETE the old credential(s)
      5. CREATE a new 64-char hex credential
      6. Smoke-test the new key against the live SSE endpoint
      7. Write api-key-config.json with the new key

    Run this script whenever a key needs to be rotated (exposure, 90-day schedule, etc.).

.PARAMETER Pat
    Konnect PAT.  Defaults to $env:KONNECT_PAT.

.PARAMETER ControlPlaneId
    Konnect control-plane ID.  Defaults to the project control plane.

.PARAMETER Region
    Konnect geo-region (us/eu/au/in/me).  Defaults to $env:KONNECT_REGION or 'us'.

.PARAMETER NewKey
    Optional: supply a specific new key value (64-char hex).
    If omitted, a key is generated automatically with .NET crypto RNG.

.PARAMETER SaveKeyTo
    File path to write the rotated key config JSON.
    Defaults to 'api-key-config.json' in the repo root.
    This file is listed in .gitignore — do not commit it.

.PARAMETER SkipSmokeTest
    Skip the live HTTP smoke-test after rotation.
    Useful when running in an environment without outbound HTTPS to the gateway.

.EXAMPLE
    $env:KONNECT_PAT = '<token>'
    .\scripts\rotate-api-key.ps1

.EXAMPLE
    .\scripts\rotate-api-key.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Pat            = $env:KONNECT_PAT,
    [string]$ControlPlaneId = '1933cbf7-093d-4e84-a6d7-8e553c34c9a7',
    [string]$Region         = $(if ($env:KONNECT_REGION) { $env:KONNECT_REGION } else { 'us' }),
    [string]$NewKey         = '',
    [string]$SaveKeyTo      = '',
    [switch]$SkipSmokeTest
)

$ErrorActionPreference = 'Stop'
$ConsumerName = 'foundry-mcp-client'
$GwBase       = 'https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io'
$SseEndpoint  = "$GwBase/mcp/key/sse"
$MsgEndpoint  = "$GwBase/mcp/key/messages"

function Write-Info([string]$m)  { Write-Host "[INFO]  $m" }
function Write-Ok([string]$m)    { Write-Host "[OK]    $m" -ForegroundColor Green }
function Write-Warn([string]$m)  { Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Fail([string]$m)        { throw "[ERROR] $m" }

if ([string]::IsNullOrWhiteSpace($Pat)) {
    Fail 'Provide -Pat or set $env:KONNECT_PAT before running this script.'
}

# ── Generate new key if not provided ─────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($NewKey)) {
    Write-Info "Generating new 64-char hex API key..."
    $rng    = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    $NewKey = ([System.BitConverter]::ToString($rng) -replace '-', '').ToLower()
} else {
    if ($NewKey.Length -ne 64 -or $NewKey -notmatch '^[0-9a-f]{64}$') {
        Fail "Provided -NewKey must be exactly 64 lowercase hex characters."
    }
    Write-Info "Using provided API key."
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

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Info "=== Kong API Key Rotation ==="
Write-Info "Consumer      : $ConsumerName"
Write-Info "Control plane : $ControlPlaneId"
Write-Info "Region        : $Region"
Write-Info "Output file   : $SaveKeyTo"
Write-Info ""

# ── Step 0: Validate PAT / connectivity ──────────────────────────────────────
Write-Info "Step 0 — Validating Konnect connectivity..."
try {
    $me = Invoke-K -Method GET -Path "/v2/users/me"
    Write-Ok "Connected as: $($me.full_name) ($($me.email))"
} catch {
    Fail "Konnect API call failed — check PAT and region. Error: $_"
}

# ── Step 1: Find consumer ─────────────────────────────────────────────────────
Write-Info ""
Write-Info "Step 1 — Looking up consumer '$ConsumerName'..."
$consumers = (Invoke-K -Method GET -Path "$cpBase/consumers?size=1000").data
$consumer  = $consumers | Where-Object { $_.username -eq $ConsumerName } | Select-Object -First 1
if (-not $consumer) {
    Fail "Consumer '$ConsumerName' not found in control plane $ControlPlaneId. Have routes been provisioned?"
}
Write-Ok "Found consumer: $ConsumerName → $($consumer.id)"

# ── Step 2: List existing key-auth credentials ────────────────────────────────
Write-Info ""
Write-Info "Step 2 — Listing existing key-auth credentials..."
$existingCreds = (Invoke-K -Method GET -Path "$cpBase/consumers/$($consumer.id)/key-auth?size=1000").data
Write-Info "Found $($existingCreds.Count) existing credential(s)."

# ── Step 3: Delete old credentials ───────────────────────────────────────────
Write-Info ""
Write-Info "Step 3 — Deleting old credential(s)..."
if ($existingCreds.Count -eq 0) {
    Write-Warn "No existing credentials to delete."
} else {
    foreach ($cred in $existingCreds) {
        if ($PSCmdlet.ShouldProcess("credential $($cred.id)", 'DELETE')) {
            Invoke-K -Method DELETE -Path "$cpBase/consumers/$($consumer.id)/key-auth/$($cred.id)" | Out-Null
            Write-Ok "Deleted credential: $($cred.id)"
        }
    }
}

# ── Step 4: Create new credential ────────────────────────────────────────────
Write-Info ""
Write-Info "Step 4 — Creating new key-auth credential..."
$newCred = $null
if ($PSCmdlet.ShouldProcess("$ConsumerName", 'Create new key-auth credential')) {
    $newCred = Invoke-K -Method POST -Path "$cpBase/consumers/$($consumer.id)/key-auth" -Body @{
        key  = $NewKey
        tags = @('foundry', 'mcp', 'rotated')
    }
    Write-Ok "Created new credential: $($newCred.id)"
}

# ── Step 5: Write api-key-config.json ────────────────────────────────────────
Write-Info ""
Write-Info "Step 5 — Writing key config to: $SaveKeyTo"
if ($PSCmdlet.ShouldProcess($SaveKeyTo, 'Write key config JSON')) {
    $config = [ordered]@{
        description         = "Kong key-auth credential for foundry-mcp-client"
        consumer            = $ConsumerName
        header_name         = "X-API-Key"
        api_key             = $NewKey
        sse_endpoint        = $SseEndpoint
        msg_endpoint        = $MsgEndpoint
        rotated_at          = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
        konnect_cred_id     = if ($newCred) { $newCred.id } else { 'dry-run' }
        note                = "DO NOT COMMIT. Listed in .gitignore. Treat as a password — rotate every 90 days."
        foundry_connection  = [ordered]@{
            server_url         = $SseEndpoint
            auth_type          = "Key-based authentication"
            credential_name    = "X-API-Key"
            credential_value   = $NewKey
        }
    }
    $config | ConvertTo-Json -Depth 5 | Set-Content -Path $SaveKeyTo -Encoding UTF8
    Write-Ok "Key config written to: $SaveKeyTo"
}

# ── Step 6: Smoke-test new key ────────────────────────────────────────────────
Write-Info ""
if ($SkipSmokeTest) {
    Write-Warn "Step 6 — Smoke-test SKIPPED (use -SkipSmokeTest to skip)."
} else {
    Write-Info "Step 6 — Smoke-testing new key against $SseEndpoint ..."
    Write-Info "  (Waiting 3s for Konnect data-plane propagation...)"
    Start-Sleep -Seconds 3

    try {
        $response = Invoke-WebRequest -Uri $SseEndpoint `
            -Headers @{ 'X-API-Key' = $NewKey; 'Accept' = 'text/event-stream' } `
            -Method GET -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop
        Write-Ok "Smoke-test PASSED — HTTP $($response.StatusCode)"
    } catch [System.Net.WebException] {
        $status = [int]$_.Exception.Response.StatusCode
        if ($status -eq 401 -or $status -eq 403) {
            Write-Warn "Smoke-test returned $status — key may not have propagated yet. Retry in ~10s."
            Write-Warn "Command: curl -H 'X-API-Key: $NewKey' '$SseEndpoint'"
        } elseif ($status -ge 200 -and $status -lt 300) {
            Write-Ok "Smoke-test PASSED — HTTP $status"
        } else {
            Write-Warn "Smoke-test returned $status — check gateway status."
        }
    } catch {
        # SSE connections often close immediately on the client side — a successful headers-only response is fine
        if ($_ -match '200') {
            Write-Ok "Smoke-test PASSED (SSE connection established)"
        } else {
            Write-Warn "Smoke-test inconclusive: $_"
            Write-Warn "Manual check: curl -H 'X-API-Key: $NewKey' '$SseEndpoint'"
        }
    }
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Info ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " KEY ROTATION COMPLETE" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Consumer    : $ConsumerName" -ForegroundColor Cyan
Write-Host " New API Key : $NewKey" -ForegroundColor Cyan
Write-Host " SSE URL     : $SseEndpoint" -ForegroundColor Cyan
Write-Host " Config file : $SaveKeyTo" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Update your Foundry project connection with the new key above." -ForegroundColor Yellow
