@description('Hub VNet resource ID')
param hubVnetId string

@description('Tags')
param tags object

var zones = [
  'privatelink.database.windows.net'
  'privatelink.blob.core.windows.net'
  'privatelink.vaultcore.azure.net'
  'privatelink.managedhsm.azure.net'
]

resource dnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zone in zones: {
  name: zone
  location: 'global'
  tags: tags
}]

resource vnetLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zone, i) in zones: {
  parent: dnsZones[i]
  name: 'link-hub-${replace(zone, '.', '-')}'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: { id: hubVnetId }
    registrationEnabled: false
  }
}]

output sqlDnsZoneId string = dnsZones[0].id
output blobDnsZoneId string = dnsZones[1].id
output keyVaultDnsZoneId string = dnsZones[2].id
output hsmDnsZoneId string = dnsZones[3].id
