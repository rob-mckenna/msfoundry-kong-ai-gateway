targetScope = 'resourceGroup'

param location string = resourceGroup().location
param namePrefix string = 'kongai'
param containerImage string
param acrName string
param containerAppEnvId string
param mockApiUrl string = 'https://kongai-mock-api.internal.graycoast-a8631da5.eastus2.azurecontainerapps.io'

var containerAppName = toLower('${namePrefix}-mcp-server')

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource mcpServerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: containerAppEnvId
    configuration: {
      ingress: {
        external: false
        targetPort: 8080
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
      secrets: [
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'mcp-server'
          image: containerImage
          env: [
            {
              name: 'PORT'
              value: '8080'
            }
            {
              name: 'MOCK_API_URL'
              value: mockApiUrl
            }
          ]
          probes: [
            {
              type: 'liveness'
              httpGet: {
                path: '/health'
                port: 8080
                httpHeaders: []
              }
              initialDelaySeconds: 30
              periodSeconds: 10
            }
            {
              type: 'readiness'
              httpGet: {
                path: '/health'
                port: 8080
                httpHeaders: []
              }
              initialDelaySeconds: 30
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

output containerAppName string = mcpServerApp.name
output containerAppFqdn string = mcpServerApp.properties.configuration.ingress.fqdn
