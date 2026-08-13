variable "org_prefix" {
  type = string
}

variable "common_tags" {
  type = map(string)
}

resource "azurerm_management_group" "intermediate_root" {
  display_name = "${upper(var.org_prefix)}-Root"
  name         = "${var.org_prefix}-root"
}

resource "azurerm_management_group" "platform" {
  display_name               = "Platform"
  name                       = "${var.org_prefix}-platform"
  parent_management_group_id = azurerm_management_group.intermediate_root.id
}

resource "azurerm_management_group" "connectivity" {
  display_name               = "Connectivity"
  name                       = "${var.org_prefix}-connectivity"
  parent_management_group_id = azurerm_management_group.platform.id
}

resource "azurerm_management_group" "management" {
  display_name               = "Management"
  name                       = "${var.org_prefix}-management"
  parent_management_group_id = azurerm_management_group.platform.id
}

resource "azurerm_management_group" "identity" {
  display_name               = "Identity"
  name                       = "${var.org_prefix}-identity"
  parent_management_group_id = azurerm_management_group.platform.id
}

resource "azurerm_management_group" "landing_zones" {
  display_name               = "Landing Zones"
  name                       = "${var.org_prefix}-landingzones"
  parent_management_group_id = azurerm_management_group.intermediate_root.id
}

resource "azurerm_management_group" "cde" {
  display_name               = "CDE-Prod"
  name                       = "${var.org_prefix}-cde-prod"
  parent_management_group_id = azurerm_management_group.landing_zones.id
}

resource "azurerm_management_group" "corp" {
  display_name               = "Corp"
  name                       = "${var.org_prefix}-corp"
  parent_management_group_id = azurerm_management_group.landing_zones.id
}

resource "azurerm_management_group" "sandbox" {
  display_name               = "Sandbox"
  name                       = "${var.org_prefix}-sandbox"
  parent_management_group_id = azurerm_management_group.intermediate_root.id
}

resource "azurerm_management_group" "decommissioned" {
  display_name               = "Decommissioned"
  name                       = "${var.org_prefix}-decommissioned"
  parent_management_group_id = azurerm_management_group.intermediate_root.id
}

output "intermediate_root_id" {
  value = azurerm_management_group.intermediate_root.id
}

output "cde_management_group_id" {
  value = azurerm_management_group.cde.id
}

output "platform_management_group_id" {
  value = azurerm_management_group.platform.id
}

output "landing_zones_management_group_id" {
  value = azurerm_management_group.landing_zones.id
}
