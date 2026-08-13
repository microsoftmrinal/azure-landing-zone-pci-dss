# --- Phase 0: Foundation & Governance ---

module "management_groups" {
  source = "../../modules/management-groups"

  org_prefix  = var.org_prefix
  common_tags = var.common_tags
}

module "policy" {
  source = "../../modules/policy"

  cde_management_group_id  = module.management_groups.cde_management_group_id
  root_management_group_id = module.management_groups.intermediate_root_id
  primary_location         = var.primary_location
  dr_location              = var.dr_location
  common_tags              = var.common_tags

  depends_on = [module.management_groups]
}

module "sentinel" {
  source = "../../modules/security/sentinel"

  providers = {
    azurerm = azurerm.management
  }

  resource_group_name = "rg-mgmt-${var.environment}-neu"
  location            = var.primary_location
  org_prefix          = var.org_prefix
  environment         = var.environment
  common_tags         = var.common_tags
}

module "defender" {
  source = "../../modules/security/defender"

  providers = {
    azurerm = azurerm.cde
  }

  log_analytics_workspace_id = module.sentinel.workspace_id
  common_tags                = var.common_tags
}

# --- Phase 1: Connectivity & Security ---

module "hub_primary" {
  source = "../../modules/connectivity/hub"

  providers = {
    azurerm = azurerm.connectivity
  }

  resource_group_name = "rg-conn-${var.environment}-neu"
  location            = var.primary_location
  address_space       = var.hub_address_space_primary
  org_prefix          = var.org_prefix
  environment         = var.environment
  common_tags         = var.common_tags
}

module "firewall_primary" {
  source = "../../modules/connectivity/firewall"

  providers = {
    azurerm = azurerm.connectivity
  }

  resource_group_name        = module.hub_primary.resource_group_name
  location                   = var.primary_location
  firewall_subnet_id         = module.hub_primary.firewall_subnet_id
  log_analytics_workspace_id = module.sentinel.workspace_id
  org_prefix                 = var.org_prefix
  environment                = var.environment
  sku_tier                   = var.firewall_sku_tier
  common_tags                = var.common_tags
}

module "spoke_cde_primary" {
  source = "../../modules/connectivity/spoke"

  providers = {
    azurerm = azurerm.cde
  }

  resource_group_name  = "rg-cde-${var.environment}-neu"
  location             = var.primary_location
  address_space        = var.spoke_cde_address_space_primary
  hub_vnet_id          = module.hub_primary.vnet_id
  firewall_private_ip  = module.firewall_primary.private_ip_address
  org_prefix           = var.org_prefix
  environment          = var.environment
  workload             = "cde"
  common_tags          = var.common_tags
}

module "dns" {
  source = "../../modules/connectivity/dns"

  providers = {
    azurerm = azurerm.connectivity
  }

  resource_group_name = module.hub_primary.resource_group_name
  hub_vnet_id         = module.hub_primary.vnet_id
  common_tags         = var.common_tags
}

# --- Phase 2: Data & Key Platform ---

module "hsm" {
  source = "../../modules/data-platform/hsm"

  providers = {
    azurerm = azurerm.cde
  }

  resource_group_name = module.spoke_cde_primary.resource_group_name
  location            = var.primary_location
  org_prefix          = var.org_prefix
  environment         = var.environment
  subnet_id           = module.spoke_cde_primary.private_endpoints_subnet_id
  admin_object_ids    = var.hsm_admin_object_ids
  dns_zone_id         = module.dns.keyvault_dns_zone_id
  common_tags         = var.common_tags
}

module "sql" {
  source = "../../modules/data-platform/sql"

  providers = {
    azurerm = azurerm.cde
  }

  resource_group_name        = module.spoke_cde_primary.resource_group_name
  location                   = var.primary_location
  dr_location                = var.dr_location
  org_prefix                 = var.org_prefix
  environment                = var.environment
  subnet_id                  = module.spoke_cde_primary.private_endpoints_subnet_id
  admin_object_id            = var.sql_admin_object_id
  admin_login_name           = var.sql_admin_login_name
  key_vault_key_id           = module.hsm.tde_key_id
  log_analytics_workspace_id = module.sentinel.workspace_id
  dns_zone_id                = module.dns.sql_dns_zone_id
  common_tags                = var.common_tags
}

module "storage" {
  source = "../../modules/data-platform/storage"

  providers = {
    azurerm = azurerm.cde
  }

  resource_group_name        = module.spoke_cde_primary.resource_group_name
  location                   = var.primary_location
  org_prefix                 = var.org_prefix
  environment                = var.environment
  subnet_id                  = module.spoke_cde_primary.private_endpoints_subnet_id
  log_analytics_workspace_id = module.sentinel.workspace_id
  dns_zone_id                = module.dns.blob_dns_zone_id
  common_tags                = var.common_tags
}

# --- Phase 3: Application Platform ---

module "app_service" {
  source = "../../modules/application-platform/app-service"

  providers = {
    azurerm = azurerm.cde
  }

  resource_group_name        = module.spoke_cde_primary.resource_group_name
  location                   = var.primary_location
  org_prefix                 = var.org_prefix
  environment                = var.environment
  integration_subnet_id      = module.spoke_cde_primary.app_integration_subnet_id
  private_endpoint_subnet_id = module.spoke_cde_primary.private_endpoints_subnet_id
  log_analytics_workspace_id = module.sentinel.workspace_id
  dns_zone_id                = module.dns.appservice_dns_zone_id
  common_tags                = var.common_tags
}

module "front_door" {
  source = "../../modules/connectivity/front-door"

  providers = {
    azurerm = azurerm.connectivity
  }

  resource_group_name        = module.hub_primary.resource_group_name
  org_prefix                 = var.org_prefix
  environment                = var.environment
  origin_hostname            = module.app_service.default_hostname
  log_analytics_workspace_id = module.sentinel.workspace_id
  custom_domain_name         = var.custom_domain_name
  common_tags                = var.common_tags
}
