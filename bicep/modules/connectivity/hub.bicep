@description('Azure region')
param location string

@description('Organisation prefix')
param orgPrefix string

@description('Environment')
param environment string

@description('VNet address space')
param addressSpace string

@description('Tags')
param tags object

var regionCode = location == 'northeurope' ? 'neu' : 'weu'

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-hub-${environment}-${regionCode}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressSpace]
    }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: cidrSubnet(addressSpace, 26, 0)
        }
      }
      {
        name: 'AzureFirewallManagementSubnet'
        properties: {
          addressPrefix: cidrSubnet(addressSpace, 26, 1)
        }
      }
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: cidrSubnet(addressSpace, 26, 2)
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: cidrSubnet(addressSpace, 26, 3)
        }
      }
    ]
  }
}

resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-bastion-${environment}-${regionCode}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  zones: ['1', '2', '3']
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: 'bas-${orgPrefix}-${environment}-${regionCode}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    enableTunneling: true
    ipConfigurations: [
      {
        name: 'bastion-ipconfig'
        properties: {
          subnet: { id: vnet.properties.subnets[3].id }
          publicIPAddress: { id: bastionPip.id }
        }
      }
    ]
  }
}

resource ddos 'Microsoft.Network/ddosProtectionPlans@2023-09-01' = {
  name: 'ddos-${orgPrefix}-${environment}-${regionCode}'
  location: location
  tags: tags
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output firewallSubnetId string = vnet.properties.subnets[0].id
output gatewaySubnetId string = vnet.properties.subnets[2].id
output ddosProtectionPlanId string = ddos.id
