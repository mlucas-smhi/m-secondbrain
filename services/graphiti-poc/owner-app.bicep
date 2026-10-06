targetScope = 'resourceGroup'
param environmentId string
param mcpImage string
param gatewayImage string
param transportImage string
param registryServer string
param registryIdentityId string
@secure()
param databasePassword string
@secure()
param mcpEdgeToken string
@secure()
param openaiApiKey string
@secure()
param databaseCaPem string
param extractionModel string
param embeddingModel string

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'eleven-owner-graphiti'
  location: resourceGroup().location
  tags: { purpose: 'eleven-owner-memory', stage: 'preseed' }
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${registryIdentityId}': {} } }
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: { external: true, allowInsecure: false, targetPort: 8080, transport: 'auto' }
      registries: [{ server: registryServer, identity: registryIdentityId }]
      secrets: [
        { name: 'database-password', value: databasePassword }
        { name: 'mcp-edge-token', value: mcpEdgeToken }
        { name: 'openai-api-key', value: openaiApiKey }
        { name: 'database-ca', value: databaseCaPem }
      ]
    }
    template: {
      terminationGracePeriodSeconds: 120
      containers: [
        {
          name: 'graphiti'
          image: mcpImage
          resources: { cpu: 1, memory: '2Gi' }
          env: [
            { name: 'FALKORDB_URI', value: 'redis://127.0.0.1:6380' }
            { name: 'FALKORDB_PASSWORD', secretRef: 'database-password' }
            { name: 'FALKORDB_DATABASE', value: 'eleven_owner_memory_v1' }
            { name: 'GRAPHITI_GROUP_ID', value: 'eleven_owner_memory_v1' }
            { name: 'MODEL_NAME', value: extractionModel }
            { name: 'EMBEDDER_MODEL', value: embeddingModel }
            { name: 'OPENAI_API_KEY', secretRef: 'openai-api-key' }
            { name: 'SEMAPHORE_LIMIT', value: '2' }
            { name: 'GRAPHITI_TELEMETRY_ENABLED', value: 'false' }
          ]
          probes: [
            { type: 'Startup', httpGet: { path: '/health', port: 8000 }, periodSeconds: 10, failureThreshold: 30 }
            { type: 'Readiness', httpGet: { path: '/health', port: 8000 }, periodSeconds: 10, failureThreshold: 3 }
          ]
        }
        {
          name: 'auth-gateway'
          image: gatewayImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [{ name: 'MCP_EDGE_TOKEN', secretRef: 'mcp-edge-token' }]
        }
        {
          name: 'database-tls'
          image: transportImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'DATABASE_TLS_HOST', value: '10.42.4.4' }
            { name: 'DATABASE_CA_PEM', secretRef: 'database-ca' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}
output mcpUrl string = 'https://${app.properties.configuration.ingress.fqdn}/mcp'
