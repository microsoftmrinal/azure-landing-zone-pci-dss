@description('Azure region')
param location string

@description('Organisation prefix')
param orgPrefix string

@description('Environment')
param environment string

@description('Subnet ID for VNet integration')
param integrationSubnetId string

@description('Subnet ID for private endpoint')
param privateEndpointSubnetId string

@description('App Service DNS zone ID')
param appDnsZoneId string

@description('Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Tags')
param tags object

var regionCode = location == 'northeurope' ? 'neu' : 'weu'

resource plan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: 'asp-${orgPrefix}-cde-${environment}-${regionCode}'
  location: location
  tags: tags
  kind: 'linux'
  sku: { name: 'P2v3', tier: 'PremiumV3' }
  properties: {
    reserved: true
    zoneRedundant: true
  }
}

resource app 'Microsoft.Web/sites@2023-01-01' = {
  name: 'app-${orgPrefix}-cde-${environment}-${regionCode}'
  location: location
  tags: tags
  kind: 'app,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: integrationSubnetId
    clientCertEnabled: true
    clientCertMode: 'OptionalInteractiveUser'
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      alwaysOn: true
      healthCheckPath: '/health'
      ipSecurityRestrictionsDefaultAction: 'Deny'
      detailedErrorLoggingEnabled: true
      httpLoggingEnabled: true
      requestTracingEnabled: true
    }
  }
}

resource authSettings 'Microsoft.Web/sites/config@2023-01-01' = {
  parent: app
  name: 'authsettingsV2'
  properties: {
    globalValidation: { requireAuthentication: true }
    platform: { enabled: true }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-app-${orgPrefix}-${environment}-${regionCode}'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'psc-app'
        properties: {
          privateLinkServiceId: app.id
          groupIds: ['sites']
        }
      }
    ]
  }
}

resource dnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: privateEndpoint
  name: 'dns-zone-group-app'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'app-config'
        properties: { privateDnsZoneId: appDnsZoneId }
      }
    ]
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-app-to-law'
  scope: app
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'AppServiceHTTPLogs', enabled: true }
      { category: 'AppServiceConsoleLogs', enabled: true }
      { category: 'AppServiceAuditLogs', enabled: true }
    ]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output appServiceId string = app.id
output defaultHostname string = app.properties.defaultHostName
output appIdentityPrincipalId string = app.identity.principalId
