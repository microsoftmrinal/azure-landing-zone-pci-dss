variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "org_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "admin_object_ids" {
  description = "List of Entra ID object IDs for HSM administrators"
  type        = list(string)
}

variable "dns_zone_id" {
  type = string
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "common_tags" {
  type = map(string)
}

locals {
  region_code = var.location == "northeurope" ? "neu" : "weu"
}

# Managed HSM for key management (FIPS 140-2 Level 3)
resource "azurerm_key_vault_managed_hardware_security_module" "this" {
  name                       = "hsm-${var.org_prefix}-${var.environment}-${local.region_code}"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  sku_name                   = "Standard_B1"
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  admin_object_ids           = var.admin_object_ids
  purge_protection_enabled   = true
  soft_delete_retention_days = 90
  tags                       = var.common_tags

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Key Vault for application secrets (non-key material)
resource "azurerm_key_vault" "cde" {
  name                          = "kv-${var.org_prefix}-${var.environment}-${local.region_code}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "premium"
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90
  public_network_access_enabled = false
  enable_rbac_authorization     = true
  tags                          = var.common_tags

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# TDE key for SQL Server CMK
resource "azurerm_key_vault_key" "tde" {
  name            = "key-tde-sql-cde"
  key_vault_id    = azurerm_key_vault.cde.id
  key_type        = "RSA-HSM"
  key_size        = 3072
  expiration_date = timeadd(timestamp(), "8760h")

  key_opts = [
    "unwrapKey",
    "wrapKey",
  ]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }
    expire_after         = "P365D"
    notify_before_expiry = "P30D"
  }
}

# Private endpoint for Key Vault
resource "azurerm_private_endpoint" "keyvault" {
  name                = "pe-kv-${var.org_prefix}-${var.environment}-${local.region_code}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_id
  tags                = var.common_tags

  private_service_connection {
    name                           = "psc-keyvault"
    private_connection_resource_id = azurerm_key_vault.cde.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-zone-group-kv"
    private_dns_zone_ids = [var.dns_zone_id]
  }
}

# Diagnostic settings for Key Vault
resource "azurerm_monitor_diagnostic_setting" "keyvault" {
  name                       = "diag-kv-to-law"
  target_resource_id         = azurerm_key_vault.cde.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

data "azurerm_client_config" "current" {}

# --- Disk Encryption Set for VM CMK (linked to HSM-backed key) ---
resource "azurerm_key_vault_key" "des" {
  name            = "key-des-vm-cde"
  key_vault_id    = azurerm_key_vault.cde.id
  key_type        = "RSA-HSM"
  key_size        = 3072
  expiration_date = timeadd(timestamp(), "8760h")

  key_opts = [
    "unwrapKey",
    "wrapKey",
    "encrypt",
    "decrypt",
  ]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }
    expire_after         = "P365D"
    notify_before_expiry = "P30D"
  }
}

resource "azurerm_disk_encryption_set" "vm" {
  name                = "des-${var.org_prefix}-${var.environment}-${local.region_code}"
  resource_group_name = var.resource_group_name
  location            = var.location
  key_vault_key_id    = azurerm_key_vault_key.des.id
  tags                = var.common_tags

  identity {
    type = "SystemAssigned"
  }
}

# Allow the DES managed identity to wrap/unwrap the CMK (RBAC-enabled vault).
resource "azurerm_role_assignment" "des_kv_crypto" {
  scope                = azurerm_key_vault.cde.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_disk_encryption_set.vm.identity[0].principal_id
}

output "key_vault_id" {
  value = azurerm_key_vault.cde.id
}

output "key_vault_uri" {
  value = azurerm_key_vault.cde.vault_uri
}

output "tde_key_id" {
  value = azurerm_key_vault_key.tde.id
}

output "hsm_id" {
  value = azurerm_key_vault_managed_hardware_security_module.this.id
}

output "disk_encryption_set_id" {
  value = azurerm_disk_encryption_set.vm.id
}
