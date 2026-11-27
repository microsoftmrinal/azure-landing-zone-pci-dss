@description('Organisation prefix')
param orgPrefix string

@description('Environment')
param environment string

@description('FQDN used for SNI, the origin host header and certificate name validation. Must match the IIS certificate (shared by all regional origins).')
param originHostname string

@description('HTTPS port IIS listens on at the origin')
param originPort int = 8082

@description('HTTPS readiness path probed on each origin')
param healthProbePath string = '/health'

@description('Regional private origins: [{ name, privateLinkServiceId, location, priority, weight? }]. Lowest priority is preferred; higher priorities receive traffic on failover.')
param origins array

@description('Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Tags')
param tags object

resource profile 'Microsoft.Cdn/profiles@2023-07-01-preview' = {
  name: 'afd-${orgPrefix}-${environment}'
  location: 'global'
  tags: tags
  sku: { name: 'Premium_AzureFrontDoor' }
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2023-07-01-preview' = {
  parent: profile
  name: 'fde-${orgPrefix}-${environment}'
  location: 'global'
  tags: tags
  properties: { enabledState: 'Enabled' }
}

resource originGroup 'Microsoft.Cdn/profiles/originGroups@2023-07-01-preview' = {
  parent: profile
  name: 'og-app-${environment}'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
    }
    healthProbeSettings: {
      probePath: healthProbePath
      probeProtocol: 'Https'
      probeIntervalInSeconds: 30
      probeRequestType: 'GET'
    }
    sessionAffinityState: 'Disabled'
  }
}

// Private origins cannot be mixed with public origins in the same origin group.
// Each connection request must be approved on the regional Private Link Service.
resource originResources 'Microsoft.Cdn/profiles/originGroups/origins@2023-07-01-preview' = [for o in origins: {
  parent: originGroup
  name: 'origin-app-${o.name}-${environment}'
  properties: {
    hostName: originHostname
    originHostHeader: originHostname
    httpPort: 80
    httpsPort: originPort
    priority: o.priority
    weight: o.?weight ?? 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
    sharedPrivateLinkResource: {
      privateLink: { id: o.privateLinkServiceId }
      privateLinkLocation: o.location
      requestMessage: 'Front Door Private Link'
    }
  }
}]

resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2023-07-01-preview' = {
  parent: endpoint
  name: 'route-default'
  properties: {
    originGroup: { id: originGroup.id }
    supportedProtocols: ['Https']
    httpsRedirect: 'Enabled'
    patternsToMatch: ['/*']
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
  }
  dependsOn: [originResources]
}

resource wafPolicy 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2022-05-01' = {
  name: 'wafpol${orgPrefix}${environment}'
  location: 'global'
  tags: tags
  sku: { name: 'Premium_AzureFrontDoor' }
  properties: {
    policySettings: {
      mode: 'Prevention'
      enabledState: 'Enabled'
    }
    managedRules: {
      managedRuleSets: [
        { ruleSetType: 'Microsoft_DefaultRuleSet', ruleSetVersion: '2.1', ruleSetAction: 'Block' }
        { ruleSetType: 'Microsoft_BotManagerRuleSet', ruleSetVersion: '1.0', ruleSetAction: 'Block' }
      ]
    }
  }
}

resource securityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2023-07-01-preview' = {
  parent: profile
  name: 'secpol-waf-${environment}'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: { id: wafPolicy.id }
      associations: [
        {
          domains: [{ id: endpoint.id }]
          patternsToMatch: ['/*']
        }
      ]
    }
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-afd-to-law'
  scope: profile
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output endpointHostname string = endpoint.properties.hostName
output profileId string = profile.id
