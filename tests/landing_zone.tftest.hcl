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
    condition     = one(azurerm_route_table.spoke.route).next_hop_type == "VirtualAppliance"
    error_message = "Default route must point to firewall (VirtualAppliance)"
  }

  assert {
    condition     = one(azurerm_route_table.spoke.route).address_prefix == "0.0.0.0/0"
    error_message = "Default route must be 0.0.0.0/0"
  }

  assert {
    condition     = azurerm_subnet.private_link_service.private_link_service_network_policies_enabled == false
    error_message = "Private Link Service NAT subnet must have private link service network policies disabled"
  }

  assert {
    condition     = contains([for r in azurerm_network_security_group.compute.security_rule : r.name], "AllowAppFromPrivateLink")
    error_message = "Compute NSG must allow the IIS port from the Private Link Service NAT subnet"
  }

  assert {
    condition     = alltrue([for r in azurerm_network_security_group.compute.security_rule : r.destination_port_range != "22"])
    error_message = "SSH (22) must not be opened; the CDE VMs are Windows and managed over RDP via Bastion"
  }
}

run "validate_spoke_opens_app_port_for_vpn_clients" {
  command = plan

  module {
    source = "./modules/connectivity/spoke"
  }

  variables {
    resource_group_name  = "rg-test-spoke"
    location             = "northeurope"
    address_space        = ["10.10.0.0/16"]
    hub_vnet_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet-hub"
    firewall_private_ip  = "10.1.0.4"
    org_prefix           = "test"
    environment          = "test"
    workload             = "cde"
    app_port             = 8082
    app_inbound_prefixes = ["192.168.10.0/24"]
    common_tags          = { Environment = "Test" }
  }

  assert {
    condition     = contains([for r in azurerm_network_security_group.compute.security_rule : r.name], "AllowAppFromPrivateClients")
    error_message = "Compute NSG must allow the IIS port from the configured VPN client prefixes"
  }
}

run "validate_firewall_client_a_and_b_rules" {
  command = plan

  module {
    source = "./modules/connectivity/firewall"
  }

  variables {
    resource_group_name           = "rg-test"
    location                      = "northeurope"
    firewall_subnet_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/AzureFirewallSubnet"
    log_analytics_workspace_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law"
    org_prefix                    = "test"
    environment                   = "test"
    sku_tier                      = "Premium"
    cde_address_prefixes          = ["10.10.0.0/16"]
    app_port                      = 8082
    client_b_inbound_prefixes     = ["192.168.10.0/24"]
    client_a_destination_prefixes = ["203.0.113.20/32"]
    client_a_destination_ports    = ["443"]
    client_a_egress_public_ip_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/pip-clientA-nat-egress"
    common_tags                   = { Environment = "Test" }
  }

  assert {
    condition     = contains([for c in azurerm_firewall_policy_rule_collection_group.cde_rules.network_rule_collection : c.name], "allow-client-b-to-app")
    error_message = "Firewall must allow Client B over VPN to IIS"
  }

  assert {
    condition     = contains([for c in azurerm_firewall_policy_rule_collection_group.cde_rules.network_rule_collection : c.name], "allow-app-to-client-a")
    error_message = "Firewall must allow the CDE application to connect out to Client A"
  }

  assert {
    condition     = length(azurerm_firewall.this.ip_configuration) == 2
    error_message = "The reserved Client A public IP must be added as a second firewall IP configuration"
  }
}

run "validate_firewall_has_no_client_rules_by_default" {
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
    common_tags                = { Environment = "Test" }
  }

  assert {
    condition     = length(azurerm_firewall_policy_rule_collection_group.cde_rules.network_rule_collection) == 1
    error_message = "Without client prefixes only the baseline network rule collection must exist"
  }

  assert {
    condition     = length(azurerm_firewall.this.ip_configuration) == 1
    error_message = "No additional firewall public IP unless client_a_egress_public_ip_id is set"
  }
}

run "validate_iis_vm_behind_internal_lb_and_pls" {
  command = plan

  module {
    source = "./modules/application-platform/compute"
  }

  variables {
    resource_group_name        = "rg-test"
    location                   = "northeurope"
    org_prefix                 = "test"
    environment                = "test"
    subnet_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-compute"
    private_link_nat_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/snet-pls"
    admin_password             = "Pl4ceholder-Only-Not-A-Secret!"
    disk_encryption_set_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/diskEncryptionSets/des-test"
    log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law"
    common_tags                = { Environment = "Test" }
  }

  assert {
    condition     = azurerm_lb_rule.app.frontend_port == 8082 && azurerm_lb_rule.app.backend_port == 8082
    error_message = "Internal load balancer must forward TCP 8082 to IIS"
  }

  assert {
    condition     = azurerm_lb_probe.app.protocol == "Https" && azurerm_lb_probe.app.port == 8082
    error_message = "Load balancer must probe the IIS HTTPS readiness endpoint on 8082"
  }

  assert {
    condition     = azurerm_windows_virtual_machine.iis.secure_boot_enabled == true && azurerm_windows_virtual_machine.iis.vtpm_enabled == true && azurerm_windows_virtual_machine.iis.encryption_at_host_enabled == true
    error_message = "IIS VM must use Trusted Launch and encryption at host"
  }

  assert {
    condition     = length(azurerm_windows_virtual_machine.iis.computer_name) <= 15
    error_message = "Windows computer name must be 15 characters or fewer"
  }

  assert {
    condition     = azurerm_private_link_service.app.nat_ip_configuration[0].primary == true
    error_message = "Private Link Service must have a primary NAT IP configuration"
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
    resource_group_name = "rg-test"
    org_prefix          = "test"
    environment         = "test"
    origin_hostname     = "app.example.com"
    origins = [
      {
        name                    = "neu"
        private_link_service_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateLinkServices/pls-neu"
        location                = "northeurope"
        priority                = 1
      },
      {
        name                    = "weu"
        private_link_service_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/privateLinkServices/pls-weu"
        location                = "westeurope"
        priority                = 2
      },
    ]
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

  assert {
    condition     = alltrue([for o in azurerm_cdn_frontdoor_origin.app : o.https_port == 8082 && o.certificate_name_check_enabled == true])
    error_message = "Origins must use HTTPS on 8082 with certificate name validation"
  }

  assert {
    condition     = azurerm_cdn_frontdoor_origin.app["neu"].priority < azurerm_cdn_frontdoor_origin.app["weu"].priority
    error_message = "North Europe must be the preferred origin; West Europe is the failover origin"
  }
}
