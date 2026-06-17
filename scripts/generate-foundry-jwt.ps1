<#
.SYNOPSIS
Generates a JWT for the Kong MCP Gateway so it can be pasted into a Microsoft Foundry project connection.

.EXAMPLE
.\scripts\generate-foundry-jwt.ps1

.EXAMPLE
.\scripts\generate-foundry-jwt.ps1 -TtlSeconds 3600 -Issuer kong-poc -Subject foundry-poc

.NOTES
Environment variable overrides:
  KONG_JWT_SECRET or JWT_SECRET   HMAC secret (default: poc-secret-change-me)
  JWT_ISSUER                      issuer claim (default: kong-poc)
  JWT_TTL_SECONDS                 token lifetime in seconds (default: 3600)
  JWT_SUBJECT                     optional subject claim

Output is the plain JWT token only. In Foundry, paste it as:
  Bearer <token>
#>
[CmdletBinding()]
param(
    [int]$TtlSeconds = $(if ($env:JWT_TTL_SECONDS) { [int]$env:JWT_TTL_SECONDS } else { 3600 }),
    [string]$Issuer = $(if ($env:JWT_ISSUER) { $env:JWT_ISSUER } else { 'kong-poc' }),
    [string]$Subject = $(if ($env:JWT_SUBJECT) { $env:JWT_SUBJECT } else { '' }),
    [string]$Secret = $(if ($env:KONG_JWT_SECRET) { $env:KONG_JWT_SECRET } elseif ($env:JWT_SECRET) { $env:JWT_SECRET } else { 'poc-secret-change-me' })
)

$ErrorActionPreference = 'Stop'

if ($TtlSeconds -le 0) {
    throw 'TtlSeconds must be a positive integer.'
}

$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCommand) {
    $pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
}

if (-not $pythonCommand) {
    throw 'Python 3 is required.'
}

$pythonScript = @'
import sys
import time

try:
    import jwt
except ImportError as exc:
    raise SystemExit("PyJWT is required to generate the Foundry JWT.") from exc

issuer, secret, ttl, subject = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]

payload = {
    "iss": issuer,
    "exp": int(time.time()) + ttl,
}

if subject:
    payload["sub"] = subject

token = jwt.encode(payload, secret, algorithm="HS256")
print(token if isinstance(token, str) else token.decode())
'@

$pythonScript | & $pythonCommand.Source - $Issuer $Secret $TtlSeconds $Subject
