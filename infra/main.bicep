targetScope = 'resourceGroup'

param location string = resourceGroup().location
param namePrefix string = 'kongai'
// Required: must be a fully-qualified image reference in ACR (e.g. <acr>.azurecr.io/kong-ai-gw:1.0)
param containerImage string
param acrName string
param containerAppEnvId string
@secure()
param openAiApiKey string = ''

var containerAppName = toLower('${namePrefix}-gw')

// Reference the ACR created by acr.bicep — admin credentials used for POC simplicity
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
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
              name: 'KONG_DATABASE'
              value: 'off'
            }
            {
              name: 'KONG_DECLARATIVE_CONFIG'
              value: '/etc/kong/kong.yaml'
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
