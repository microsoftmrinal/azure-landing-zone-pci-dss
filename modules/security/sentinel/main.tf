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

variable "common_tags" {
  type = map(string)
}

locals {
  region_code = var.location == "northeurope" ? "neu" : "weu"
}

resource "azurerm_log_analytics_workspace" "central" {
  name                = "law-${var.org_prefix}-${var.environment}-${local.region_code}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 365 # PCI DSS requires minimum 1 year online
  tags                = var.common_tags
}

resource "azurerm_sentinel_log_analytics_workspace_onboarding" "this" {
  workspace_id                 = azurerm_log_analytics_workspace.central.id
  customer_managed_key_enabled = false
}

# Sentinel data connectors
resource "azurerm_sentinel_data_connector_azure_active_directory" "entra" {
  name                       = "dc-entra-id"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.central.id

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

resource "azurerm_sentinel_data_connector_azure_security_center" "defender" {
  name                       = "dc-defender"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.central.id

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

# Analytics rules for PCI-relevant detections
resource "azurerm_sentinel_alert_rule_scheduled" "brute_force" {
  name                       = "pci-brute-force-detection"
  display_name               = "PCI - Brute Force Login Attempts"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.central.id
  severity                   = "High"
  query_frequency            = "PT5M"
  query_period               = "PT1H"
  trigger_operator           = "GreaterThan"
  trigger_threshold          = 0

  query = <<-QUERY
    SigninLogs
    | where ResultType != "0"
    | summarize FailedAttempts = count() by UserPrincipalName, IPAddress, bin(TimeGenerated, 5m)
    | where FailedAttempts >= 10
  QUERY

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

resource "azurerm_sentinel_alert_rule_scheduled" "data_exfil" {
  name                       = "pci-data-exfiltration"
  display_name               = "PCI - Potential Data Exfiltration"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.central.id
  severity                   = "High"
  query_frequency            = "PT10M"
  query_period               = "PT1H"
  trigger_operator           = "GreaterThan"
  trigger_threshold          = 0

  query = <<-QUERY
    AzureDiagnostics
    | where Category == "AzureFirewallNetworkRule" or Category == "AzureFirewallApplicationRule"
    | where msg_s contains "Deny" and msg_s contains "10.10."
    | summarize DeniedConnections = count() by SourceIP = extract(@"(\d+\.\d+\.\d+\.\d+)", 1, msg_s), bin(TimeGenerated, 10m)
    | where DeniedConnections >= 50
  QUERY

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

output "workspace_id" {
  value = azurerm_log_analytics_workspace.central.id
}

output "workspace_name" {
  value = azurerm_log_analytics_workspace.central.name
}
