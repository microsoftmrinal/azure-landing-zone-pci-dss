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

variable "log_analytics_workspace_id" {
  type = string
}

variable "dns_zone_id" {
  type = string
}

variable "common_tags" {
  type = map(string)
}

locals {
  region_code = var.location == "northeurope" ? "neu" : "weu"
}

# Immutable audit storage - WORM policy for PCI compliance
resource "azurerm_storage_account" "audit" {
  name                            = "st${var.org_prefix}audit${var.environment}${local.region_code}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "GRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  tags                            = var.common_tags

  blob_properties {
    versioning_enabled = true

    container_delete_retention_policy {
      days = 365
    }

    delete_retention_policy {
      days = 365
    }
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

# Immutability policy for audit logs
resource "azurerm_storage_container" "audit_logs" {
  name                  = "audit-logs"
  storage_account_name  = azurerm_storage_account.audit.name
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "lifecycle" {
  storage_account_id = azurerm_storage_account.audit.id

  rule {
    name    = "archive-after-90-days"
    enabled = true

    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["audit-logs/"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 30
        tier_to_archive_after_days_since_modification_greater_than = 90
      }
    }
  }
}

# Diagnostic settings
resource "azurerm_monitor_diagnostic_setting" "storage" {
  name                       = "diag-storage-to-law"
  target_resource_id         = "${azurerm_storage_account.audit.id}/blobServices/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }

  metric {
    category = "Transaction"
    enabled  = true
  }
}

# Private endpoint
resource "azurerm_private_endpoint" "storage" {
  name                = "pe-st-audit-${var.org_prefix}-${var.environment}-${local.region_code}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_id
  tags                = var.common_tags

  private_service_connection {
    name                           = "psc-blob"
    private_connection_resource_id = azurerm_storage_account.audit.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-zone-group-blob"
    private_dns_zone_ids = [var.dns_zone_id]
  }
}

output "storage_account_id" {
  value = azurerm_storage_account.audit.id
}

output "storage_account_name" {
  value = azurerm_storage_account.audit.name
}
