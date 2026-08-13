@description('Azure region')
param location string

@description('DR region')
param drLocation string

@description('Organisation prefix')
param orgPrefix string

@description('Environment')
param environment string

@description('Subnet ID for private endpoint')
param subnetId string

@description('Entra ID object ID of SQL admin group')
param adminObjectId string

@description('Key Vault key URI for TDE')
param keyVaultKeyUri string

@description('Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

@description('SQL Private DNS Zone ID')
param sqlDnsZoneId string

@description('Tags')
param tags object

var regionCode = location == 'northeurope' ? 'neu' : 'weu'
var drRegionCode = drLocation == 'westeurope' ? 'weu' : 'neu'

resource sqlPrimary 'Microsoft.Sql/servers@2023-05-01-preview' = {
  name: 'sql-${orgPrefix}-${environment}-${regionCode}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      login: 'sg-sql-admins-cde'
      sid: adminObjectId
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource sqlSecondary 'Microsoft.Sql/servers@2023-05-01-preview' = {
  name: 'sql-${orgPrefix}-${environment}-${drRegionCode}'
  location: drLocation
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      login: 'sg-sql-admins-cde'
      sid: adminObjectId
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource database 'Microsoft.Sql/servers/databases@2023-05-01-preview' = {
  parent: sqlPrimary
  name: 'sqldb-${orgPrefix}-cde-${environment}'
  location: location
  tags: tags
  sku: { name: 'BC_Gen5', tier: 'BusinessCritical', capacity: 4 }
  properties: {
    zoneRedundant: true
    maxSizeBytes: 274877906944 // 256 GB
    encryptionProtector: {
      identity: { type: 'SystemAssigned' }
      value: keyVaultKeyUri
    }
  }
}

resource failoverGroup 'Microsoft.Sql/servers/failoverGroups@2023-05-01-preview' = {
  parent: sqlPrimary
  name: 'fog-${orgPrefix}-cde-${environment}'
  tags: tags
  properties: {
    partnerServers: [{ id: sqlSecondary.id }]
    databases: [database.id]
    readWriteEndpoint: {
      failoverPolicy: 'Automatic'
      failoverWithDataLossGracePeriodMinutes: 60
    }
  }
}

resource auditPrimary 'Microsoft.Sql/servers/auditingSettings@2023-05-01-preview' = {
  parent: sqlPrimary
  name: 'default'
  properties: {
    state: 'Enabled'
    isAzureMonitorTargetEnabled: true
    retentionDays: 365
  }
}

resource auditSecondary 'Microsoft.Sql/servers/auditingSettings@2023-05-01-preview' = {
  parent: sqlSecondary
  name: 'default'
  properties: {
    state: 'Enabled'
    isAzureMonitorTargetEnabled: true
    retentionDays: 365
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-sql-${orgPrefix}-${environment}-${regionCode}'
  location: location
  tags: tags
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: 'psc-sql'
        properties: {
          privateLinkServiceId: sqlPrimary.id
          groupIds: ['sqlServer']
        }
      }
    ]
    customDnsConfigs: []
  }
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: privateEndpoint
  name: 'dns-zone-group-sql'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sql-config'
        properties: { privateDnsZoneId: sqlDnsZoneId }
      }
    ]
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-sql-to-law'
  scope: database
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'SQLSecurityAuditEvents', enabled: true }
      { category: 'AutomaticTuning', enabled: true }
    ]
    metrics: [{ category: 'Basic', enabled: true }]
  }
}

output serverFqdn string = sqlPrimary.properties.fullyQualifiedDomainName
output serverId string = sqlPrimary.id
output failoverGroupFqdn string = '${failoverGroup.name}.database.windows.net'
