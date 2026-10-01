targetScope = 'resourceGroup'
param location string = resourceGroup().location
param vmName string = 'graphiti-cookoff-db'
@description('Digest-pinned falkordb/falkordb-server image. Never latest.')
param databaseImage string
param privateIp string = '10.42.4.4'
@secure()
@minLength(64)
@maxLength(64)
param databasePassword string
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = { name: vmName }
resource configure 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'configure-falkordb'
  location: location
  properties: {
    source: { script: loadTextContent('configure-database.sh') }
    timeoutInSeconds: 1200
    treatFailureAsDeploymentFailure: true
    parameters: [
      { name: 'FALKORDB_IMAGE', value: databaseImage }
      { name: 'DB_PRIVATE_IP', value: privateIp }
    ]
    protectedParameters: [{ name: 'DB_PASSWORD', value: databasePassword }]
  }
}
