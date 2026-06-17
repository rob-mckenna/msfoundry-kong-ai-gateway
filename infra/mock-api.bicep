targetScope = 'resourceGroup'

param location string = resourceGroup().location
param namePrefix string = 'kongai'
param containerImage string
param acrName string
param containerAppEnvId string

var containerAppName = toLower('${namePrefix}-mock-api')

// Reference the ACR created by acr.bicep
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource mockApiApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: containerAppEnvId
    configuration: {
      ingress: {
        external: false  // Internal-only ingress
        targetPort: 3000
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
          name: 'mock-api'
          image: containerImage
          env: [
            {
              name: 'PORT'
              value: '3000'
            }
          ]
          probes: [
            {
              type: 'liveness'
              httpGet: {
                path: '/api/status'
                port: 3000
                httpHeaders: []
              }
              initialDelaySeconds: 30
              periodSeconds: 10
            }
            {
              type: 'readiness'
              httpGet: {
                path: '/api/status'
                port: 3000
                httpHeaders: []
              }
              initialDelaySeconds: 30
              periodSeconds: 10
            }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: '100'
              }
            }
          }
        ]
      }
    }
  }
}

output containerAppName string = mockApiApp.name
output containerAppFqdn string = mockApiApp.properties.configuration.ingress.fqdn
