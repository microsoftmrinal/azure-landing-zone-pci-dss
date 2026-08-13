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

variable "integration_subnet_id" {
  description = "Subnet ID for VNet integration (delegated to Microsoft.Web/serverFarms)"
  type        = string
}

variable "private_endpoint_subnet_id" {
  description = "Subnet ID for private endpoint (separate from integration subnet)"
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
  region_code = var.location == "northeurope" ? "neu" : "weu"
}

# App Service Plan - Premium v3, zone-redundant
resource "azurerm_service_plan" "cde" {
  name                   = "asp-${var.org_prefix}-cde-${var.environment}-${local.region_code}"
  location               = var.location
  resource_group_name    = var.resource_group_name
  os_type                = "Linux"
  sku_name               = "P2v3"
  zone_balancing_enabled = true
  tags                   = var.common_tags
}

# App Service - VNet integrated, no public inbound
resource "azurerm_linux_web_app" "cde" {
  name                          = "app-${var.org_prefix}-cde-${var.environment}-${local.region_code}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  service_plan_id               = azurerm_service_plan.cde.id
  https_only                    = true
  public_network_access_enabled = false
  virtual_network_subnet_id     = var.integration_subnet_id
  tags                          = var.common_tags

  site_config {
    minimum_tls_version = "1.2"
    ftps_state          = "Disabled"
    http2_enabled       = true
    always_on           = true
    health_check_path   = "/health"

    ip_restriction_default_action = "Deny"
  }

  auth_settings {
    enabled = true
  }

  client_certificate_enabled = true
  client_certificate_mode    = "OptionalInteractiveUser"

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    "WEBSITE_DNS_SERVER"                 = "168.63.129.16"
    "WEBSITE_VNET_ROUTE_ALL"             = "1"
    "SCM_DO_BUILD_DURING_DEPLOYMENT"     = "true"
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = "" # Set via CI/CD
  }

  logs {
    detailed_error_messages = true
    failed_request_tracing  = true

    http_logs {
      file_system {
        retention_in_days = 30
        retention_in_mb   = 100
      }
    }
    application_logs {
      file_system_level = "Warning"
    }
  }
}

# Private endpoint for App Service (inbound)
resource "azurerm_private_endpoint" "app" {
  name                = "pe-app-${var.org_prefix}-${var.environment}-${local.region_code}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.common_tags

  private_service_connection {
    name                           = "psc-app"
    private_connection_resource_id = azurerm_linux_web_app.cde.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-zone-group-app"
    private_dns_zone_ids = [var.dns_zone_id]
  }
}

# Diagnostic settings
resource "azurerm_monitor_diagnostic_setting" "app" {
  name                       = "diag-app-to-law"
  target_resource_id         = azurerm_linux_web_app.cde.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AppServiceHTTPLogs"
  }

  enabled_log {
    category = "AppServiceConsoleLogs"
  }

  enabled_log {
    category = "AppServiceAuditLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

output "app_service_id" {
  value = azurerm_linux_web_app.cde.id
}

output "default_hostname" {
  value = azurerm_linux_web_app.cde.default_hostname
}

output "app_identity_principal_id" {
  value = azurerm_linux_web_app.cde.identity[0].principal_id
}
