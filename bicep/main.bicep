targetScope = 'subscription'

@description('Primary Azure region')
param primaryLocation string = 'northeurope'

@description('DR Azure region')
param drLocation string = 'westeurope'

@description('Organisation prefix for naming')
param orgPrefix string = 'p24'

@description('Environment name')
param environment string = 'prod'

@description('Entra ID object ID for SQL administrator group')
param sqlAdminObjectId string

@description('Entra ID object IDs for HSM administrators')
param hsmAdminObjectIds array

@description('Log Analytics workspace resource ID (from management subscription)')
param logAnalyticsWorkspaceId string

@description('Common tags applied to all resources')
param commonTags object = {
  Environment: 'Production'
  PCIScope: 'CDE'
  DataClassification: 'CardholderData'
  ManagedBy: 'Bicep'
  Workload: 'Payment24-CDE'
}

// --- Resource Groups ---
resource rgConn 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-conn-${environment}-neu'
  location: primaryLocation
  tags: commonTags
}

resource rgCde 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-cde-${environment}-neu'
  location: primaryLocation
  tags: commonTags
}

resource rgConnDr 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-conn-${environment}-weu'
  location: drLocation
  tags: commonTags
}

resource rgCdeDr 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-cde-${environment}-weu'
  location: drLocation
  tags: commonTags
}

// --- Phase 1: Connectivity ---
module hubPrimary 'modules/connectivity/hub.bicep' = {
  name: 'deploy-hub-neu'
  scope: rgConn
  params: {
    location: primaryLocation
    orgPrefix: orgPrefix
    environment: environment
    addressSpace: '10.1.0.0/16'
    tags: commonTags
  }
}

module firewall 'modules/connectivity/firewall.bicep' = {
  name: 'deploy-firewall-neu'
  scope: rgConn
  params: {
    location: primaryLocation
    orgPrefix: orgPrefix
    environment: environment
    firewallSubnetId: hubPrimary.outputs.firewallSubnetId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: commonTags
  }
}

module spoke 'modules/connectivity/spoke.bicep' = {
  name: 'deploy-spoke-cde-neu'
  scope: rgCde
  params: {
    location: primaryLocation
    orgPrefix: orgPrefix
    environment: environment
    addressSpace: '10.10.0.0/16'
    hubVnetId: hubPrimary.outputs.vnetId
    firewallPrivateIp: firewall.outputs.privateIpAddress
    tags: commonTags
  }
}

module dns 'modules/connectivity/dns.bicep' = {
  name: 'deploy-dns-zones'
  scope: rgConn
  params: {
    hubVnetId: hubPrimary.outputs.vnetId
    tags: commonTags
  }
}

module frontDoor 'modules/connectivity/frontDoor.bicep' = {
  name: 'deploy-front-door'
  scope: rgConn
  params: {
    orgPrefix: orgPrefix
    environment: environment
    originHostname: appService.outputs.defaultHostname
    originAppServiceId: appService.outputs.appServiceId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: commonTags
  }
}

// --- Phase 2: Data Platform ---
module hsm 'modules/data-platform/hsm.bicep' = {
  name: 'deploy-hsm'
  scope: rgCde
  params: {
    location: primaryLocation
    orgPrefix: orgPrefix
    environment: environment
    subnetId: spoke.outputs.privateEndpointsSubnetId
    adminObjectIds: hsmAdminObjectIds
    tags: commonTags
  }
}

module sql 'modules/data-platform/sql.bicep' = {
  name: 'deploy-sql'
  scope: rgCde
  params: {
    location: primaryLocation
    drLocation: drLocation
    orgPrefix: orgPrefix
    environment: environment
    subnetId: spoke.outputs.privateEndpointsSubnetId
    adminObjectId: sqlAdminObjectId
    keyVaultKeyUri: hsm.outputs.tdeKeyUri
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    sqlDnsZoneId: dns.outputs.sqlDnsZoneId
    tags: commonTags
  }
}

module storage 'modules/data-platform/storage.bicep' = {
  name: 'deploy-storage'
  scope: rgCde
  params: {
    location: primaryLocation
    orgPrefix: orgPrefix
    environment: environment
    subnetId: spoke.outputs.privateEndpointsSubnetId
    blobDnsZoneId: dns.outputs.blobDnsZoneId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: commonTags
  }
}

// --- Phase 3: Application Platform ---
module appService 'modules/application-platform/appService.bicep' = {
  name: 'deploy-app-service'
  scope: rgCde
  params: {
    location: primaryLocation
    orgPrefix: orgPrefix
    environment: environment
    integrationSubnetId: spoke.outputs.appIntegrationSubnetId
    privateEndpointSubnetId: spoke.outputs.privateEndpointsSubnetId
    appDnsZoneId: dns.outputs.appServiceDnsZoneId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: commonTags
  }
}

// --- Outputs ---
output hubVnetId string = hubPrimary.outputs.vnetId
output firewallPrivateIp string = firewall.outputs.privateIpAddress
output frontDoorEndpoint string = frontDoor.outputs.endpointHostname
output sqlServerFqdn string = sql.outputs.serverFqdn
output keyVaultUri string = hsm.outputs.keyVaultUri
