targetScope = 'resourceGroup'

param location string = resourceGroup().location
param prefix string = 'graphiti-cookoff'
param vmSize string = 'Standard_B2ms'
param sshPublicKey string
param adminUsername string = 'graphitiadmin'
@description('Dedicated, unpeered test network. Confirm no overlap before deployment.')
param networkPrefix string = '10.42.0.0/16'
param appSubnetPrefix string = '10.42.0.0/23'
param dbSubnetPrefix string = '10.42.4.0/24'
param dbPrivateIp string = '10.42.4.4'
var tags = { purpose: 'synthetic-memory-cookoff', production: 'false' }

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${prefix}-db-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'OnlyGraphitiSubnet'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '6379'
          sourceAddressPrefix: appSubnetPrefix
          destinationAddressPrefix: dbPrivateIp
        }
      }
      {
        name: 'DenyAllOtherInbound'
        properties: {
          priority: 200
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${prefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [networkPrefix] }
    subnets: [
      {
        name: 'apps'
        properties: {
          addressPrefix: appSubnetPrefix
          delegations: [{ name: 'containerapps', properties: { serviceName: 'Microsoft.App/environments' } }]
        }
      }
      {
        name: 'database'
        properties: {
          addressPrefix: dbSubnetPrefix
          networkSecurityGroup: { id: nsg.id }
          defaultOutboundAccess: false
        }
      }
    ]
  }
}
// Explicit VM outbound internet for package/image pulls. NO public inbound rule,
// including SSH. Administration uses Azure managed Run Command and RBAC.
resource outboundIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${prefix}-db-egress'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}
resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${prefix}-db-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [{
      name: 'primary'
      properties: {
        privateIPAllocationMethod: 'Static'
        privateIPAddress: dbPrivateIp
        subnet: { id: '${vnet.id}/subnets/database' }
        publicIPAddress: { id: outboundIp.id }
      }
    }]
  }
}
resource disk 'Microsoft.Compute/disks@2024-03-02' = {
  name: '${prefix}-data'
  location: location
  tags: tags
  sku: { name: 'StandardSSD_LRS' }
  properties: { creationData: { createOption: 'Empty' }, diskSizeGB: 32 }
}
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: '${prefix}-db'
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: '${prefix}-db'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [{ path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }] }
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: { publisher: 'Canonical', offer: 'ubuntu-24_04-lts', sku: 'server', version: 'latest' }
      osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'StandardSSD_LRS' } }
      dataDisks: [{ lun: 0, createOption: 'Attach', managedDisk: { id: disk.id }, deleteOption: 'Detach', caching: 'None' }]
    }
    networkProfile: { networkInterfaces: [{ id: nic.id }] }
  }
}
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-logs'
  location: location
  tags: tags
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}
resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${prefix}-env'
  location: location
  tags: tags
  properties: {
    vnetConfiguration: { infrastructureSubnetId: '${vnet.id}/subnets/apps', internal: false }
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: { customerId: logs.properties.customerId, sharedKey: logs.listKeys().primarySharedKey }
    }
  }
}
output environmentId string = environment.id
output databaseVmName string = vm.name
output databaseUri string = 'redis://${dbPrivateIp}:6379'
output dataDiskId string = disk.id
