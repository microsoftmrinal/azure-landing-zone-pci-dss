variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "firewall_subnet_id" {
  type = string
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "org_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "sku_tier" {
  type    = string
  default = "Premium"
}

variable "common_tags" {
  type = map(string)
}

variable "cde_address_prefixes" {
  description = "CDE spoke address space(s): destination of inbound VPN client traffic and source of Client A egress."
  type        = list(string)
  default     = []
}

variable "app_port" {
  description = "HTTPS port IIS listens on"
  type        = number
  default     = 8082
}

variable "client_b_inbound_prefixes" {
  description = "Client B source prefixes allowed to reach the IIS application port over VPN. Empty = no rule."
  type        = list(string)
  default     = []
}

variable "client_a_destination_prefixes" {
  description = "Client A server prefixes the CDE application may connect out to. Empty = no rule."
  type        = list(string)
  default     = []
}

variable "client_a_destination_ports" {
  description = "TCP ports of the Client A server"
  type        = list(string)
  default     = []
}

variable "client_a_egress_public_ip_id" {
  description = "Optional existing Standard static public IP (e.g. pip-clientA-nat-egress) added to the firewall. Azure Firewall chooses among its public IPs for SNAT, so Client A must allow-list every firewall egress IP; this does not pin Client A flows to this address."
  type        = string
  default     = null
}

locals {
  region_code = var.location == "northeurope" ? "neu" : "weu"
}

resource "azurerm_public_ip" "firewall" {
  name                = "pip-fw-${var.org_prefix}-${var.environment}-${local.region_code}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.common_tags
}

resource "azurerm_firewall_policy" "this" {
  name                     = "fwpol-${var.org_prefix}-${var.environment}-${local.region_code}"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  sku                      = var.sku_tier
  threat_intelligence_mode = "Deny"
  tags                     = var.common_tags

  dns {
    proxy_enabled = true
  }

  # IDPS is a Premium-only capability. Omitted on Standard so the policy applies;
  # flip firewall_sku_tier to "Premium" to enable in-place before go-live.
  dynamic "intrusion_detection" {
    for_each = var.sku_tier == "Premium" ? [1] : []
    content {
      mode = "Deny"
    }
  }

  insights {
    enabled                            = true
    default_log_analytics_workspace_id = var.log_analytics_workspace_id
    retention_in_days                  = 365
  }
}

resource "azurerm_firewall" "this" {
  name                = "fw-${var.org_prefix}-${var.environment}-${local.region_code}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "AZFW_VNet"
  sku_tier            = var.sku_tier
  firewall_policy_id  = azurerm_firewall_policy.this.id
  zones               = ["1", "2", "3"]
  tags                = var.common_tags

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = var.firewall_subnet_id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }

  dynamic "ip_configuration" {
    for_each = var.client_a_egress_public_ip_id == null ? [] : [1]
    content {
      name                 = "fw-ipconfig-client-a"
      public_ip_address_id = var.client_a_egress_public_ip_id
    }
  }
}

# Diagnostic settings - send all logs to Log Analytics
resource "azurerm_monitor_diagnostic_setting" "firewall" {
  name                       = "diag-fw-to-law"
  target_resource_id         = azurerm_firewall.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# Network rule collection - allow essential outbound
resource "azurerm_firewall_policy_rule_collection_group" "cde_rules" {
  name               = "rcg-cde-${var.environment}"
  firewall_policy_id = azurerm_firewall_policy.this.id
  priority           = 100

  network_rule_collection {
    name     = "allow-azure-services"
    priority = 100
    action   = "Allow"

    rule {
      name                  = "allow-dns"
      protocols             = ["UDP"]
      source_addresses      = ["10.0.0.0/8"]
      destination_addresses = ["168.63.129.16"]
      destination_ports     = ["53"]
    }

    rule {
      name                  = "allow-ntp"
      protocols             = ["UDP"]
      source_addresses      = ["10.0.0.0/8"]
      destination_addresses = ["*"]
      destination_ports     = ["123"]
    }

    rule {
      name              = "allow-azure-monitor"
      protocols         = ["TCP"]
      source_addresses  = ["10.0.0.0/8"]
      destination_fqdns = ["*.ods.opinsights.azure.com", "*.oms.opinsights.azure.com", "*.monitoring.azure.com"]
      destination_ports = ["443"]
    }

    rule {
      name              = "allow-windows-activation"
      protocols         = ["TCP"]
      source_addresses  = ["10.0.0.0/8"]
      destination_fqdns = ["azkms.core.windows.net", "kms.core.windows.net"]
      destination_ports = ["1688"]
    }
  }

  # Client B (VPN) -> IIS. Source prefixes must be the real partner ranges.
  dynamic "network_rule_collection" {
    for_each = length(var.client_b_inbound_prefixes) > 0 && length(var.cde_address_prefixes) > 0 ? [1] : []
    content {
      name     = "allow-client-b-to-app"
      priority = 110
      action   = "Allow"

      rule {
        name                  = "client-b-to-iis"
        protocols             = ["TCP"]
        source_addresses      = var.client_b_inbound_prefixes
        destination_addresses = var.cde_address_prefixes
        destination_ports     = [tostring(var.app_port)]
      }
    }
  }

  # CDE application -> Client A server (connection initiated by the custom app on the VM).
  dynamic "network_rule_collection" {
    for_each = length(var.client_a_destination_prefixes) > 0 && length(var.client_a_destination_ports) > 0 && length(var.cde_address_prefixes) > 0 ? [1] : []
    content {
      name     = "allow-app-to-client-a"
      priority = 120
      action   = "Allow"

      rule {
        name                  = "app-to-client-a"
        protocols             = ["TCP"]
        source_addresses      = var.cde_address_prefixes
        destination_addresses = var.client_a_destination_prefixes
        destination_ports     = var.client_a_destination_ports
      }
    }
  }

  application_rule_collection {
    name     = "allow-microsoft-updates"
    priority = 200
    action   = "Allow"

    rule {
      name = "windows-update"
      protocols {
        type = "Https"
        port = 443
      }
      source_addresses  = ["10.0.0.0/8"]
      destination_fqdns = ["*.update.microsoft.com", "*.windowsupdate.com"]
    }

    rule {
      name = "entra-id-vm-login"
      protocols {
        type = "Https"
        port = 443
      }
      source_addresses  = ["10.0.0.0/8"]
      destination_fqdns = ["login.microsoftonline.com", "enterpriseregistration.windows.net", "device.login.microsoftonline.com", "pas.windows.net"]
    }
  }
}

output "private_ip_address" {
  value = azurerm_firewall.this.ip_configuration[0].private_ip_address
}

output "firewall_id" {
  value = azurerm_firewall.this.id
}

output "public_ip_address" {
  description = "Primary firewall public IP. Client A must also allow-list any additional firewall public IP."
  value       = azurerm_public_ip.firewall.ip_address
}

output "firewall_policy_id" {
  value = azurerm_firewall_policy.this.id
}
