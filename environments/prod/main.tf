terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.47"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate-prod-neu"
    storage_account_name = "sttfstateprodneu001"
    container_name       = "tfstate"
    key                  = "landing-zone-prod.tfstate"
    use_oidc             = true
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
  use_oidc = true
}

provider "azurerm" {
  alias           = "connectivity"
  subscription_id = var.connectivity_subscription_id
  use_oidc        = true
  features {}
}

provider "azurerm" {
  alias           = "management"
  subscription_id = var.management_subscription_id
  use_oidc        = true
  features {}
}

provider "azurerm" {
  alias           = "cde"
  subscription_id = var.cde_subscription_id
  use_oidc        = true
  features {}
}
