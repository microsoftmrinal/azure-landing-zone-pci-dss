variable "cde_management_group_id" {
  description = "Management group ID where PCI DSS v4 policy is assigned"
  type        = string
}

variable "root_management_group_id" {
  description = "Intermediate root management group ID for baseline policies"
  type        = string
}

variable "primary_location" {
  type = string
}

variable "dr_location" {
  type = string
}

variable "common_tags" {
  type = map(string)
}

# PCI DSS v4 built-in initiative
data "azurerm_policy_set_definition" "pci_dss_v4" {
  display_name = "PCI DSS v4"
}

resource "azurerm_management_group_policy_assignment" "pci_dss_v4" {
  name                 = "pci-dss-v4-cde"
  display_name         = "PCI DSS v4 - CDE"
  description          = "Assigns the PCI DSS v4 compliance initiative to the CDE management group"
  management_group_id  = var.cde_management_group_id
  policy_definition_id = data.azurerm_policy_set_definition.pci_dss_v4.id

  identity {
    type = "SystemAssigned"
  }

  location = var.primary_location
}

# Deny public IP addresses in CDE
resource "azurerm_management_group_policy_assignment" "deny_public_ip" {
  name                 = "deny-public-ip-cde"
  display_name         = "Deny Public IP Addresses in CDE"
  management_group_id  = var.cde_management_group_id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/6c112d4e-5bc7-47ae-a041-ea2d9dcbd749"
  enforcement_mode     = "Default"
}

# Allowed locations - restrict to EU regions only
resource "azurerm_management_group_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  display_name         = "Allowed Locations - EU Only"
  management_group_id  = var.root_management_group_id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"

  parameters = jsonencode({
    listOfAllowedLocations = {
      value = [var.primary_location, var.dr_location]
    }
  })
}

# Require encryption on storage accounts
resource "azurerm_management_group_policy_assignment" "storage_encryption" {
  name                 = "require-storage-encrypt"
  display_name         = "Require Storage Account Encryption"
  management_group_id  = var.cde_management_group_id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/b5ec538c-daa0-4006-8596-35468b9148e8"
  enforcement_mode     = "Default"
}

# Require TLS 1.2
resource "azurerm_management_group_policy_assignment" "require_tls" {
  name                 = "require-tls-12"
  display_name         = "Require minimum TLS 1.2"
  management_group_id  = var.root_management_group_id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/fe83a0eb-a853-422d-afc8-c7a6999afcec"
  enforcement_mode     = "Default"
}

# Deny public network access on SQL
resource "azurerm_management_group_policy_assignment" "deny_sql_public" {
  name                 = "deny-sql-public-access"
  display_name         = "Deny SQL Public Network Access"
  management_group_id  = var.cde_management_group_id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/1b8ca024-1d5c-4dec-8995-b1a932b41780"
  enforcement_mode     = "Default"
}

# Require tags on resources
resource "azurerm_management_group_policy_assignment" "require_pci_scope_tag" {
  name                 = "require-pciscope-tag"
  display_name         = "Require PCIScope Tag"
  management_group_id  = var.cde_management_group_id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99"

  parameters = jsonencode({
    tagName = {
      value = "PCIScope"
    }
  })
}
