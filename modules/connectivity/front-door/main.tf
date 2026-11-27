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
  description = "FQDN used for SNI, the origin host header and certificate name validation. Must match the IIS certificate (shared by all regional origins)."
  type        = string
}

variable "origin_port" {
  description = "HTTPS port IIS listens on at the origin"
  type        = number
  default     = 8082
}

variable "health_probe_path" {
  description = "HTTPS readiness path probed on each origin"
  type        = string
  default     = "/health"
}

variable "origins" {
  description = "Regional private origins. Each is an internal load balancer exposed through a Private Link Service. Lowest priority is preferred; higher priorities receive traffic on failover."
  type = list(object({
    name                    = string
    private_link_service_id = string
    location                = string
    priority                = number
    weight                  = optional(number, 1000)
  }))
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
    path                = var.health_probe_path
    protocol            = "Https"
    interval_in_seconds = 30
    request_type        = "GET"
  }
}

# Private origins cannot be mixed with public origins in the same origin group.
# Each connection request must be approved on the regional Private Link Service.
resource "azurerm_cdn_frontdoor_origin" "app" {
  for_each                      = { for o in var.origins : o.name => o }
  name                          = "origin-app-${each.key}-${var.environment}"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.app.id
  enabled                       = true

  certificate_name_check_enabled = true
  host_name                      = var.origin_hostname
  origin_host_header             = var.origin_hostname
  http_port                      = 80
  https_port                     = var.origin_port
  priority                       = each.value.priority
  weight                         = each.value.weight

  private_link {
    location               = each.value.location
    private_link_target_id = each.value.private_link_service_id
    request_message        = "Front Door Private Link"
  }
}

resource "azurerm_cdn_frontdoor_route" "default" {
  name                          = "route-default"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.app.id
  cdn_frontdoor_origin_ids      = [for o in azurerm_cdn_frontdoor_origin.app : o.id]

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
