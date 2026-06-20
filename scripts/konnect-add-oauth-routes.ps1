[CmdletBinding()]
param(
    [string]$Pat = $env:KONNECT_PAT,
    [Parameter(Mandatory = $true)]
    [string]$ControlPlaneId,
    [Parameter(Mandatory = $true)]
    [string]$EntraTenantId,
    # The OAuth client app registered in Entra (used by Kong to validate tokens)
    [Parameter(Mandatory = $true)]
    [string]$EntraClientId,
    # The resource/API app registration whose audience the token must carry.
    # Entra issues tokens with aud = "api://<id>"; Kong is configured to accept
    # both "api://<id>" and the bare GUID so either format validates correctly.
    [Parameter(Mandatory = $true)]
    [string]$EntraResourceAppId,
    [string]$Region = $(if ($env:KONNECT_REGION) { $env:KONNECT_REGION } else { 'us' }),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$OAuthServiceName = 'mcp-oauth-service'
$OAuthSseRouteName = 'mcp-oauth-sse'
$OAuthMessagesRouteName = 'mcp-oauth-messages'
$OAuthMessagesPath = '/mcp/oauth/messages'

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" }
function Fail([string]$Message) { throw "[ERROR] $Message" }

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Fail "Required command not found: $Name"
    }
}

function Get-KonnectApiBase([string]$Geo) {
    switch ($Geo) {
        'us' { 'https://us.api.konghq.com' }
        'eu' { 'https://eu.api.konghq.com' }
        'au' { 'https://au.api.konghq.com' }
        'in' { 'https://in.api.konghq.com' }
        'me' { 'https://me.api.konghq.com' }
        default { Fail "Unsupported region '$Geo'." }
    }
}

function Invoke-KonnectApi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [object]$Body
    )

    $headers = @{ Authorization = "Bearer $Pat" }
    $uri = "$script:KonnectApiBase$Path"

    if ($null -ne $Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 10)
    }

    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

if ([string]::IsNullOrWhiteSpace($Pat)) {
    Fail 'Provide -Pat or set KONNECT_PAT.'
}

Require-Command 'curl'
Require-Command 'kongctl'

$script:KonnectApiBase = Get-KonnectApiBase $Region
$env:KONGCTL_DEFAULT_KONNECT_PAT = $Pat

if (-not $DryRun) {
    & kongctl get me | Out-Null
}

$services = Invoke-KonnectApi -Method GET -Path "/v2/control-planes/$ControlPlaneId/core-entities/services"
$mcpService = @($services.data | Where-Object { $_.name -eq 'mcp-service' })[0]
if (-not $mcpService) {
    Fail 'The mcp-service service was not found. Run the sync script first.'
}
$oauthService = @($services.data | Where-Object { $_.name -eq $OAuthServiceName })[0]

if (-not $oauthService -and -not $DryRun) {
    $oauthService = Invoke-KonnectApi -Method POST -Path "/v2/control-planes/$ControlPlaneId/core-entities/services" -Body @{
        name = $OAuthServiceName
        host = $mcpService.host
        protocol = $mcpService.protocol
        port = $mcpService.port
    }
}

if ($DryRun) {
    Write-Info "Would create $OAuthServiceName mirroring mcp-service ($($mcpService.id)) for auth isolation."
    Write-Info "Would create /mcp/oauth/sse and /mcp/oauth/messages routes on $OAuthServiceName."
    Write-Info "Would attach pre-function path rewrites, openid-connect bearer validation (audience: api://$EntraResourceAppId OR $EntraResourceAppId), and route-level CORS."
    return
}

$routes = Invoke-KonnectApi -Method GET -Path "/v2/control-planes/$ControlPlaneId/core-entities/routes"
$oauthSseRoute = @($routes.data | Where-Object { $_.name -eq $OAuthSseRouteName })[0]
$oauthMessagesRoute = @($routes.data | Where-Object { $_.name -eq $OAuthMessagesRouteName })[0]

if (-not $oauthSseRoute) {
    $oauthSseRoute = Invoke-KonnectApi -Method POST -Path "/v2/control-planes/$ControlPlaneId/core-entities/routes" -Body @{
        name = $OAuthSseRouteName
        service = @{ id = $oauthService.id }
        paths = @('/mcp/oauth/sse')
        methods = @('GET', 'OPTIONS')
        strip_path = $false
        preserve_host = $false
    }
}

if (-not $oauthMessagesRoute) {
    $oauthMessagesRoute = Invoke-KonnectApi -Method POST -Path "/v2/control-planes/$ControlPlaneId/core-entities/routes" -Body @{
        name = $OAuthMessagesRouteName
        service = @{ id = $oauthService.id }
        paths = @('/mcp/oauth/messages')
        methods = @('POST', 'OPTIONS')
        strip_path = $false
        preserve_host = $false
    }
}

$plugins = Invoke-KonnectApi -Method GET -Path "/v2/control-planes/$ControlPlaneId/core-entities/plugins"
$issuer = "https://login.microsoftonline.com/$EntraTenantId/v2.0"
$pluginConfig = @{
    issuer = $issuer
    client_id = @($EntraClientId)
    auth_methods = @('bearer')
    # Accept both audience formats: Entra issues "api://<id>"; also accept bare GUID as fallback
    audience_required = @("api://$EntraResourceAppId", $EntraResourceAppId)
    scopes = @()
    scopes_required = @()
    bearer_token_param_type = @('header')
    consumer_optional = $false
    upstream_headers_claims = @('oid', 'preferred_username', 'name')
    upstream_headers_names = @('x-user-oid', 'x-user-upn', 'x-user-name')
}

function Get-RoutePlugin([object[]]$PluginData, [string]$PluginName, [string]$RouteId) {
    @($PluginData | Where-Object { $_.name -eq $PluginName -and $_.route.id -eq $RouteId })[0]
}

if (-not (Get-RoutePlugin -PluginData $plugins.data -PluginName 'pre-function' -RouteId $oauthSseRoute.id)) {
    [void](Invoke-KonnectApi -Method POST -Path "/v2/control-planes/$ControlPlaneId/core-entities/plugins" -Body @{
        name = 'pre-function'
        route = @{ id = $oauthSseRoute.id }
        config = @{
            access = @(
                "kong.service.request.set_path('/mcp/sse')",
                "kong.service.request.set_header('x-external-mcp-messages-path', '$OAuthMessagesPath')"
            )
        }
    })
}

if (-not (Get-RoutePlugin -PluginData $plugins.data -PluginName 'pre-function' -RouteId $oauthMessagesRoute.id)) {
    [void](Invoke-KonnectApi -Method POST -Path "/v2/control-planes/$ControlPlaneId/core-entities/plugins" -Body @{
        name = 'pre-function'
        route = @{ id = $oauthMessagesRoute.id }
        config = @{
            access = @(
                "kong.service.request.set_path('/mcp/messages')"
            )
        }
    })
}

foreach ($route in @($oauthSseRoute, $oauthMessagesRoute)) {
    $oidcPlugin = Get-RoutePlugin -PluginData $plugins.data -PluginName 'openid-connect' -RouteId $route.id
    if (-not $oidcPlugin) {
        [void](Invoke-KonnectApi -Method POST -Path "/v2/control-planes/$ControlPlaneId/core-entities/plugins" -Body @{
            name = 'openid-connect'
            route = @{ id = $route.id }
            config = $pluginConfig
        })
    } else {
        # Konnect v2 does not support PATCH — GET the full object, update config, PUT it back.
        $fullPlugin = Invoke-KonnectApi -Method GET -Path "/v2/control-planes/$ControlPlaneId/core-entities/plugins/$($oidcPlugin.id)"
        $putBody = @{
            name      = $fullPlugin.name
            enabled   = $fullPlugin.enabled
            config    = $pluginConfig
            protocols = $fullPlugin.protocols
        }
        if ($fullPlugin.route)    { $putBody.route    = @{ id = $fullPlugin.route.id }    }
        if ($fullPlugin.service)  { $putBody.service  = @{ id = $fullPlugin.service.id }  }
        if ($fullPlugin.consumer) { $putBody.consumer = @{ id = $fullPlugin.consumer.id } }
        if ($fullPlugin.tags)     { $putBody.tags     = $fullPlugin.tags }
        [void](Invoke-KonnectApi -Method PUT -Path "/v2/control-planes/$ControlPlaneId/core-entities/plugins/$($oidcPlugin.id)" -Body $putBody)
    }

    if (-not (Get-RoutePlugin -PluginData $plugins.data -PluginName 'cors' -RouteId $route.id)) {
        $methods = if ($route.id -eq $oauthSseRoute.id) { @('GET', 'OPTIONS') } else { @('POST', 'OPTIONS') }
        $corsConfig = @{
            origins = @('*')
            methods = $methods
            headers = @('Accept', 'Authorization', 'Content-Type')
            credentials = $true
            max_age = 3600
        }

        if ($route.id -eq $oauthSseRoute.id) {
            $corsConfig.exposed_headers = @('X-Auth-Token')
        }

        [void](Invoke-KonnectApi -Method POST -Path "/v2/control-planes/$ControlPlaneId/core-entities/plugins" -Body @{
            name = 'cors'
            route = @{ id = $route.id }
            config = $corsConfig
        })
    }
}

Write-Info 'OAuth routes created.'
Write-Info 'Validate with GET /mcp/oauth/sse and POST /mcp/oauth/messages?sessionId=...'
