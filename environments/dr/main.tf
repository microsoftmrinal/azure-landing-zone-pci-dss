terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
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
}

module "spoke_cde_dr" {
  source = "../../modules/connectivity/spoke"

  providers = {
    azurerm = azurerm.cde
  }

  resource_group_name = "rg-cde-${var.environment}-weu"
  location            = "westeurope"
  address_space       = ["10.20.0.0/16"]
  hub_vnet_id         = module.hub_dr.vnet_id
  firewall_private_ip = module.firewall_dr.private_ip_address
  org_prefix          = var.org_prefix
  environment         = var.environment
  workload            = "cde"
  common_tags         = var.common_tags
}

variable "log_analytics_workspace_id" {
  description = "Central Log Analytics workspace ID (from primary region)"
  type        = string
}
