@description('Organisation prefix')
param orgPrefix string

@description('Environment')
param environment string

@description('App Service default hostname')
param originHostname string

@description('App Service resource ID for Private Link')
param originAppServiceId string

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
      probePath: '/health'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 30
      probeRequestType: 'HEAD'
    }
    sessionAffinityState: 'Disabled'
  }
}

resource origin 'Microsoft.Cdn/profiles/originGroups/origins@2023-07-01-preview' = {
  parent: originGroup
  name: 'origin-app-${environment}'
  properties: {
    hostName: originHostname
    originHostHeader: originHostname
    httpPort: 80
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    sharedPrivateLinkResource: {
      privateLink: { id: originAppServiceId }
      privateLinkLocation: 'northeurope'
      groupId: 'sites'
      requestMessage: 'Front Door Private Link'
    }
  }
}

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
  dependsOn: [origin]
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
