targetScope = 'managementGroup'

@description('Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Primary location')
param primaryLocation string = 'northeurope'

// Sentinel workspace
resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: last(split(logAnalyticsWorkspaceId, '/'))
  scope: resourceGroup(split(logAnalyticsWorkspaceId, '/')[2], split(logAnalyticsWorkspaceId, '/')[4])
}

// Enable all Defender for Cloud plans via policy
resource defenderServers 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'VirtualMachines'
  properties: { pricingTier: 'Standard' }
}

resource defenderSql 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'SqlServers'
  properties: { pricingTier: 'Standard' }
}

resource defenderStorage 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'StorageAccounts'
  properties: {
    pricingTier: 'Standard'
    subPlan: 'DefenderForStorageV2'
  }
}

resource defenderKeyVaults 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'KeyVaults'
  properties: { pricingTier: 'Standard' }
}

resource defenderArm 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'Arm'
  properties: { pricingTier: 'Standard' }
}

resource defenderDns 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'Dns'
  properties: { pricingTier: 'Standard' }
}

resource defenderContainers 'Microsoft.Security/pricings@2024-01-01' = {
  name: 'Containers'
  properties: { pricingTier: 'Standard' }
}
