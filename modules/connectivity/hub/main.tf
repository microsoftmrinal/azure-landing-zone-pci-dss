variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "address_space" {
  type = list(string)
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

# --- VPN Gateway ---
variable "deploy_vpn_gateway" {
  type    = bool
  default = false
}

variable "vpn_gateway_sku" {
  type    = string
  default = "VpnGw2AZ"
}

variable "on_prem_gateway_ip" {
  description = "On-premises / remote-tenant VPN device public IP. When set, a S2S connection is created."
  type        = string
  default     = null
}

variable "on_prem_address_spaces" {
  description = "Remote network address spaces reachable over the S2S tunnel."
  type        = list(string)
  default     = []
}

variable "vpn_shared_key" {
  description = "Pre-shared key for the S2S connection."
  type        = string
  sensitive   = true
  default     = null
}

locals {
  region_code = var.location == "northeurope" ? "neu" : "weu"
}

resource "azurerm_resource_group" "hub" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.common_tags
}

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-hub-${var.environment}-${local.region_code}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  address_space       = var.address_space
  tags                = var.common_tags
}

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.address_space[0], 10, 0)] # /26
}

resource "azurerm_subnet" "firewall_management" {
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.address_space[0], 10, 1)]
}

resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.address_space[0], 10, 2)]
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.address_space[0], 10, 3)]
}

resource "azurerm_subnet" "dns_resolver" {
  name                 = "snet-dns-resolver"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.address_space[0], 10, 4)]

  delegation {
    name = "dns-resolver"
    service_delegation {
      name = "Microsoft.Network/dnsResolvers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}

# Bastion host
resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion-${var.environment}-${local.region_code}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.common_tags
}

resource "azurerm_bastion_host" "hub" {
  name                = "bas-${var.org_prefix}-${var.environment}-${local.region_code}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  sku                 = "Standard"
  tunneling_enabled   = true
  tags                = var.common_tags

  ip_configuration {
    name                 = "bastion-ipconfig"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

# DDoS Protection Plan
resource "azurerm_network_ddos_protection_plan" "hub" {
  name                = "ddos-${var.org_prefix}-${var.environment}-${local.region_code}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  tags                = var.common_tags
}

# --- VPN Gateway (hub/spoke S2S) ---
resource "azurerm_public_ip" "vpngw" {
  count               = var.deploy_vpn_gateway ? 1 : 0
  name                = "pip-vpngw-${var.org_prefix}-${var.environment}-${local.region_code}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.common_tags
}

resource "azurerm_virtual_network_gateway" "vpn" {
  count               = var.deploy_vpn_gateway ? 1 : 0
  name                = "vpngw-${var.org_prefix}-${var.environment}-${local.region_code}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = var.vpn_gateway_sku
  generation          = "Generation2"
  active_active       = false
  enable_bgp          = false
  tags                = var.common_tags

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.vpngw[0].id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway.id
  }
}

# Optional site-to-site connection to the remote/on-prem device.
# Created only when an on-prem gateway IP is supplied.
resource "azurerm_local_network_gateway" "onprem" {
  count               = var.deploy_vpn_gateway && var.on_prem_gateway_ip != null ? 1 : 0
  name                = "lng-${var.org_prefix}-${var.environment}-${local.region_code}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  gateway_address     = var.on_prem_gateway_ip
  address_space       = var.on_prem_address_spaces
  tags                = var.common_tags
}

resource "azurerm_virtual_network_gateway_connection" "onprem" {
  count                      = var.deploy_vpn_gateway && var.on_prem_gateway_ip != null ? 1 : 0
  name                       = "cn-${var.org_prefix}-${var.environment}-${local.region_code}"
  location                   = azurerm_resource_group.hub.location
  resource_group_name        = azurerm_resource_group.hub.name
  type                       = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.vpn[0].id
  local_network_gateway_id   = azurerm_local_network_gateway.onprem[0].id
  shared_key                 = var.vpn_shared_key
  tags                       = var.common_tags
}

output "vnet_id" {
  value = azurerm_virtual_network.hub.id
}

output "vnet_name" {
  value = azurerm_virtual_network.hub.name
}

output "resource_group_name" {
  value = azurerm_resource_group.hub.name
}

output "firewall_subnet_id" {
  value = azurerm_subnet.firewall.id
}

output "gateway_subnet_id" {
  value = azurerm_subnet.gateway.id
}

output "bastion_subnet_id" {
  value = azurerm_subnet.bastion.id
}

output "ddos_protection_plan_id" {
  value = azurerm_network_ddos_protection_plan.hub.id
}

output "vpn_gateway_id" {
  value = try(azurerm_virtual_network_gateway.vpn[0].id, null)
}
