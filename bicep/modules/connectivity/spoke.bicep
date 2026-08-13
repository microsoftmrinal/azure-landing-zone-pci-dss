@description('Azure region')
param location string

@description('Organisation prefix')
param orgPrefix string

@description('Environment')
param environment string

@description('Spoke VNet address space')
param addressSpace string

@description('Hub VNet resource ID for peering')
param hubVnetId string

@description('Firewall private IP for UDR')
param firewallPrivateIp string

@description('Tags')
param tags object

var regionCode = location == 'northeurope' ? 'neu' : 'weu'
var workload = 'cde'

resource nsgApp 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-${workload}-app-${environment}-${regionCode}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
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

resource nsgPe 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-${workload}-pe-${environment}-${regionCode}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
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

resource nsgCompute 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-${workload}-compute-${environment}-${regionCode}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
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

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-${workload}-${environment}-${regionCode}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressSpace] }
    subnets: [
      {
        name: 'snet-app-integration'
        properties: {
          addressPrefix: cidrSubnet(addressSpace, 24, 1)
          networkSecurityGroup: { id: nsgApp.id }
          delegations: [
            {
              name: 'app-service'
              properties: { serviceName: 'Microsoft.Web/serverFarms' }
            }
          ]
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: cidrSubnet(addressSpace, 24, 2)
          networkSecurityGroup: { id: nsgPe.id }
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: 'snet-compute'
        properties: {
          addressPrefix: cidrSubnet(addressSpace, 24, 3)
          networkSecurityGroup: { id: nsgCompute.id }
        }
      }
    ]
  }
}

resource routeTable 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'rt-${workload}-${environment}-${regionCode}'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: vnet
  name: 'peer-${workload}-to-hub'
  properties: {
    remoteVirtualNetwork: { id: hubVnetId }
    allowForwardedTraffic: true
    allowVirtualNetworkAccess: true
    useRemoteGateways: true
  }
}

output vnetId string = vnet.id
output appIntegrationSubnetId string = vnet.properties.subnets[0].id
output privateEndpointsSubnetId string = vnet.properties.subnets[1].id
output computeSubnetId string = vnet.properties.subnets[2].id
