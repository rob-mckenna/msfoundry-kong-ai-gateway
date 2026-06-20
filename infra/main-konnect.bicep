targetScope = 'resourceGroup'

param location string = resourceGroup().location
param namePrefix string = 'kongai'
param containerImage string
param acrName string
param containerAppEnvId string
param keyVaultName string
param kongClusterControlPlane string
param kongClusterTelemetryEndpoint string
@secure()
param openAiApiKey string = ''

var containerAppName = toLower('${namePrefix}-gw')
var normalizedClusterControlPlaneBase = replace(replace(kongClusterControlPlane, 'https://', ''), 'http://', '')
var normalizedClusterTelemetryEndpointBase = replace(replace(kongClusterTelemetryEndpoint, 'https://', ''), 'http://', '')
var normalizedClusterControlPlane = contains(normalizedClusterControlPlaneBase, ':') ? normalizedClusterControlPlaneBase : '${normalizedClusterControlPlaneBase}:443'
var normalizedClusterTelemetryEndpoint = contains(normalizedClusterTelemetryEndpointBase, ':') ? normalizedClusterTelemetryEndpointBase : '${normalizedClusterTelemetryEndpointBase}:443'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' existing = {
  name: keyVaultName
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: containerAppEnvId
    configuration: {
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
        traffic: [
          {
            weight: 100
            latestRevision: true
          }
        ]
      }
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: concat([
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
        {
          name: 'kong-cluster-cert'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/kong-cluster-cert'
          identity: 'system'
        }
        {
          name: 'kong-cluster-key'
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/kong-cluster-key'
          identity: 'system'
        }
      ], length(openAiApiKey) > 0 ? [
        {
          name: 'openai-api-key'
          value: openAiApiKey
        }
      ] : [])
    }
    template: {
      containers: [
        {
          name: 'kong'
          image: containerImage
          env: concat([
            {
              name: 'KONG_ROLE'
              value: 'data_plane'
            }
            {
              name: 'KONG_DATABASE'
              value: 'off'
            }
            {
              name: 'KONG_CLUSTER_MTLS'
              value: 'pki'
            }
            {
              name: 'KONG_KONNECT_MODE'
              value: 'on'
            }
            {
              name: 'KONG_LUA_SSL_TRUSTED_CERTIFICATE'
              value: 'system'
            }
            {
              name: 'KONG_CLUSTER_CONTROL_PLANE'
              value: normalizedClusterControlPlane
            }
            {
              name: 'KONG_CLUSTER_TELEMETRY_ENDPOINT'
              value: normalizedClusterTelemetryEndpoint
            }
            {
              name: 'KONG_CLUSTER_CERT'
              secretRef: 'kong-cluster-cert'
            }
            {
              name: 'KONG_CLUSTER_CERT_KEY'
              secretRef: 'kong-cluster-key'
            }
            {
              name: 'KONG_PROXY_ACCESS_LOG'
              value: '/dev/stdout'
            }
            {
              name: 'KONG_PROXY_ERROR_LOG'
              value: '/dev/stderr'
            }
            {
              name: 'KONG_STATUS_LISTEN'
              value: '0.0.0.0:8100'
            }
            {
              name: 'KONG_ADMIN_LISTEN'
              value: 'off'
            }
            {
              name: 'KONG_UNTRUSTED_LUA'
              value: 'on'
            }
            {
              name: 'KONG_PROXY_BUFFERING'
              value: 'off'
            }
            {
              name: 'KONG_NGINX_HTTP_PROXY_BUFFERING'
              value: 'off'
            }
            {
              name: 'KONG_NGINX_PROXY_PROXY_SEND_TIMEOUT'
              value: '600s'
            }
            {
              name: 'KONG_NGINX_PROXY_PROXY_READ_TIMEOUT'
              value: '600s'
            }
          ], length(openAiApiKey) > 0 ? [
            {
              name: 'OPENAI_API_KEY'
              secretRef: 'openai-api-key'
            }
          ] : [])
          probes: [
            {
              type: 'liveness'
              httpGet: {
                path: '/status'
                port: 8100
                httpHeaders: []
              }
              initialDelaySeconds: 60
              periodSeconds: 10
            }
            {
              type: 'readiness'
              httpGet: {
                path: '/status'
                port: 8100
                httpHeaders: []
              }
              initialDelaySeconds: 60
              periodSeconds: 10
            }
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 5
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: '50'
              }
            }
          }
        ]
      }
    }
  }
}

output containerAppName string = containerApp.name
output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
