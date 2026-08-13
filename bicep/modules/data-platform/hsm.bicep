@description('Azure region')
param location string

@description('Organisation prefix')
param orgPrefix string

@description('Environment')
param environment string

@description('Subnet ID for private endpoint')
param subnetId string

@description('Entra ID object IDs for HSM administrators')
param adminObjectIds array

@description('Tags')
param tags object

var regionCode = location == 'northeurope' ? 'neu' : 'weu'

resource managedHsm 'Microsoft.KeyVault/managedHSMs@2023-07-01' = {
  name: 'hsm-${orgPrefix}-${environment}-${regionCode}'
  location: location
  tags: tags
  sku: { family: 'B', name: 'Standard_B1' }
  properties: {
    tenantId: subscription().tenantId
    initialAdminObjectIds: adminObjectIds
    enablePurgeProtection: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${orgPrefix}-${environment}-${regionCode}'
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'premium' }
    enablePurgeProtection: true
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource tdeKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: keyVault
  name: 'key-tde-sql-cde'
  properties: {
    kty: 'RSA-HSM'
    keySize: 3072
    keyOps: ['unwrapKey', 'wrapKey']
    attributes: {
      enabled: true
      exp: dateTimeAdd(utcNow(), 'P365D')
    }
    rotationPolicy: {
      lifetimeActions: [
        {
          trigger: { timeBeforeExpiry: 'P30D' }
          action: { type: 'Rotate' }
        }
      ]
      attributes: { expiryTime: 'P365D' }
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-kv-${orgPrefix}-${environment}-${regionCode}'
  location: location
  tags: tags
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: 'psc-keyvault'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}

output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri
output tdeKeyUri string = tdeKey.properties.keyUriWithVersion
output hsmId string = managedHsm.id
