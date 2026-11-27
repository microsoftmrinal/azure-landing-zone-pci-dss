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

@description('HTTPS port the IIS application listens on in the compute subnet')
param appPort int = 8082

@description('Private client prefixes (e.g. VPN client B ranges) allowed to reach the application port')
param appInboundPrefixes array = []

@description('Source prefixes (e.g. the hub Bastion subnet/VNet) allowed inbound to the compute subnet on RDP')
param managementInboundPrefixes array = []

@description('Use the hub VPN/ER gateway for transit. Must be false unless the hub has a gateway and gateway-transit peering.')
param useRemoteGateways bool = false

@description('Tags')
param tags object

var regionCode = location == 'northeurope' ? 'neu' : 'weu'
var workload = 'cde'
var plsSubnetPrefix = cidrSubnet(addressSpace, 24, 1)

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
    securityRules: concat([
      {
        // Front Door Premium reaches IIS through the Private Link Service NAT subnet.
        name: 'AllowAppFromPrivateLink'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: string(appPort)
          sourceAddressPrefix: plsSubnetPrefix
          destinationAddressPrefix: '*'
        }
      }
      {
        // Internal load balancer health probes.
        name: 'AllowLoadBalancerProbe'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: string(appPort)
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
    ], empty(appInboundPrefixes) ? [] : [
      {
        name: 'AllowAppFromPrivateClients'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: string(appPort)
          sourceAddressPrefixes: appInboundPrefixes
          destinationAddressPrefix: '*'
        }
      }
    ], empty(managementInboundPrefixes) ? [] : [
      {
        name: 'AllowManagementInbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefixes: managementInboundPrefixes
          destinationAddressPrefix: '*'
        }
      }
    ], [
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
    ])
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
        // NAT subnet for the Private Link Service that exposes the IIS load balancer to Front Door.
        // Private link service network policies must be disabled; NSGs are not applied here.
        name: 'snet-pls'
        properties: {
          addressPrefix: plsSubnetPrefix
          privateLinkServiceNetworkPolicies: 'Disabled'
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
    useRemoteGateways: useRemoteGateways
  }
}

output vnetId string = vnet.id
output privateLinkServiceSubnetId string = vnet.properties.subnets[0].id
output privateLinkServiceSubnetPrefix string = plsSubnetPrefix
output privateEndpointsSubnetId string = vnet.properties.subnets[1].id
output computeSubnetId string = vnet.properties.subnets[2].id
