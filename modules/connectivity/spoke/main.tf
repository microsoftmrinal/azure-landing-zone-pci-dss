variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "address_space" {
  type = list(string)
}

variable "hub_vnet_id" {
  type = string
}

variable "firewall_private_ip" {
  type = string
}

variable "org_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "workload" {
  type = string
}

variable "use_remote_gateways" {
  description = "Use the hub VPN/ER gateway for transit. Must be false until the hub gateway + gateway-transit peering exist."
  type        = bool
  default     = false
}

variable "management_inbound_prefixes" {
  description = "Source prefixes (e.g. the hub Bastion subnet/VNet) allowed inbound to the compute subnet on SSH/RDP. Empty = deny all inbound."
  type        = list(string)
  default     = []
}

variable "common_tags" {
  type = map(string)
}

locals {
  region_code = var.location == "northeurope" ? "neu" : "weu"
}

resource "azurerm_resource_group" "spoke" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.common_tags
}

resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-${var.workload}-${var.environment}-${local.region_code}"
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  address_space       = var.address_space
  tags                = var.common_tags
}

resource "azurerm_subnet" "app_integration" {
  name                 = "snet-app-integration"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.address_space[0], 8, 1)]

  delegation {
    name = "app-service"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action"
      ]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                                      = "snet-private-endpoints"
  resource_group_name                       = azurerm_resource_group.spoke.name
  virtual_network_name                      = azurerm_virtual_network.spoke.name
  address_prefixes                          = [cidrsubnet(var.address_space[0], 8, 2)]
  private_endpoint_network_policies_enabled = true
}

resource "azurerm_subnet" "compute" {
  name                 = "snet-compute"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.address_space[0], 8, 3)]
}

# Route table forcing all traffic through firewall
resource "azurerm_route_table" "spoke" {
  name                          = "rt-${var.workload}-${var.environment}-${local.region_code}"
  location                      = azurerm_resource_group.spoke.location
  resource_group_name           = azurerm_resource_group.spoke.name
  disable_bgp_route_propagation = true
  tags                          = var.common_tags

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.firewall_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "app_integration" {
  subnet_id      = azurerm_subnet.app_integration.id
  route_table_id = azurerm_route_table.spoke.id
}

resource "azurerm_subnet_route_table_association" "private_endpoints" {
  subnet_id      = azurerm_subnet.private_endpoints.id
  route_table_id = azurerm_route_table.spoke.id
}

resource "azurerm_subnet_route_table_association" "compute" {
  subnet_id      = azurerm_subnet.compute.id
  route_table_id = azurerm_route_table.spoke.id
}

# VNet peering spoke -> hub
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                         = "peer-${var.workload}-to-hub"
  resource_group_name          = azurerm_resource_group.spoke.name
  virtual_network_name         = azurerm_virtual_network.spoke.name
  remote_virtual_network_id    = var.hub_vnet_id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
  use_remote_gateways          = var.use_remote_gateways
}

# NSG for compute subnet
resource "azurerm_network_security_group" "compute" {
  name                = "nsg-${var.workload}-compute-${var.environment}-${local.region_code}"
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  tags                = var.common_tags

  # Allow SSH/RDP inbound only from approved management sources (e.g. hub Bastion).
  dynamic "security_rule" {
    for_each = length(var.management_inbound_prefixes) > 0 ? [1] : []
    content {
      name                       = "AllowManagementInbound"
      priority                   = 200
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_ranges    = ["22", "3389"]
      source_address_prefixes    = var.management_inbound_prefixes
      destination_address_prefix = "*"
    }
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "compute" {
  subnet_id                 = azurerm_subnet.compute.id
  network_security_group_id = azurerm_network_security_group.compute.id
}

# NSG for app integration subnet
resource "azurerm_network_security_group" "app_integration" {
  name                = "nsg-${var.workload}-app-${var.environment}-${local.region_code}"
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  tags                = var.common_tags

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "app_integration" {
  subnet_id                 = azurerm_subnet.app_integration.id
  network_security_group_id = azurerm_network_security_group.app_integration.id
}

# NSG for private endpoints subnet
resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-${var.workload}-pe-${var.environment}-${local.region_code}"
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  tags                = var.common_tags

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

output "vnet_id" {
  value = azurerm_virtual_network.spoke.id
}

output "resource_group_name" {
  value = azurerm_resource_group.spoke.name
}

output "app_integration_subnet_id" {
  value = azurerm_subnet.app_integration.id
}

output "private_endpoints_subnet_id" {
  value = azurerm_subnet.private_endpoints.id
}

output "compute_subnet_id" {
  value = azurerm_subnet.compute.id
}
