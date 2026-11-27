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
  security_contact_email     = var.security_contact_email
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

  deploy_vpn_gateway     = var.deploy_vpn_gateway
  vpn_gateway_sku        = var.vpn_gateway_sku
  on_prem_gateway_ip     = var.on_prem_gateway_ip
  on_prem_address_spaces = var.on_prem_address_spaces
  vpn_shared_key         = var.vpn_shared_key
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

  cde_address_prefixes          = var.spoke_cde_address_space_primary
  app_port                      = var.app_port
  client_b_inbound_prefixes     = var.client_b_inbound_prefixes
  client_a_destination_prefixes = var.client_a_destination_prefixes
  client_a_destination_ports    = var.client_a_destination_ports
  client_a_egress_public_ip_id  = var.client_a_egress_public_ip_id
}

module "spoke_cde_primary" {
  source = "../../modules/connectivity/spoke"

  providers = {
    azurerm = azurerm.cde
  }

  resource_group_name         = "rg-cde-${var.environment}-neu"
  location                    = var.primary_location
  address_space               = var.spoke_cde_address_space_primary
  hub_vnet_id                 = module.hub_primary.vnet_id
  firewall_private_ip         = module.firewall_primary.private_ip_address
  org_prefix                  = var.org_prefix
  environment                 = var.environment
  workload                    = "cde"
  use_remote_gateways         = var.deploy_vpn_gateway
  management_inbound_prefixes = var.hub_address_space_primary
  app_port                    = var.app_port
  app_inbound_prefixes        = var.client_b_inbound_prefixes
  common_tags                 = var.common_tags

  # Ensure the hub VPN gateway is fully provisioned before the spoke peering
  # requests remote-gateway transit.
  depends_on = [module.hub_primary]
}

# Hub -> spoke peering with gateway transit. Required for the spoke's
# use_remote_gateways to work. Lives on the connectivity (hub) side.
resource "azurerm_virtual_network_peering" "hub_to_spoke_cde" {
  count                        = var.deploy_vpn_gateway ? 1 : 0
  provider                     = azurerm.connectivity
  name                         = "peer-hub-to-cde"
  resource_group_name          = module.hub_primary.resource_group_name
  virtual_network_name         = module.hub_primary.vnet_name
  remote_virtual_network_id    = module.spoke_cde_primary.vnet_id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
  allow_gateway_transit        = true

  depends_on = [module.hub_primary]
}

# Steer VPN-originated traffic for the CDE through the firewall so the VPN path is
# inspected and symmetric with the spoke 0.0.0.0/0 -> firewall route. BGP route
# propagation must stay enabled on the GatewaySubnet route table.
resource "azurerm_route_table" "gateway" {
  count                         = var.deploy_vpn_gateway ? 1 : 0
  provider                      = azurerm.connectivity
  name                          = "rt-gateway-${var.environment}-neu"
  location                      = var.primary_location
  resource_group_name           = module.hub_primary.resource_group_name
  disable_bgp_route_propagation = false
  tags                          = var.common_tags

  dynamic "route" {
    for_each = { for i, p in var.spoke_cde_address_space_primary : "cde-${i}" => p }
    content {
      name                   = route.key
      address_prefix         = route.value
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = module.firewall_primary.private_ip_address
    }
  }
}

resource "azurerm_subnet_route_table_association" "gateway" {
  count          = var.deploy_vpn_gateway ? 1 : 0
  provider       = azurerm.connectivity
  subnet_id      = module.hub_primary.gateway_subnet_id
  route_table_id = azurerm_route_table.gateway[0].id
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

# --- Phase 2: Key Platform (HSM + DES) — required by the client VM ---

module "hsm" {
  source = "../../modules/data-platform/hsm"
  count  = var.deploy_key_platform ? 1 : 0

  providers = {
    azurerm = azurerm.cde
  }

  resource_group_name        = module.spoke_cde_primary.resource_group_name
  location                   = var.primary_location
  org_prefix                 = var.org_prefix
  environment                = var.environment
  subnet_id                  = module.spoke_cde_primary.private_endpoints_subnet_id
  admin_object_ids           = var.hsm_admin_object_ids
  dns_zone_id                = module.dns.keyvault_dns_zone_id
  log_analytics_workspace_id = module.sentinel.workspace_id
  common_tags                = var.common_tags
}

# --- Phase 2b: IIS VM (CDE spoke) behind an internal load balancer + Private Link Service ---

module "compute_cde" {
  source = "../../modules/application-platform/compute"
  count  = var.deploy_compute_vm ? 1 : 0

  providers = {
    azurerm = azurerm.cde
  }

  resource_group_name         = module.spoke_cde_primary.resource_group_name
  location                    = var.primary_location
  org_prefix                  = var.org_prefix
  environment                 = var.environment
  subnet_id                   = module.spoke_cde_primary.compute_subnet_id
  private_link_nat_subnet_id  = module.spoke_cde_primary.private_link_service_subnet_id
  admin_password              = var.vm_admin_password
  disk_encryption_set_id      = module.hsm[0].disk_encryption_set_id
  app_port                    = var.app_port
  app_allowed_source_prefixes = concat(module.spoke_cde_primary.private_link_service_subnet_prefixes, var.client_b_inbound_prefixes)
  log_analytics_workspace_id  = module.sentinel.workspace_id
  common_tags                 = var.common_tags

  depends_on = [module.hsm]
}

# --- Phase 2c: Data Platform (SQL + audit storage) — off by default ---

module "sql" {
  source = "../../modules/data-platform/sql"
  count  = var.deploy_data_platform ? 1 : 0

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
  key_vault_key_id           = module.hsm[0].tde_key_id
  log_analytics_workspace_id = module.sentinel.workspace_id
  dns_zone_id                = module.dns.sql_dns_zone_id
  common_tags                = var.common_tags

  depends_on = [module.hsm]
}

module "storage" {
  source = "../../modules/data-platform/storage"
  count  = var.deploy_data_platform ? 1 : 0

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

# --- Phase 3: Front Door Premium + WAF (private VM origins) — off by default ---
# Requires deploy_compute_vm = true. Approve the Front Door private endpoint connection
# on each regional Private Link Service after apply.

module "front_door" {
  source = "../../modules/connectivity/front-door"
  count  = var.deploy_front_door ? 1 : 0

  providers = {
    azurerm = azurerm.connectivity
  }

  resource_group_name = module.hub_primary.resource_group_name
  org_prefix          = var.org_prefix
  environment         = var.environment
  origin_hostname     = var.app_origin_hostname
  origin_port         = var.app_port
  origins = concat(
    [{
      name                    = "neu"
      private_link_service_id = module.compute_cde[0].private_link_service_id
      location                = var.primary_location
      priority                = 1
    }],
    var.dr_private_link_service_id == null ? [] : [{
      name                    = "weu"
      private_link_service_id = var.dr_private_link_service_id
      location                = var.dr_location
      priority                = 2
    }]
  )
  log_analytics_workspace_id = module.sentinel.workspace_id
  custom_domain_name         = var.custom_domain_name
  common_tags                = var.common_tags
}
