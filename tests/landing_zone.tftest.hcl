variables {
  connectivity_subscription_id = "00000000-0000-0000-0000-000000000000"
  management_subscription_id   = "00000000-0000-0000-0000-000000000000"
  cde_subscription_id          = "00000000-0000-0000-0000-000000000000"
  sql_admin_object_id          = "00000000-0000-0000-0000-000000000000"
  hsm_admin_object_ids         = ["00000000-0000-0000-0000-000000000000"]
}

run "validate_management_groups" {
  command = plan

  module {
    source = "./modules/management-groups"
  }

  variables {
    org_prefix  = "test"
    common_tags = { Environment = "Test" }
  }

  assert {
    condition     = azurerm_management_group.cde.display_name == "CDE-Prod"
    error_message = "CDE management group must be named CDE-Prod"
  }

  assert {
    condition     = azurerm_management_group.intermediate_root.display_name == "TEST-Root"
    error_message = "Intermediate root must use uppercased org prefix"
  }
}

run "validate_policy_requires_premium_firewall" {
  command = plan

  module {
    source = "./modules/policy"
  }

  variables {
    cde_management_group_id  = "/providers/Microsoft.Management/managementGroups/test-cde"
    root_management_group_id = "/providers/Microsoft.Management/managementGroups/test-root"
    primary_location         = "northeurope"
    dr_location              = "westeurope"
    common_tags              = { Environment = "Test" }
  }

  assert {
    condition     = azurerm_management_group_policy_assignment.pci_dss_v4.display_name == "PCI DSS v4 - CDE"
    error_message = "PCI DSS v4 policy assignment must target CDE"
  }
}

run "validate_hub_creates_required_subnets" {
  command = plan

  module {
    source = "./modules/connectivity/hub"
  }

  variables {
    resource_group_name = "rg-test-hub"
    location            = "northeurope"
    address_space       = ["10.1.0.0/16"]
    org_prefix          = "test"
    environment         = "test"
    common_tags         = { Environment = "Test" }
  }

  assert {
    condition     = azurerm_subnet.firewall.name == "AzureFirewallSubnet"
    error_message = "Firewall subnet must be named AzureFirewallSubnet"
  }

  assert {
    condition     = azurerm_subnet.gateway.name == "GatewaySubnet"
    error_message = "Gateway subnet must be named GatewaySubnet"
  }

  assert {
    condition     = azurerm_subnet.bastion.name == "AzureBastionSubnet"
    error_message = "Bastion subnet must be named AzureBastionSubnet"
  }
}

run "validate_firewall_must_be_premium" {
  command = plan

  module {
    source = "./modules/connectivity/firewall"
  }

  variables {
    resource_group_name        = "rg-test"
    location                   = "northeurope"
    firewall_subnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/AzureFirewallSubnet"
    log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law"
    org_prefix                 = "test"
    environment                = "test"
    sku_tier                   = "Premium"
    common_tags                = { Environment = "Test" }
  }

  assert {
    condition     = azurerm_firewall.this.sku_tier == "Premium"
    error_message = "Firewall must be Premium tier for PCI-DSS IDPS"
  }

  assert {
    condition     = azurerm_firewall_policy.this.intrusion_detection[0].mode == "Deny"
    error_message = "IDPS must be in Deny mode for PCI-DSS"
  }

  assert {
    condition     = azurerm_firewall_policy.this.threat_intelligence_mode == "Deny"
    error_message = "Threat intelligence must be in Deny mode"
  }
}

run "validate_spoke_forces_traffic_through_firewall" {
  command = plan

  module {
    source = "./modules/connectivity/spoke"
  }

  variables {
    resource_group_name = "rg-test-spoke"
    location            = "northeurope"
    address_space       = ["10.10.0.0/16"]
    hub_vnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet-hub"
    firewall_private_ip = "10.1.0.4"
    org_prefix          = "test"
    environment         = "test"
    workload            = "cde"
    common_tags         = { Environment = "Test" }
  }

  assert {
    condition     = azurerm_route_table.spoke.disable_bgp_route_propagation == true
    error_message = "BGP propagation must be disabled on spoke to prevent firewall bypass"
  }

  assert {
    condition     = azurerm_route_table.spoke.route[0].next_hop_type == "VirtualAppliance"
    error_message = "Default route must point to firewall (VirtualAppliance)"
  }

  assert {
    condition     = azurerm_route_table.spoke.route[0].address_prefix == "0.0.0.0/0"
    error_message = "Default route must be 0.0.0.0/0"
  }
}

run "validate_sql_is_private_and_entra_only" {
  command = plan

  module {
    source = "./modules/data-platform/sql"
  }

  variables {
    resource_group_name        = "rg-test"
    location                   = "northeurope"
    dr_location                = "westeurope"
    org_prefix                 = "test"
    environment                = "test"
    subnet_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-pe"
    admin_object_id            = "00000000-0000-0000-0000-000000000000"
    admin_login_name           = "sg-sql-admins"
    key_vault_key_id           = "https://kv-test.vault.azure.net/keys/tde/version1"
    log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law"
    dns_zone_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.database.windows.net"
    common_tags                = { Environment = "Test" }
  }

  assert {
    condition     = azurerm_mssql_server.primary.public_network_access_enabled == false
    error_message = "SQL Server must have public access disabled"
  }

  assert {
    condition     = azurerm_mssql_server.primary.azuread_administrator[0].azuread_authentication_only == true
    error_message = "SQL must use Entra-only authentication (no SQL auth)"
  }

  assert {
    condition     = azurerm_mssql_server.primary.minimum_tls_version == "1.2"
    error_message = "SQL must require TLS 1.2 minimum"
  }

  assert {
    condition     = azurerm_mssql_database.cde.zone_redundant == true
    error_message = "SQL database must be zone-redundant"
  }
}

run "validate_storage_is_immutable_and_private" {
  command = plan

  module {
    source = "./modules/data-platform/storage"
  }

  variables {
    resource_group_name        = "rg-test"
    location                   = "northeurope"
    org_prefix                 = "test"
    environment                = "test"
    subnet_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-pe"
    log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law"
    dns_zone_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
    common_tags                = { Environment = "Test" }
  }

  assert {
    condition     = azurerm_storage_account.audit.public_network_access_enabled == false
    error_message = "Storage must have public access disabled"
  }

  assert {
    condition     = azurerm_storage_account.audit.min_tls_version == "TLS1_2"
    error_message = "Storage must require TLS 1.2"
  }

  assert {
    condition     = azurerm_storage_account.audit.shared_access_key_enabled == false
    error_message = "Shared access keys must be disabled (use Entra auth)"
  }

  assert {
    condition     = azurerm_storage_account.audit.allow_nested_items_to_be_public == false
    error_message = "Public blob access must be disabled"
  }
}

run "validate_waf_in_prevention_mode" {
  command = plan

  module {
    source = "./modules/connectivity/front-door"
  }

  variables {
    resource_group_name        = "rg-test"
    org_prefix                 = "test"
    environment                = "test"
    origin_hostname            = "app-test.azurewebsites.net"
    origin_app_service_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Web/sites/app-test"
    log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law"
    common_tags                = { Environment = "Test" }
  }

  assert {
    condition     = azurerm_cdn_frontdoor_firewall_policy.waf.mode == "Prevention"
    error_message = "WAF must be in Prevention mode for PCI-DSS"
  }

  assert {
    condition     = azurerm_cdn_frontdoor_profile.this.sku_name == "Premium_AzureFrontDoor"
    error_message = "Front Door must be Premium SKU for Private Link support"
  }
}
