# Test MCP Gateway - List Available Tools
# Shows how to discover tools from the MCP server

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('jwt', 'key', 'oauth')]
    [string]$AuthType = 'key'
)

$GatewayUrl = "https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io"

Write-Host "🔍 MCP Tool Discovery Test" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host ""

# Setup authentication based on type
switch ($AuthType) {
    'jwt' {
        Write-Host "Authentication: JWT Bearer Token" -ForegroundColor Yellow
        $SseUrl = "$GatewayUrl/mcp/sse"
        $MessagesUrl = "$GatewayUrl/mcp/messages"
        
        # Generate JWT token
        $JWT = & node -e "const jwt = require('jsonwebtoken'); console.log(jwt.sign({ iss: 'kong-poc', exp: Math.floor(Date.now() / 1000) + 3600 }, 'poc-secret-change-me', { algorithm: 'HS256' }));"
        $Headers = @{
            "Authorization" = "Bearer $JWT"
            "Content-Type" = "application/json"
        }
    }
    'key' {
        Write-Host "Authentication: API Key (X-API-Key)" -ForegroundColor Yellow
        $SseUrl = "$GatewayUrl/mcp/key/sse"
        $MessagesUrl = "$GatewayUrl/mcp/key/messages"
        
        $config = Get-Content "api-key-config.json" -ErrorAction SilentlyContinue | ConvertFrom-Json
        if ($config) {
            $ApiKey = $config.api_key
        } else {
            $ApiKey = "e2ba9eeb0233bb3df9058ada8fbb76d4ffa53afa79e7bf6f04c74b5f68777d43"
        }
        
        $Headers = @{
            "X-API-Key" = $ApiKey
            "Content-Type" = "application/json"
        }
    }
    'oauth' {
        Write-Host "Authentication: OAuth (use Foundry - manual token needed)" -ForegroundColor Yellow
        Write-Host "OAuth requires interactive login - use Foundry UI for testing" -ForegroundColor Red
        Write-Host ""
        exit
    }
}

Write-Host "SSE Endpoint: $SseUrl" -ForegroundColor White
Write-Host "Messages Endpoint: $MessagesUrl" -ForegroundColor White
Write-Host ""

# Step 1: Connect to SSE endpoint to get session info
Write-Host "Step 1: Connecting to SSE endpoint..." -ForegroundColor Cyan
Write-Host ""

try {
    # Quick test - just verify we can connect (don't actually wait for SSE stream)
    $response = Invoke-WebRequest -Uri $SseUrl -Headers $Headers -TimeoutSec 5 -Method GET -ErrorAction Stop
    Write-Host "✅ SSE connection successful (200 OK)" -ForegroundColor Green
    Write-Host "   Content-Type: $($response.Headers['Content-Type'])" -ForegroundColor Gray
} catch {
    Write-Host "❌ SSE connection failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Step 2: List available tools
Write-Host "Step 2: Requesting tool list..." -ForegroundColor Cyan
Write-Host ""

$toolsRequest = @{
    jsonrpc = "2.0"
    id = 1
    method = "tools/list"
    params = @{}
} | ConvertTo-Json -Depth 10

try {
    $response = Invoke-RestMethod -Uri $MessagesUrl -Method POST -Headers $Headers -Body $toolsRequest
    
    if ($response.result.tools) {
        Write-Host "✅ Found $($response.result.tools.Count) tool(s):" -ForegroundColor Green
        Write-Host ""
        
        foreach ($tool in $response.result.tools) {
            Write-Host "  📦 $($tool.name)" -ForegroundColor Cyan
            Write-Host "     $($tool.description)" -ForegroundColor Gray
            if ($tool.inputSchema.properties) {
                Write-Host "     Parameters:" -ForegroundColor Yellow
                foreach ($param in $tool.inputSchema.properties.PSObject.Properties) {
                    $required = if ($tool.inputSchema.required -contains $param.Name) { " (required)" } else { "" }
                    Write-Host "       - $($param.Name): $($param.Value.type)$required" -ForegroundColor White
                    if ($param.Value.description) {
                        Write-Host "         $($param.Value.description)" -ForegroundColor Gray
                    }
                }
            }
            Write-Host ""
        }
    } else {
        Write-Host "⚠️  No tools found" -ForegroundColor Yellow
    }
    
} catch {
    Write-Host "❌ Tool list request failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) {
        Write-Host "   $($_.ErrorDetails.Message)" -ForegroundColor Red
    }
    exit 1
}

Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
Write-Host ""
Write-Host "💡 To test a tool, use:" -ForegroundColor Yellow
Write-Host "   .\scripts\test-mcp-tool-call.ps1 -Tool get_weather -Params @{location='Seattle'} -AuthType $AuthType" -ForegroundColor White
Write-Host ""
