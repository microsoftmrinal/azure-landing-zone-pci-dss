targetScope = 'subscription'

@description('Primary Azure region')
param primaryLocation string = 'northeurope'

@description('DR Azure region')
param drLocation string = 'westeurope'

@description('Organisation prefix for naming')
param orgPrefix string = 'org'

@description('Environment name')
param environment string = 'prod'

@description('Entra ID object ID for SQL administrator group')
param sqlAdminObjectId string

@description('Entra ID object IDs for HSM administrators')
param hsmAdminObjectIds array

@description('Log Analytics workspace resource ID (from management subscription)')
param logAnalyticsWorkspaceId string

@description('Local administrator password for the IIS VMs (supply at deployment time from Key Vault; never commit)')
@secure()
param vmAdminPassword string

@description('HTTPS port IIS listens on')
param appPort int = 8082

@description('FQDN on the IIS certificate (SAN covers both regions). Used for Front Door SNI, origin host header and certificate name validation.')
param appOriginHostname string

@description('Client B source prefixes allowed to reach IIS on appPort over VPN (via the firewall). Empty = no rule.')
param clientBInboundPrefixes array = []

@description('Client A server prefixes the custom app on the VM connects out to. Empty = no rule.')
param clientADestinationPrefixes array = []

@description('TCP ports of the Client A server')
param clientADestinationPorts array = []

@description('North Europe reserved public IP (e.g. pip-clientA-nat-egress) added to the firewall. Client A must allow-list every firewall egress IP.')
param clientAEgressPublicIpId string = ''

@description('West Europe reserved public IP added to the West Europe firewall. Client A must allow-list it in advance.')
param drClientAEgressPublicIpId string = ''

@description('Common tags applied to all resources')
param commonTags object = {
  Environment: 'Production'
  PCIScope: 'CDE'
  DataClassification: 'CardholderData'
  ManagedBy: 'Bicep'
  Workload: 'CDE-Workload'
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
    cdeAddressPrefixes: ['10.10.0.0/16']
    appPort: appPort
    clientBInboundPrefixes: clientBInboundPrefixes
    clientADestinationPrefixes: clientADestinationPrefixes
    clientADestinationPorts: clientADestinationPorts
    clientAEgressPublicIpId: clientAEgressPublicIpId
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
    appPort: appPort
    appInboundPrefixes: clientBInboundPrefixes
    managementInboundPrefixes: ['10.1.0.0/16']
    tags: commonTags
  }
}

// --- West Europe (warm standby) connectivity ---
module hubDr 'modules/connectivity/hub.bicep' = {
  name: 'deploy-hub-weu'
  scope: rgConnDr
  params: {
    location: drLocation
    orgPrefix: orgPrefix
    environment: environment
    addressSpace: '10.2.0.0/16'
    tags: commonTags
  }
}

module firewallDr 'modules/connectivity/firewall.bicep' = {
  name: 'deploy-firewall-weu'
  scope: rgConnDr
  params: {
    location: drLocation
    orgPrefix: orgPrefix
    environment: environment
    firewallSubnetId: hubDr.outputs.firewallSubnetId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    cdeAddressPrefixes: ['10.20.0.0/16']
    appPort: appPort
    clientBInboundPrefixes: clientBInboundPrefixes
    clientADestinationPrefixes: clientADestinationPrefixes
    clientADestinationPorts: clientADestinationPorts
    clientAEgressPublicIpId: drClientAEgressPublicIpId
    tags: commonTags
  }
}

module spokeDr 'modules/connectivity/spoke.bicep' = {
  name: 'deploy-spoke-cde-weu'
  scope: rgCdeDr
  params: {
    location: drLocation
    orgPrefix: orgPrefix
    environment: environment
    addressSpace: '10.20.0.0/16'
    hubVnetId: hubDr.outputs.vnetId
    firewallPrivateIp: firewallDr.outputs.privateIpAddress
    appPort: appPort
    appInboundPrefixes: clientBInboundPrefixes
    managementInboundPrefixes: ['10.2.0.0/16']
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

// Front Door Premium + WAF with private IIS origins: North Europe preferred (priority 1),
// West Europe failover (priority 2). Approve each Front Door private endpoint connection
// on the regional Private Link Service after deployment.
module frontDoor 'modules/connectivity/frontDoor.bicep' = {
  name: 'deploy-front-door'
  scope: rgConn
  params: {
    orgPrefix: orgPrefix
    environment: environment
    originHostname: appOriginHostname
    originPort: appPort
    origins: [
      {
        name: 'neu'
        privateLinkServiceId: compute.outputs.privateLinkServiceId
        location: primaryLocation
        priority: 1
      }
      {
        name: 'weu'
        privateLinkServiceId: computeDr.outputs.privateLinkServiceId
        location: drLocation
        priority: 2
      }
    ]
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

// --- Phase 3: IIS VMs behind internal load balancers + Private Link Services ---
// The DR key platform is an independent HSM/Key Vault: the disk encryption set must be in the VM's region.
// Cross-region key recovery is a separate design decision.
module hsmDr 'modules/data-platform/hsm.bicep' = {
  name: 'deploy-hsm-weu'
  scope: rgCdeDr
  params: {
    location: drLocation
    orgPrefix: orgPrefix
    environment: environment
    subnetId: spokeDr.outputs.privateEndpointsSubnetId
    adminObjectIds: hsmAdminObjectIds
    tags: commonTags
  }
}

module compute 'modules/application-platform/compute.bicep' = {
  name: 'deploy-iis-vm-neu'
  scope: rgCde
  params: {
    location: primaryLocation
    orgPrefix: orgPrefix
    environment: environment
    subnetId: spoke.outputs.computeSubnetId
    privateLinkNatSubnetId: spoke.outputs.privateLinkServiceSubnetId
    adminPassword: vmAdminPassword
    diskEncryptionSetId: hsm.outputs.diskEncryptionSetId
    appPort: appPort
    appAllowedSourcePrefixes: concat([spoke.outputs.privateLinkServiceSubnetPrefix], clientBInboundPrefixes)
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: commonTags
  }
}

module computeDr 'modules/application-platform/compute.bicep' = {
  name: 'deploy-iis-vm-weu'
  scope: rgCdeDr
  params: {
    location: drLocation
    orgPrefix: orgPrefix
    environment: environment
    subnetId: spokeDr.outputs.computeSubnetId
    privateLinkNatSubnetId: spokeDr.outputs.privateLinkServiceSubnetId
    adminPassword: vmAdminPassword
    diskEncryptionSetId: hsmDr.outputs.diskEncryptionSetId
    appPort: appPort
    appAllowedSourcePrefixes: concat([spokeDr.outputs.privateLinkServiceSubnetPrefix], clientBInboundPrefixes)
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: commonTags
  }
}

// --- Outputs ---
output hubVnetId string = hubPrimary.outputs.vnetId
output firewallPrivateIp string = firewall.outputs.privateIpAddress
output firewallPublicIp string = firewall.outputs.publicIpAddress
output drFirewallPublicIp string = firewallDr.outputs.publicIpAddress
output frontDoorEndpoint string = frontDoor.outputs.endpointHostname
output privateLinkServiceIdNeu string = compute.outputs.privateLinkServiceId
output privateLinkServiceIdWeu string = computeDr.outputs.privateLinkServiceId
output sqlServerFqdn string = sql.outputs.serverFqdn
output keyVaultUri string = hsm.outputs.keyVaultUri
