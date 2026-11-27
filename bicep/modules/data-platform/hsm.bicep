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

@description('Key expiry as Unix epoch seconds. utcNow() is only valid as a parameter default.')
param keyExpiryEpoch int = dateTimeToEpoch(dateTimeAdd(utcNow(), 'P365D'))

var regionCode = location == 'northeurope' ? 'neu' : 'weu'
// Key Vault Crypto Service Encryption User
var cryptoServiceEncryptionUserRoleId = 'e147488a-f6f5-4113-8e2d-b22465e65bf6'

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
      exp: keyExpiryEpoch
    }
    rotationPolicy: {
      lifetimeActions: [
        {
          trigger: { timeBeforeExpiry: 'P30D' }
          action: { type: 'rotate' }
        }
      ]
      attributes: { expiryTime: 'P365D' }
    }
  }
}

// --- Disk Encryption Set for VM CMK (linked to HSM-backed key) ---
resource desKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: keyVault
  name: 'key-des-vm-cde'
  properties: {
    kty: 'RSA-HSM'
    keySize: 3072
    keyOps: ['unwrapKey', 'wrapKey', 'encrypt', 'decrypt']
    attributes: {
      enabled: true
      exp: keyExpiryEpoch
    }
    rotationPolicy: {
      lifetimeActions: [
        {
          trigger: { timeBeforeExpiry: 'P30D' }
          action: { type: 'rotate' }
        }
      ]
      attributes: { expiryTime: 'P365D' }
    }
  }
}

resource diskEncryptionSet 'Microsoft.Compute/diskEncryptionSets@2023-10-02' = {
  name: 'des-${orgPrefix}-${environment}-${regionCode}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    encryptionType: 'EncryptionAtRestWithCustomerKey'
    activeKey: {
      keyUrl: desKey.properties.keyUriWithVersion
      sourceVault: { id: keyVault.id }
    }
  }
}

// Allow the DES managed identity to wrap/unwrap the CMK (RBAC-enabled vault).
resource desCryptoRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, diskEncryptionSet.id, cryptoServiceEncryptionUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cryptoServiceEncryptionUserRoleId)
    principalId: diskEncryptionSet.identity.principalId
    principalType: 'ServicePrincipal'
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
output diskEncryptionSetId string = diskEncryptionSet.id
