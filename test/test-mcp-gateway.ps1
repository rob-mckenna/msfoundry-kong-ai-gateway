[CmdletBinding()]
param(
    [string]$GatewayBaseUrl = $(if ($env:GATEWAY_BASE_URL) { $env:GATEWAY_BASE_URL } else { 'https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io' }),
    [string]$OpenAiModel = $(if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { 'gpt-4.1' }),
    [string]$JwtIssuer = $(if ($env:JWT_ISSUER) { $env:JWT_ISSUER } else { 'kong-poc' }),
    [string]$JwtSecret = $(if ($env:JWT_SECRET) { $env:JWT_SECRET } else { 'poc-secret-change-me' }),
    [string]$JwtSubject = $(if ($env:JWT_SUBJECT) { $env:JWT_SUBJECT } else { 'poc-user' }),
    [int]$JwtTtlSeconds = $(if ($env:JWT_TTL_SECONDS) { [int]$env:JWT_TTL_SECONDS } else { 3600 }),
    [int]$SseTimeoutSeconds = $(if ($env:SSE_TIMEOUT_SECONDS) { [int]$env:SSE_TIMEOUT_SECONDS } else { 20 }),
    [int]$MessageTimeoutSeconds = $(if ($env:MESSAGE_TIMEOUT_SECONDS) { [int]$env:MESSAGE_TIMEOUT_SECONDS } else { 60 }),
    [int]$ChatTimeoutSeconds = $(if ($env:CHAT_TIMEOUT_SECONDS) { [int]$env:CHAT_TIMEOUT_SECONDS } else { 60 }),
    [switch]$KeepTestArtifacts
)

$ErrorActionPreference = 'Stop'

$Script:PassCount = 0
$Script:FailCount = 0
$Script:SseJob = $null
$Script:SessionId = $null

$scriptDir = Split-Path -Parent $PSCommandPath
$tempDir = Join-Path $scriptDir ".tmp-mcp-gateway-$PID"
$sseRaw = Join-Path $tempDir 'sse-stream.txt'
$sseStdErr = Join-Path $tempDir 'sse-stderr.txt'
$invalidJsonFile = Join-Path $tempDir 'invalid-json.json'

New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

function Remove-TestArtifacts {
    if ($Script:SseJob) {
        try {
            Stop-Job -Job $Script:SseJob -ErrorAction SilentlyContinue | Out-Null
        } catch {
        }

        try {
            Receive-Job -Job $Script:SseJob -ErrorAction SilentlyContinue | Out-Null
        } catch {
        }

        try {
            Remove-Job -Job $Script:SseJob -Force -ErrorAction SilentlyContinue | Out-Null
        } catch {
        }
    }

    if (-not $KeepTestArtifacts.IsPresent -and (Test-Path $tempDir)) {
        Remove-Item -Path $tempDir -Recurse -Force
    }
}

trap {
    Remove-TestArtifacts
    throw
}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)

    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-JwtToken {
    param(
        [string]$Issuer,
        [string]$Subject,
        [string]$Secret,
        [int]$TtlSeconds
    )

    $headerJson = @{ alg = 'HS256'; typ = 'JWT' } | ConvertTo-Json -Compress
    $payloadJson = @{
        iss = $Issuer
        sub = $Subject
        exp = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $TtlSeconds
    } | ConvertTo-Json -Compress

    $headerPart = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($headerJson))
    $payloadPart = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payloadJson))
    $signingInput = "$headerPart.$payloadPart"

    $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($Secret))
    try {
        $signatureBytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($signingInput))
    } finally {
        $hmac.Dispose()
    }

    $signaturePart = ConvertTo-Base64Url $signatureBytes
    "$signingInput.$signaturePart"
}

$token = if ($env:JWT_TOKEN) { $env:JWT_TOKEN } else { New-JwtToken -Issuer $JwtIssuer -Subject $JwtSubject -Secret $JwtSecret -TtlSeconds $JwtTtlSeconds }
$invalidToken = if ($env:INVALID_JWT_TOKEN) { $env:INVALID_JWT_TOKEN } else { New-JwtToken -Issuer $JwtIssuer -Subject $JwtSubject -Secret "$JwtSecret-invalid" -TtlSeconds $JwtTtlSeconds }

function Write-Pass {
    param([string]$Message)
    $Script:PassCount++
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-Fail {
    param(
        [string]$Message,
        [string]$Detail
    )

    $Script:FailCount++
    Write-Host "[FAIL] $Message" -ForegroundColor Red
    if ($Detail) {
        Write-Host "       $Detail" -ForegroundColor DarkRed
    }
}

function Get-HttpStatus {
    param([string]$ResponseText)

    if (-not $ResponseText) {
        return $null
    }

    $statusLine = ($ResponseText -split "`r?`n" | Where-Object { $_ -match '^HTTP/' } | Select-Object -Last 1)
    if (-not $statusLine) {
        return $null
    }

    $parts = $statusLine -split '\s+'
    if ($parts.Length -ge 2) {
        return [int]$parts[1]
    }

    $null
}

function Get-SseText {
    if (-not (Test-Path $sseRaw)) {
        return ''
    }

    Get-Content -Path $sseRaw -Raw
}

function Get-SessionIdFromSse {
    param([string]$Content)

    if (-not $Content) {
        return $null
    }

    $match = [regex]::Match($Content, 'sessionId=([A-Za-z0-9-]+)')
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    $null
}

function Wait-ForSessionId {
    param([int]$TimeoutSeconds)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $sessionId = Get-SessionIdFromSse -Content (Get-SseText)
        if ($sessionId) {
            return $sessionId
        }

        Start-Sleep -Milliseconds 500
    }

    $null
}

function Wait-ForFileContent {
    param(
        [string]$Path,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $Path) -and (Get-Item $Path).Length -gt 0) {
            return $true
        }

        Start-Sleep -Milliseconds 500
    }

    $false
}

function Get-SseJsonRpcResponse {
    param(
        [string]$Content,
        [string]$RequestId
    )

    if (-not $Content) {
        return $null
    }

    $lines = $Content -split "`r?`n"
    foreach ($line in $lines) {
        if ($line -notlike 'data: {*') {
            continue
        }

        try {
            $json = $line.Substring(6) | ConvertFrom-Json -Depth 100
        } catch {
            continue
        }

        if ($null -ne $json.id -and "$($json.id)" -eq $RequestId) {
            return $json
        }
    }

    $null
}

function Wait-ForJsonRpcResponse {
    param(
        [string]$RequestId,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $response = Get-SseJsonRpcResponse -Content (Get-SseText) -RequestId $RequestId
        if ($response) {
            return $response
        }

        Start-Sleep -Milliseconds 500
    }

    $null
}

function Set-Utf8NoBomContent {
    param(
        [string]$Path,
        [string]$Value
    )

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Value, $utf8NoBom)
}

function Invoke-CurlRequest {
    param(
        [string]$Method,
        [string]$Url,
        [string]$BodyPath,
        [string]$Token,
        [string]$ContentType = 'application/json',
        [string]$Body,
        [string]$BodyFile,
        [int]$TimeoutSeconds = 20
    )

    $arguments = @('-sS', '--max-time', "$TimeoutSeconds", '-o', $BodyPath, '--write-out', '%{http_code}', '-X', $Method, $Url)

    if ($Token) {
        $arguments += @('-H', "Authorization: Bearer $Token")
    }

    if ($ContentType) {
        $arguments += @('-H', "Content-Type: $ContentType")
    }

    if ($BodyFile) {
        $arguments += @('--data-binary', "@$BodyFile")
    } elseif ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $inlineBodyFile = Join-Path $tempDir ("curl-body-{0}.json" -f ([guid]::NewGuid().ToString()))
        Set-Utf8NoBomContent -Path $inlineBodyFile -Value $Body
        $arguments += @('--data-binary', "@$inlineBodyFile")
    }

    $status = (& curl.exe @arguments)
    if ([string]::IsNullOrWhiteSpace($status)) {
        return $null
    }

    [int]($status.Trim())
}

function Send-McpRequest {
    param(
        [string]$RequestId,
        [string]$Payload,
        [string]$Prefix
    )

    $bodyPath = Join-Path $tempDir "$Prefix-body.txt"
    $status = Invoke-CurlRequest -Method 'POST' -Url "$GatewayBaseUrl/mcp/messages?sessionId=$Script:SessionId" -BodyPath $bodyPath -Token $token -Body $Payload -TimeoutSeconds $MessageTimeoutSeconds

    if ($status -notin 200, 202) {
        throw "Unexpected MCP POST status: $status"
    }

    if (-not $RequestId) {
        return $null
    }

    $response = Wait-ForJsonRpcResponse -RequestId $RequestId -TimeoutSeconds $MessageTimeoutSeconds
    if (-not $response) {
        throw "Timed out waiting for JSON-RPC response id $RequestId"
    }

    $response
}

Write-Host 'MCP Gateway test suite'
Write-Host "Base URL    : $GatewayBaseUrl"
Write-Host "OpenAI model: $OpenAiModel"
Write-Host ''

$invalidAuthHeaders = Join-Path $tempDir 'invalid-auth-headers.txt'
$invalidAuthBody = Join-Path $tempDir 'invalid-auth-body.txt'
$invalidAuthStatus = Invoke-CurlRequest -Method 'GET' -Url "$GatewayBaseUrl/mcp/sse" -BodyPath $invalidAuthBody -Token $invalidToken -ContentType '' -TimeoutSeconds 15

if ($invalidAuthStatus -in 401, 403) {
    Write-Pass 'Invalid JWT is rejected by /mcp/sse'
} else {
    Write-Fail 'Invalid JWT is rejected by /mcp/sse' "Expected HTTP 401/403, got $invalidAuthStatus"
}

$Script:SseJob = Start-Job -ScriptBlock {
    param($Url, $Token, $RawPath, $StdErrPath)
    if (Test-Path $RawPath) {
        Remove-Item $RawPath -Force
    }

    if (Test-Path $StdErrPath) {
        Remove-Item $StdErrPath -Force
    }

    $command = 'curl.exe -sS -N -i -H "Authorization: Bearer {0}" "{1}" > "{2}" 2> "{3}"' -f $Token, $Url, $RawPath, $StdErrPath
    & cmd.exe /d /s /c $command
} -ArgumentList "$GatewayBaseUrl/mcp/sse", $token, $sseRaw, $sseStdErr

$sseStatus = $null
if (Wait-ForFileContent -Path $sseRaw -TimeoutSeconds $SseTimeoutSeconds) {
    $sseStatus = Get-HttpStatus -ResponseText (Get-SseText)
}

if ($sseStatus -eq 200) {
    Write-Pass 'SSE endpoint accepts a valid JWT'
} else {
    Write-Fail 'SSE endpoint accepts a valid JWT' "Expected HTTP 200, got $sseStatus"
}

$Script:SessionId = Wait-ForSessionId -TimeoutSeconds $SseTimeoutSeconds
if ($Script:SessionId) {
    Write-Pass 'SSE handshake returns a sessionId'
} else {
    Write-Fail 'SSE handshake returns a sessionId' "Timed out waiting for sessionId in $sseRaw"
}

if ($Script:SessionId) {
    try {
        $initialize = Send-McpRequest -RequestId '1' -Payload '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcp-gateway-test","version":"1.0.0"}}}' -Prefix 'initialize'
        if ($initialize.jsonrpc -eq '2.0' -and $initialize.id -eq 1 -and $initialize.result.serverInfo.name -eq 'mock-api-mcp-server' -and $initialize.result.protocolVersion) {
            Write-Pass 'MCP initialize returns server metadata'
        } else {
            Write-Fail 'MCP initialize returns server metadata' 'Initialize response shape did not match expectations.'
        }
    } catch {
        Write-Fail 'MCP initialize returns server metadata' $_.Exception.Message
    }

    try {
        [void](Send-McpRequest -RequestId '' -Payload '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' -Prefix 'initialized-notification')
    } catch {
    }

    try {
        $toolList = Send-McpRequest -RequestId '2' -Payload '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' -Prefix 'tools-list'
        $toolNames = @($toolList.result.tools | ForEach-Object { $_.name })
        if ($toolList.jsonrpc -eq '2.0' -and $toolList.id -eq 2 -and $toolNames -contains 'get_weather' -and $toolNames -contains 'calculate') {
            Write-Pass 'tools/list returns get_weather and calculate'
        } else {
            Write-Fail 'tools/list returns get_weather and calculate' 'tools/list response was missing one or more expected tools.'
        }
    } catch {
        Write-Fail 'tools/list returns get_weather and calculate' $_.Exception.Message
    }

    try {
        $weather = Send-McpRequest -RequestId '3' -Payload '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_weather","arguments":{"location":"Seattle"}}}' -Prefix 'tool-weather'
        $structuredWeather = $weather.result.structuredContent
        if ($weather.jsonrpc -eq '2.0' -and $weather.id -eq 3 -and $structuredWeather.location -eq 'Seattle' -and $structuredWeather.PSObject.Properties.Name -contains 'temperature' -and $structuredWeather.PSObject.Properties.Name -contains 'condition') {
            Write-Pass 'tools/call get_weather returns structured weather data'
        } else {
            Write-Fail 'tools/call get_weather returns structured weather data' 'Weather tool response did not contain the expected fields.'
        }
    } catch {
        Write-Fail 'tools/call get_weather returns structured weather data' $_.Exception.Message
    }

    try {
        $calculate = Send-McpRequest -RequestId '4' -Payload '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"calculate","arguments":{"operation":"multiply","a":6,"b":7}}}' -Prefix 'tool-calculate'
        $structuredCalc = $calculate.result.structuredContent
        if ($calculate.jsonrpc -eq '2.0' -and $calculate.id -eq 4 -and $structuredCalc.operation -eq 'multiply' -and $structuredCalc.result -eq 42) {
            Write-Pass 'tools/call calculate returns the expected result'
        } else {
            Write-Fail 'tools/call calculate returns the expected result' 'Calculation tool response did not contain the expected result.'
        }
    } catch {
        Write-Fail 'tools/call calculate returns the expected result' $_.Exception.Message
    }
}

$missingSessionBody = Join-Path $tempDir 'missing-session-body.json'
$missingSessionStatus = Invoke-CurlRequest -Method 'POST' -Url "$GatewayBaseUrl/mcp/messages" -BodyPath $missingSessionBody -Token $token -Body '{"jsonrpc":"2.0","id":99,"method":"tools/list","params":{}}' -TimeoutSeconds $MessageTimeoutSeconds

try {
    $missingSessionJson = Get-Content -Path $missingSessionBody -Raw | ConvertFrom-Json
} catch {
    $missingSessionJson = $null
}

if ($missingSessionStatus -eq 400 -and $missingSessionJson -and $missingSessionJson.error -eq 'Missing sessionId query parameter') {
    Write-Pass 'Missing sessionId is rejected with HTTP 400'
} else {
    Write-Fail 'Missing sessionId is rejected with HTTP 400' 'Expected HTTP 400 and missing sessionId error.'
}

if ($Script:SessionId) {
    Set-Content -Path $invalidJsonFile -Value '{"jsonrpc":' -NoNewline
    $invalidJsonBody = Join-Path $tempDir 'invalid-json-body.json'
    $invalidJsonStatus = Invoke-CurlRequest -Method 'POST' -Url "$GatewayBaseUrl/mcp/messages?sessionId=$Script:SessionId" -BodyPath $invalidJsonBody -Token $token -BodyFile $invalidJsonFile -TimeoutSeconds $MessageTimeoutSeconds

    try {
        $invalidJsonResponse = Get-Content -Path $invalidJsonBody -Raw | ConvertFrom-Json
    } catch {
        $invalidJsonResponse = $null
    }

    if ($invalidJsonStatus -in 400, 500 -and $invalidJsonResponse -and $invalidJsonResponse.error) {
        Write-Pass 'Invalid JSON is rejected with an error response'
    } else {
        Write-Fail 'Invalid JSON is rejected with an error response' 'Expected HTTP 400/500 and JSON error payload.'
    }
}

$chatBody = Join-Path $tempDir 'chat-body.json'
$chatPayload = @{ model = $OpenAiModel; messages = @(@{ role = 'user'; content = 'Reply with: gateway ok' }) } | ConvertTo-Json -Compress -Depth 10
$chatStatus = Invoke-CurlRequest -Method 'POST' -Url "$GatewayBaseUrl/chat" -BodyPath $chatBody -Token $token -Body $chatPayload -TimeoutSeconds $ChatTimeoutSeconds

$chatRaw = if (Test-Path $chatBody) { Get-Content -Path $chatBody -Raw } else { '' }
if ($chatStatus -eq 200 -and $chatRaw -match '"choices"\s*:' -and $chatRaw.ToLowerInvariant().Contains('gateway ok')) {
    Write-Pass 'Azure OpenAI /chat returns a valid completion'
} else {
    Write-Fail 'Azure OpenAI /chat returns a valid completion' "Expected HTTP 200 and a completion containing 'gateway ok'; got status $chatStatus"
}

Write-Host ''
Write-Host "Passed: $Script:PassCount"
Write-Host "Failed: $Script:FailCount"

Remove-TestArtifacts

if ($Script:FailCount -gt 0) {
    exit 1
}
