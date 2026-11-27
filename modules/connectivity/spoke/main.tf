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
  description = "Source prefixes (e.g. the hub Bastion subnet/VNet) allowed inbound to the compute subnet on RDP. Empty = deny all inbound."
  type        = list(string)
  default     = []
}

variable "app_port" {
  description = "HTTPS port the IIS application listens on in the compute subnet"
  type        = number
  default     = 8082
}

variable "app_inbound_prefixes" {
  description = "Private client prefixes (e.g. VPN client B ranges) allowed to reach the application port. Empty = only Front Door via Private Link and load balancer probes."
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

# NAT subnet for the Private Link Service that exposes the IIS load balancer to Front Door.
# Private link service network policies must be disabled on this subnet.
resource "azurerm_subnet" "private_link_service" {
  name                                          = "snet-pls"
  resource_group_name                           = azurerm_resource_group.spoke.name
  virtual_network_name                          = azurerm_virtual_network.spoke.name
  address_prefixes                              = [cidrsubnet(var.address_space[0], 8, 1)]
  private_link_service_network_policies_enabled = false
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

  # Front Door Premium reaches IIS through the Private Link Service NAT subnet.
  security_rule {
    name                       = "AllowAppFromPrivateLink"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(var.app_port)
    source_address_prefixes    = azurerm_subnet.private_link_service.address_prefixes
    destination_address_prefix = "*"
  }

  # Private clients (e.g. client B over VPN, inspected by the hub firewall).
  dynamic "security_rule" {
    for_each = length(var.app_inbound_prefixes) > 0 ? [1] : []
    content {
      name                       = "AllowAppFromPrivateClients"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = tostring(var.app_port)
      source_address_prefixes    = var.app_inbound_prefixes
      destination_address_prefix = "*"
    }
  }

  # Internal load balancer health probes.
  security_rule {
    name                       = "AllowLoadBalancerProbe"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(var.app_port)
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Allow RDP inbound only from approved management sources (e.g. hub Bastion).
  dynamic "security_rule" {
    for_each = length(var.management_inbound_prefixes) > 0 ? [1] : []
    content {
      name                       = "AllowManagementInbound"
      priority                   = 200
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "3389"
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

output "private_link_service_subnet_id" {
  value = azurerm_subnet.private_link_service.id
}

output "private_link_service_subnet_prefixes" {
  value = azurerm_subnet.private_link_service.address_prefixes
}

output "private_endpoints_subnet_id" {
  value = azurerm_subnet.private_endpoints.id
}

output "compute_subnet_id" {
  value = azurerm_subnet.compute.id
}
