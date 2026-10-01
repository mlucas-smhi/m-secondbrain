targetScope = 'resourceGroup'
param location string = resourceGroup().location
param appName string = 'graphiti-cookoff-mcp'
param environmentId string
@description('Digest-pinned images built from this directory.')
param mcpImage string
param gatewayImage string
param registryServer string
@description('Managed identity with AcrPull on the build registry.')
param registryIdentityId string
param databaseUri string = 'redis://10.42.4.4:6379'
@secure()
param databasePassword string
@secure()
@minLength(64)
param mcpEdgeToken string
@secure()
param openaiApiKey string
@description('Explicit selection required; no silent upstream model default.')
param extractionModel string
param embeddingModel string = 'text-embedding-3-small'

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: { purpose: 'synthetic-memory-cookoff', production: 'false' }
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
            { name: 'FALKORDB_URI', value: databaseUri }
            { name: 'FALKORDB_PASSWORD', secretRef: 'database-password' }
            { name: 'FALKORDB_DATABASE', value: 'ea_memory_cookoff_v1' }
            { name: 'GRAPHITI_GROUP_ID', value: 'ea_memory_cookoff_v1' }
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
      ]
      // Native MCP has a process-local queue and session state. Not HA.
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}
output mcpUrl string = 'https://${app.properties.configuration.ingress.fqdn}/mcp'
