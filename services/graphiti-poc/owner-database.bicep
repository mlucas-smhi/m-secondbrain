targetScope = 'resourceGroup'
@secure()
param databasePassword string
@secure()
param tlsKeyBase64 string
param tlsCertBase64 string
param tlsCaBase64 string
param databaseImage string
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = { name: 'graphiti-cookoff-db' }
resource configure 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'configure-eleven-owner-database'
  location: resourceGroup().location
  properties: {
    source: { script: loadTextContent('configure-owner-database.sh') }
    timeoutInSeconds: 600
    treatFailureAsDeploymentFailure: true
    parameters: [
      { name: 'FALKORDB_IMAGE', value: databaseImage }
      { name: 'TLS_CA_B64', value: tlsCaBase64 }
      { name: 'TLS_CERT_B64', value: tlsCertBase64 }
    ]
    protectedParameters: [
      { name: 'DB_PASSWORD', value: databasePassword }
      { name: 'TLS_KEY_B64', value: tlsKeyBase64 }
    ]
  }
}
