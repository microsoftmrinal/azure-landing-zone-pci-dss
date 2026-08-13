@description('Azure region')
param location string

@description('Organisation prefix')
param orgPrefix string

@description('Environment')
param environment string

@description('Firewall subnet resource ID')
param firewallSubnetId string

@description('Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Tags')
param tags object

var regionCode = location == 'northeurope' ? 'neu' : 'weu'

resource firewallPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-fw-${orgPrefix}-${environment}-${regionCode}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  zones: ['1', '2', '3']
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: 'fwpol-${orgPrefix}-${environment}-${regionCode}'
  location: location
  tags: tags
  properties: {
    sku: { tier: 'Premium' }
    threatIntelMode: 'Deny'
    dnsSettings: { enableProxy: true }
    intrusionDetection: {
      mode: 'Deny'
      configuration: {
        bypassTrafficSettings: []
        signatureOverrides: []
      }
    }
    insights: {
      isEnabled: true
      logAnalyticsResources: {
        defaultWorkspaceId: { id: logAnalyticsWorkspaceId }
      }
      retentionDays: 365
    }
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  name: 'fw-${orgPrefix}-${environment}-${regionCode}'
  location: location
  tags: tags
  zones: ['1', '2', '3']
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Premium'
    }
    firewallPolicy: { id: firewallPolicy.id }
    ipConfigurations: [
      {
        name: 'fw-ipconfig'
        properties: {
          subnet: { id: firewallSubnetId }
          publicIPAddress: { id: firewallPip.id }
        }
      }
    ]
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-fw-to-law'
  scope: firewall
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output privateIpAddress string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output firewallId string = firewall.id
