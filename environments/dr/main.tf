terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.100.0, < 4.0.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate-prod-weu"
    storage_account_name = "sttfstateprodweu001"
    container_name       = "tfstate"
    key                  = "landing-zone-dr.tfstate"
    use_oidc             = true
  }
}

provider "azurerm" {
  features {}
  use_oidc = true
}

provider "azurerm" {
  alias           = "connectivity"
  subscription_id = var.connectivity_subscription_id
  use_oidc        = true
  features {}
}

provider "azurerm" {
  alias           = "cde"
  subscription_id = var.cde_subscription_id
  use_oidc        = true
  features {}
}

variable "connectivity_subscription_id" {
  type = string
}

variable "cde_subscription_id" {
  type = string
}

variable "org_prefix" {
  type    = string
  default = "p24"
}

variable "environment" {
  type    = string
  default = "dr"
}

variable "common_tags" {
  type = map(string)
  default = {
    Environment        = "DR"
    PCIScope           = "CDE"
    DataClassification = "CardholderData"
    ManagedBy          = "Terraform"
    Workload           = "Payment24-CDE"
  }
}

# DR hub (West Europe)
module "hub_dr" {
  source = "../../modules/connectivity/hub"

  providers = {
    azurerm = azurerm.connectivity
  }

  resource_group_name = "rg-conn-${var.environment}-weu"
  location            = "westeurope"
  address_space       = ["10.2.0.0/16"]
  org_prefix          = var.org_prefix
  environment         = var.environment
  common_tags         = var.common_tags

  deploy_vpn_gateway     = var.deploy_vpn_gateway
  vpn_gateway_sku        = var.vpn_gateway_sku
  on_prem_gateway_ip     = var.on_prem_gateway_ip
  on_prem_address_spaces = var.on_prem_address_spaces
  vpn_shared_key         = var.vpn_shared_key
}

module "firewall_dr" {
  source = "../../modules/connectivity/firewall"

  providers = {
    azurerm = azurerm.connectivity
  }

  resource_group_name        = module.hub_dr.resource_group_name
  location                   = "westeurope"
  firewall_subnet_id         = module.hub_dr.firewall_subnet_id
  log_analytics_workspace_id = var.log_analytics_workspace_id
  org_prefix                 = var.org_prefix
  environment                = var.environment
  sku_tier                   = "Premium"
  common_tags                = var.common_tags

  cde_address_prefixes          = ["10.20.0.0/16"]
  app_port                      = var.app_port
  client_b_inbound_prefixes     = var.client_b_inbound_prefixes
  client_a_destination_prefixes = var.client_a_destination_prefixes
  client_a_destination_ports    = var.client_a_destination_ports
  client_a_egress_public_ip_id  = var.client_a_egress_public_ip_id
}

module "spoke_cde_dr" {
  source = "../../modules/connectivity/spoke"

  providers = {
    azurerm = azurerm.cde
  }

  resource_group_name         = "rg-cde-${var.environment}-weu"
  location                    = "westeurope"
  address_space               = ["10.20.0.0/16"]
  hub_vnet_id                 = module.hub_dr.vnet_id
  firewall_private_ip         = module.firewall_dr.private_ip_address
  org_prefix                  = var.org_prefix
  environment                 = var.environment
  workload                    = "cde"
  use_remote_gateways         = var.deploy_vpn_gateway
  management_inbound_prefixes = ["10.2.0.0/16"]
  app_port                    = var.app_port
  app_inbound_prefixes        = var.client_b_inbound_prefixes
  common_tags                 = var.common_tags

  depends_on = [module.hub_dr]
}

# Hub -> spoke peering with gateway transit (required for the spoke's use_remote_gateways).
resource "azurerm_virtual_network_peering" "hub_to_spoke_cde_dr" {
  count                        = var.deploy_vpn_gateway ? 1 : 0
  provider                     = azurerm.connectivity
  name                         = "peer-hub-to-cde"
  resource_group_name          = module.hub_dr.resource_group_name
  virtual_network_name         = module.hub_dr.vnet_name
  remote_virtual_network_id    = module.spoke_cde_dr.vnet_id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
  allow_gateway_transit        = true

  depends_on = [module.hub_dr]
}

# Steer VPN-originated traffic for the CDE through the firewall (keep BGP propagation enabled).
resource "azurerm_route_table" "gateway_dr" {
  count                         = var.deploy_vpn_gateway ? 1 : 0
  provider                      = azurerm.connectivity
  name                          = "rt-gateway-${var.environment}-weu"
  location                      = "westeurope"
  resource_group_name           = module.hub_dr.resource_group_name
  disable_bgp_route_propagation = false
  tags                          = var.common_tags

  route {
    name                   = "cde-0"
    address_prefix         = "10.20.0.0/16"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = module.firewall_dr.private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "gateway_dr" {
  count          = var.deploy_vpn_gateway ? 1 : 0
  provider       = azurerm.connectivity
  subnet_id      = module.hub_dr.gateway_subnet_id
  route_table_id = azurerm_route_table.gateway_dr[0].id
}

# Key platform in West Europe. The disk encryption set must be in the same region as the VM.
# Independent HSM/Key Vault: key recovery between regions is a separate design decision.
module "hsm_dr" {
  source = "../../modules/data-platform/hsm"
  count  = var.deploy_key_platform ? 1 : 0

  providers = {
    azurerm = azurerm.cde
  }

  resource_group_name        = module.spoke_cde_dr.resource_group_name
  location                   = "westeurope"
  org_prefix                 = var.org_prefix
  environment                = var.environment
  subnet_id                  = module.spoke_cde_dr.private_endpoints_subnet_id
  admin_object_ids           = var.hsm_admin_object_ids
  dns_zone_id                = var.keyvault_dns_zone_id
  log_analytics_workspace_id = var.log_analytics_workspace_id
  common_tags                = var.common_tags
}

# Warm-standby IIS VM behind an internal load balancer + Private Link Service (Front Door priority-2 origin).
module "compute_cde_dr" {
  source = "../../modules/application-platform/compute"
  count  = var.deploy_compute_vm ? 1 : 0

  providers = {
    azurerm = azurerm.cde
  }

  resource_group_name         = module.spoke_cde_dr.resource_group_name
  location                    = "westeurope"
  org_prefix                  = var.org_prefix
  environment                 = var.environment
  subnet_id                   = module.spoke_cde_dr.compute_subnet_id
  private_link_nat_subnet_id  = module.spoke_cde_dr.private_link_service_subnet_id
  admin_password              = var.vm_admin_password
  disk_encryption_set_id      = module.hsm_dr[0].disk_encryption_set_id
  app_port                    = var.app_port
  app_allowed_source_prefixes = concat(module.spoke_cde_dr.private_link_service_subnet_prefixes, var.client_b_inbound_prefixes)
  log_analytics_workspace_id  = var.log_analytics_workspace_id
  common_tags                 = var.common_tags

  depends_on = [module.hsm_dr]
}

variable "log_analytics_workspace_id" {
  description = "Central Log Analytics workspace ID (from primary region)"
  type        = string
}

variable "deploy_vpn_gateway" {
  description = "Deploy the West Europe VPN Gateway and enable spoke gateway transit."
  type        = bool
  default     = true
}

variable "vpn_gateway_sku" {
  type    = string
  default = "VpnGw2AZ"
}

variable "on_prem_gateway_ip" {
  description = "Remote VPN device public IP for the West Europe tunnel. When set, a S2S connection is created."
  type        = string
  default     = null
}

variable "on_prem_address_spaces" {
  type    = list(string)
  default = []
}

variable "vpn_shared_key" {
  type      = string
  sensitive = true
  default   = null
}

variable "deploy_key_platform" {
  description = "Deploy the West Europe Managed HSM / Key Vault / Disk Encryption Set (required by the IIS VM)."
  type        = bool
  default     = true
}

variable "deploy_compute_vm" {
  description = "Deploy the West Europe IIS VM, internal load balancer and Private Link Service. Requires deploy_key_platform = true."
  type        = bool
  default     = true
}

variable "hsm_admin_object_ids" {
  description = "Entra ID object IDs for HSM administrators"
  type        = list(string)
  default     = []
}

variable "keyvault_dns_zone_id" {
  description = "privatelink.vaultcore.azure.net zone ID (output keyvault_dns_zone_id of the prod DNS module)"
  type        = string
  default     = null
}

variable "app_port" {
  type    = number
  default = 8082
}

variable "client_b_inbound_prefixes" {
  type    = list(string)
  default = []
}

variable "client_a_destination_prefixes" {
  type    = list(string)
  default = []
}

variable "client_a_destination_ports" {
  type    = list(string)
  default = []
}

variable "client_a_egress_public_ip_id" {
  description = "Separate West Europe reserved public IP for Client A (must be allow-listed by Client A in advance)."
  type        = string
  default     = null
}

variable "vm_admin_password" {
  description = "Local administrator password for the IIS VM (retrieve from Key Vault in pipeline)."
  type        = string
  sensitive   = true
  default     = null
}

output "private_link_service_id" {
  description = "West Europe Private Link Service. Pass to environments/prod as dr_private_link_service_id and approve the Front Door connection here."
  value       = try(module.compute_cde_dr[0].private_link_service_id, null)
}

output "app_load_balancer_private_ip" {
  description = "Private IP of the West Europe internal load balancer (VPN clients / private DNS target)."
  value       = try(module.compute_cde_dr[0].load_balancer_frontend_ip_address, null)
}

output "firewall_public_ip" {
  description = "Primary West Europe firewall egress public IP. Client A must allow-list it."
  value       = module.firewall_dr.public_ip_address
}
