@description('Azure region')
param location string

@description('Organisation prefix')
param orgPrefix string

@description('Environment')
param environment string

@description('Compute subnet ID for the VM NIC and the internal load balancer frontend')
param subnetId string

@description('Subnet ID (private link service network policies disabled) for the Private Link Service NAT IP')
param privateLinkNatSubnetId string

@description('Local administrator user name')
param adminUsername string = 'azureadmin'

@description('Local administrator password (supply from Key Vault / environment; never commit)')
@secure()
param adminPassword string

@description('Disk Encryption Set ID backed by an HSM key')
param diskEncryptionSetId string

@description('HTTPS port IIS listens on')
param appPort int = 8082

@description('HTTPS readiness path served by IIS on appPort')
param healthProbePath string = '/health'

@description('Source prefixes allowed by Windows Firewall to reach appPort (Private Link Service NAT subnet, VPN clients). Empty = any source (NSG still applies).')
param appAllowedSourcePrefixes array = []

@description('VM size')
param vmSize string = 'Standard_D4s_v5'

@description('Availability zone for the VM')
param availabilityZone string = '1'

@description('Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Tags')
param tags object

var regionCode = location == 'northeurope' ? 'neu' : 'weu'
var suffix = '${orgPrefix}-cde-${environment}-${regionCode}'
var lbName = 'lbi-${suffix}'
// 168.63.129.16 is the Azure platform address that sources load balancer probes.
var firewallRemoteAddresses = empty(appAllowedSourcePrefixes) ? 'Any' : join(concat(appAllowedSourcePrefixes, ['168.63.129.16']), ',')

resource lb 'Microsoft.Network/loadBalancers@2023-09-01' = {
  name: lbName
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'fe-app'
        zones: ['1', '2', '3']
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
    backendAddressPools: [
      { name: 'be-iis' }
    ]
    probes: [
      {
        name: 'probe-https-${appPort}'
        properties: {
          protocol: 'Https'
          port: appPort
          requestPath: healthProbePath
          intervalInSeconds: 15
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'rule-https-${appPort}'
        properties: {
          protocol: 'Tcp'
          frontendPort: appPort
          backendPort: appPort
          enableTcpReset: true
          frontendIPConfiguration: { id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, 'fe-app') }
          backendAddressPool: { id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, 'be-iis') }
          probe: { id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, 'probe-https-${appPort}') }
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-vm-${suffix}-001'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'internal'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
          loadBalancerBackendAddressPools: [
            { id: lb.properties.backendAddressPools[0].id }
          ]
        }
      }
    ]
  }
}

// Private Link Service: Front Door Premium reaches IIS through a Front Door-managed
// private endpoint. The connection request must be approved on this resource.
resource pls 'Microsoft.Network/privateLinkServices@2023-09-01' = {
  name: 'pls-${suffix}'
  location: location
  tags: tags
  properties: {
    loadBalancerFrontendIpConfigurations: [
      { id: lb.properties.frontendIPConfigurations[0].id }
    ]
    ipConfigurations: [
      {
        name: 'nat-primary'
        properties: {
          primary: true
          privateIPAddressVersion: 'IPv4'
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: privateLinkNatSubnetId }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-${suffix}-001'
  location: location
  tags: tags
  zones: [availabilityZone]
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    securityProfile: {
      encryptionAtHost: true
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    osProfile: {
      computerName: take('${orgPrefix}iis${regionCode}01', 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'Premium_ZRS'
          diskEncryptionSet: { id: diskEncryptionSetId }
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: nic.id }
      ]
    }
  }
}

// Installs the IIS role and opens the app port. The site, the HTTPS binding on appPort and
// the certificate for the application FQDN are deployed by the application pipeline.
resource iisRole 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'iis-role'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: 'powershell.exe -ExecutionPolicy Bypass -Command "Install-WindowsFeature -Name Web-Server -IncludeManagementTools; New-NetFirewallRule -DisplayName \'App-HTTPS-${appPort}\' -Direction Inbound -Protocol TCP -LocalPort ${appPort} -RemoteAddress ${firewallRemoteAddresses} -Action Allow"'
    }
  }
}

// Entra ID sign-in for administrators (RDP via Bastion); avoids shared local credentials.
resource aadLogin 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'aad-login'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
  }
}

resource nicDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-nic-to-law'
  scope: nic
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

resource lbDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-lb-to-law'
  scope: lb
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output vmId string = vm.id
output vmIdentityPrincipalId string = vm.identity.principalId
output loadBalancerFrontendIpAddress string = lb.properties.frontendIPConfigurations[0].properties.privateIPAddress
output privateLinkServiceId string = pls.id
