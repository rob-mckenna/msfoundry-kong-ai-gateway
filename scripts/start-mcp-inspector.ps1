# Start MCP Inspector with API Key auth
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('jwt', 'key')]
    [string]$AuthType = 'key',
    
    [Parameter(Mandatory=$false)]
    [int]$Port = 6274
)

$GatewayUrl = "https://kongai-gw.graycoast-a8631da5.eastus2.azurecontainerapps.io"

Write-Host "🔍 MCP Inspector Launcher" -ForegroundColor Cyan
Write-Host "=========================" -ForegroundColor Cyan
Write-Host ""

switch ($AuthType) {
    'key' {
        $config = Get-Content "api-key-config.json" -ErrorAction SilentlyContinue | ConvertFrom-Json
        if (-not $config) {
            Write-Host "❌ api-key-config.json not found" -ForegroundColor Red
            Write-Host "   Run Phase 1 of key-auth migration first" -ForegroundColor Yellow
            exit 1
        }
        
        $ApiKey = $config.api_key
        
        Write-Host "Authentication: API Key (X-API-Key)" -ForegroundColor Yellow
        Write-Host "Endpoint: $GatewayUrl/mcp/key/sse" -ForegroundColor White
        Write-Host "Port: $Port" -ForegroundColor White
        Write-Host ""
        Write-Host "Starting Inspector..." -ForegroundColor Green
        Write-Host ""
        
        npx @modelcontextprotocol/inspector sse "$GatewayUrl/mcp/key/sse" `
            --header "X-API-Key: $ApiKey" `
            --port $Port
    }
    'jwt' {
        Write-Host "Authentication: JWT Bearer Token" -ForegroundColor Yellow
        Write-Host "Endpoint: $GatewayUrl/mcp/sse" -ForegroundColor White
        Write-Host "Port: $Port" -ForegroundColor White
        Write-Host ""
        
        # Check if jsonwebtoken is available
        $jwtTest = node -e "try { require('jsonwebtoken'); console.log('ok'); } catch { console.log('missing'); }" 2>$null
        if ($jwtTest -ne 'ok') {
            Write-Host "❌ jsonwebtoken package not found" -ForegroundColor Red
            Write-Host "   Run: npm install jsonwebtoken" -ForegroundColor Yellow
            exit 1
        }
        
        Write-Host "Generating JWT token..." -ForegroundColor Green
        $JWT = node -e "const jwt = require('jsonwebtoken'); console.log(jwt.sign({ iss: 'kong-poc', exp: Math.floor(Date.now() / 1000) + 3600 }, 'poc-secret-change-me', { algorithm: 'HS256' }));"
        
        if (-not $JWT) {
            Write-Host "❌ Failed to generate JWT" -ForegroundColor Red
            exit 1
        }
        
        Write-Host "Token generated (expires in 1 hour)" -ForegroundColor Green
        Write-Host ""
        Write-Host "Starting Inspector..." -ForegroundColor Green
        Write-Host ""
        
        npx @modelcontextprotocol/inspector sse "$GatewayUrl/mcp/sse" `
            --header "Authorization: Bearer $JWT" `
            --port $Port
    }
}
