variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "dr_location" {
  type = string
}

variable "org_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "subnet_id" {
  description = "Subnet ID for private endpoint"
  type        = string
}

variable "admin_object_id" {
  description = "Entra ID object ID of the SQL administrator group"
  type        = string
}

variable "admin_login_name" {
  type = string
}

variable "key_vault_key_id" {
  description = "Key Vault key ID for TDE CMK"
  type        = string
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
  region_code    = var.location == "northeurope" ? "neu" : "weu"
  dr_region_code = var.dr_location == "westeurope" ? "weu" : "neu"
}

# Primary SQL Server
resource "azurerm_mssql_server" "primary" {
  name                          = "sql-${var.org_prefix}-${var.environment}-${local.region_code}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  tags                          = var.common_tags

  azuread_administrator {
    login_username              = var.admin_login_name
    object_id                   = var.admin_object_id
    azuread_authentication_only = true
  }

  identity {
    type = "SystemAssigned"
  }
}

# DR SQL Server
resource "azurerm_mssql_server" "secondary" {
  name                          = "sql-${var.org_prefix}-${var.environment}-${local.dr_region_code}"
  resource_group_name           = var.resource_group_name
  location                      = var.dr_location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  tags                          = var.common_tags

  azuread_administrator {
    login_username              = var.admin_login_name
    object_id                   = var.admin_object_id
    azuread_authentication_only = true
  }

  identity {
    type = "SystemAssigned"
  }
}

# Database with Business Critical tier
resource "azurerm_mssql_database" "cde" {
  name                        = "sqldb-${var.org_prefix}-cde-${var.environment}"
  server_id                   = azurerm_mssql_server.primary.id
  sku_name                    = "BC_Gen5_4"
  zone_redundant              = true
  max_size_gb                 = 256
  min_capacity                = 0.5
  auto_pause_delay_in_minutes = -1 # Never auto-pause for production
  tags                        = var.common_tags

  transparent_data_encryption_key_vault_key_id = var.key_vault_key_id

  threat_detection_policy {
    state                = "Enabled"
    email_account_admins = "Enabled"
    retention_days       = 365
  }

  long_term_retention_policy {
    weekly_retention  = "P4W"
    monthly_retention = "P12M"
    yearly_retention  = "P7Y"
    week_of_year      = 1
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Failover group
resource "azurerm_mssql_failover_group" "cde" {
  name      = "fog-${var.org_prefix}-cde-${var.environment}"
  server_id = azurerm_mssql_server.primary.id

  databases = [azurerm_mssql_database.cde.id]

  partner_server {
    id = azurerm_mssql_server.secondary.id
  }

  read_write_endpoint_failover_policy {
    mode          = "Automatic"
    grace_minutes = 60
  }

  tags = var.common_tags
}

# Auditing
resource "azurerm_mssql_server_extended_auditing_policy" "primary" {
  server_id              = azurerm_mssql_server.primary.id
  log_monitoring_enabled = true
  retention_in_days      = 365
}

resource "azurerm_mssql_server_extended_auditing_policy" "secondary" {
  server_id              = azurerm_mssql_server.secondary.id
  log_monitoring_enabled = true
  retention_in_days      = 365
}

# Diagnostic settings
resource "azurerm_monitor_diagnostic_setting" "sql" {
  name                       = "diag-sql-to-law"
  target_resource_id         = azurerm_mssql_database.cde.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "SQLSecurityAuditEvents"
  }

  enabled_log {
    category = "AutomaticTuning"
  }

  metric {
    category = "Basic"
    enabled  = true
  }
}

# Private endpoint
resource "azurerm_private_endpoint" "sql" {
  name                = "pe-sql-${var.org_prefix}-${var.environment}-${local.region_code}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_id
  tags                = var.common_tags

  private_service_connection {
    name                           = "psc-sql"
    private_connection_resource_id = azurerm_mssql_server.primary.id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-zone-group-sql"
    private_dns_zone_ids = [var.dns_zone_id]
  }
}

output "server_fqdn" {
  value = azurerm_mssql_server.primary.fully_qualified_domain_name
}

output "server_id" {
  value = azurerm_mssql_server.primary.id
}

output "failover_group_fqdn" {
  value = "${azurerm_mssql_failover_group.cde.name}.database.windows.net"
}
