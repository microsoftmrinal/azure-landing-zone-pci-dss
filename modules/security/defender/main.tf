variable "log_analytics_workspace_id" {
  type = string
}

variable "common_tags" {
  type = map(string)
}

# Enable all Defender for Cloud plans
resource "azurerm_security_center_subscription_pricing" "servers" {
  tier          = "Standard"
  resource_type = "VirtualMachines"
}

resource "azurerm_security_center_subscription_pricing" "app_services" {
  tier          = "Standard"
  resource_type = "AppServices"
}

resource "azurerm_security_center_subscription_pricing" "sql" {
  tier          = "Standard"
  resource_type = "SqlServers"
}

resource "azurerm_security_center_subscription_pricing" "sql_vms" {
  tier          = "Standard"
  resource_type = "SqlServerVirtualMachines"
}

resource "azurerm_security_center_subscription_pricing" "storage" {
  tier          = "Standard"
  resource_type = "StorageAccounts"
  subplan       = "DefenderForStorageV2"
}

resource "azurerm_security_center_subscription_pricing" "containers" {
  tier          = "Standard"
  resource_type = "Containers"
}

resource "azurerm_security_center_subscription_pricing" "key_vaults" {
  tier          = "Standard"
  resource_type = "KeyVaults"
}

resource "azurerm_security_center_subscription_pricing" "arm" {
  tier          = "Standard"
  resource_type = "Arm"
}

resource "azurerm_security_center_subscription_pricing" "dns" {
  tier          = "Standard"
  resource_type = "Dns"
}

# Export to Log Analytics
resource "azurerm_security_center_workspace" "this" {
  scope        = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  workspace_id = var.log_analytics_workspace_id
}

# Auto-provisioning of monitoring agent
resource "azurerm_security_center_auto_provisioning" "this" {
  auto_provision = "On"
}

# Security contacts for PCI alerting
resource "azurerm_security_center_contact" "this" {
  email               = "security@payment24.com"
  phone               = "+31000000000"
  alert_notifications = true
  alerts_to_admins    = true
}

data "azurerm_client_config" "current" {}
