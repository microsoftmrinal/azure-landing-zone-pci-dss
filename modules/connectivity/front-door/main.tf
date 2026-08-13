variable "resource_group_name" {
  type = string
}

variable "org_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "origin_hostname" {
  description = "App Service default hostname to use as private origin"
  type        = string
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "custom_domain_name" {
  type    = string
  default = ""
}

variable "common_tags" {
  type = map(string)
}

resource "azurerm_cdn_frontdoor_profile" "this" {
  name                = "afd-${var.org_prefix}-${var.environment}"
  resource_group_name = var.resource_group_name
  sku_name            = "Premium_AzureFrontDoor"
  tags                = var.common_tags
}

resource "azurerm_cdn_frontdoor_endpoint" "this" {
  name                     = "fde-${var.org_prefix}-${var.environment}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  tags                     = var.common_tags
}

resource "azurerm_cdn_frontdoor_origin_group" "app" {
  name                     = "og-app-${var.environment}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  session_affinity_enabled = false

  load_balancing {
    sample_size                 = 4
    successful_samples_required = 3
  }

  health_probe {
    path                = "/health"
    protocol            = "Https"
    interval_in_seconds = 30
    request_type        = "HEAD"
  }
}

resource "azurerm_cdn_frontdoor_origin" "app" {
  name                          = "origin-app-${var.environment}"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.app.id
  enabled                       = true

  certificate_name_check_enabled = true
  host_name                      = var.origin_hostname
  origin_host_header             = var.origin_hostname
  http_port                      = 80
  https_port                     = 443
  priority                       = 1
  weight                         = 1000

  private_link {
    location               = "northeurope"
    private_link_target_id = "/subscriptions/placeholder" # resolved at deploy time via data source
    request_message        = "Front Door Private Link"
    target_type            = "sites"
  }
}

resource "azurerm_cdn_frontdoor_route" "default" {
  name                          = "route-default"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.app.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.app.id]

  supported_protocols    = ["Https"]
  https_redirect_enabled = true
  patterns_to_match      = ["/*"]
  forwarding_protocol    = "HttpsOnly"

  link_to_default_domain = true
}

# WAF Policy - OWASP rules
resource "azurerm_cdn_frontdoor_firewall_policy" "waf" {
  name                = "wafpol${var.org_prefix}${var.environment}"
  resource_group_name = var.resource_group_name
  sku_name            = "Premium_AzureFrontDoor"
  mode                = "Prevention"
  tags                = var.common_tags

  managed_rule {
    type    = "Microsoft_DefaultRuleSet"
    version = "2.1"
    action  = "Block"
  }

  managed_rule {
    type    = "Microsoft_BotManagerRuleSet"
    version = "1.0"
    action  = "Block"
  }
}

resource "azurerm_cdn_frontdoor_security_policy" "waf" {
  name                     = "secpol-waf-${var.environment}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.waf.id

      association {
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.this.id
        }
        patterns_to_match = ["/*"]
      }
    }
  }
}

# Diagnostics
resource "azurerm_monitor_diagnostic_setting" "front_door" {
  name                       = "diag-afd-to-law"
  target_resource_id         = azurerm_cdn_frontdoor_profile.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

output "endpoint_hostname" {
  value = azurerm_cdn_frontdoor_endpoint.this.host_name
}

output "profile_id" {
  value = azurerm_cdn_frontdoor_profile.this.id
}
