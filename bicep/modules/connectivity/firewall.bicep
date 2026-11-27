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

@description('CDE spoke address space(s): destination of inbound VPN client traffic and source of Client A egress')
param cdeAddressPrefixes array = []

@description('HTTPS port IIS listens on')
param appPort int = 8082

@description('Client B source prefixes allowed to reach IIS over VPN. Empty = no rule.')
param clientBInboundPrefixes array = []

@description('Client A server prefixes the CDE application may connect out to. Empty = no rule.')
param clientADestinationPrefixes array = []

@description('TCP ports of the Client A server')
param clientADestinationPorts array = []

@description('Optional existing Standard static public IP (e.g. pip-clientA-nat-egress) added to the firewall. Azure Firewall chooses among its public IPs for SNAT, so Client A must allow-list every firewall egress IP; this does not pin Client A flows to this address.')
param clientAEgressPublicIpId string = ''

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
  dependsOn: [cdeRules]
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Premium'
    }
    firewallPolicy: { id: firewallPolicy.id }
    ipConfigurations: concat([
      {
        name: 'fw-ipconfig'
        properties: {
          subnet: { id: firewallSubnetId }
          publicIPAddress: { id: firewallPip.id }
        }
      }
    ], empty(clientAEgressPublicIpId) ? [] : [
      {
        name: 'fw-ipconfig-client-a'
        properties: {
          publicIPAddress: { id: clientAEgressPublicIpId }
        }
      }
    ])
  }
}

resource cdeRules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'rcg-cde-${environment}'
  properties: {
    priority: 100
    ruleCollections: concat([
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-azure-services'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'allow-dns'
            ipProtocols: ['UDP']
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['168.63.129.16']
            destinationPorts: ['53']
          }
          {
            ruleType: 'NetworkRule'
            name: 'allow-ntp'
            ipProtocols: ['UDP']
            sourceAddresses: ['10.0.0.0/8']
            destinationAddresses: ['*']
            destinationPorts: ['123']
          }
          {
            ruleType: 'NetworkRule'
            name: 'allow-azure-monitor'
            ipProtocols: ['TCP']
            sourceAddresses: ['10.0.0.0/8']
            destinationFqdns: ['*.ods.opinsights.azure.com', '*.oms.opinsights.azure.com', '*.monitoring.azure.com']
            destinationPorts: ['443']
          }
          {
            ruleType: 'NetworkRule'
            name: 'allow-windows-activation'
            ipProtocols: ['TCP']
            sourceAddresses: ['10.0.0.0/8']
            destinationFqdns: ['azkms.core.windows.net', 'kms.core.windows.net']
            destinationPorts: ['1688']
          }
        ]
      }
    ], empty(clientBInboundPrefixes) || empty(cdeAddressPrefixes) ? [] : [
      {
        // Client B (VPN) -> IIS. Source prefixes must be the real partner ranges.
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-client-b-to-app'
        priority: 110
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'client-b-to-iis'
            ipProtocols: ['TCP']
            sourceAddresses: clientBInboundPrefixes
            destinationAddresses: cdeAddressPrefixes
            destinationPorts: [string(appPort)]
          }
        ]
      }
    ], empty(clientADestinationPrefixes) || empty(clientADestinationPorts) || empty(cdeAddressPrefixes) ? [] : [
      {
        // CDE application -> Client A server (connection initiated by the custom app on the VM).
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-app-to-client-a'
        priority: 120
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'app-to-client-a'
            ipProtocols: ['TCP']
            sourceAddresses: cdeAddressPrefixes
            destinationAddresses: clientADestinationPrefixes
            destinationPorts: clientADestinationPorts
          }
        ]
      }
    ], [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-microsoft-updates'
        priority: 200
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'windows-update'
            protocols: [{ protocolType: 'Https', port: 443 }]
            sourceAddresses: ['10.0.0.0/8']
            targetFqdns: ['*.update.microsoft.com', '*.windowsupdate.com']
          }
          {
            ruleType: 'ApplicationRule'
            name: 'entra-id-vm-login'
            protocols: [{ protocolType: 'Https', port: 443 }]
            sourceAddresses: ['10.0.0.0/8']
            targetFqdns: ['login.microsoftonline.com', 'enterpriseregistration.windows.net', 'device.login.microsoftonline.com', 'pas.windows.net']
          }
        ]
      }
    ])
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
output publicIpAddress string = firewallPip.properties.ipAddress
