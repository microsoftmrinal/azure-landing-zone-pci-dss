variable "resource_group_name" {
  type = string
}

variable "hub_vnet_id" {
  type = string
}

variable "common_tags" {
  type = map(string)
}

locals {
  private_dns_zones = [
    "privatelink.database.windows.net",
    "privatelink.blob.core.windows.net",
    "privatelink.vaultcore.azure.net",
    "privatelink.managedhsm.azure.net",
    "privatelink.file.core.windows.net",
    "privatelink.queue.core.windows.net",
    "privatelink.table.core.windows.net",
  ]
}

resource "azurerm_private_dns_zone" "zones" {
  for_each            = toset(local.private_dns_zones)
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub_links" {
  for_each              = azurerm_private_dns_zone.zones
  name                  = "link-hub-${replace(each.key, ".", "-")}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = each.value.name
  virtual_network_id    = var.hub_vnet_id
  registration_enabled  = false
  tags                  = var.common_tags
}

output "sql_dns_zone_id" {
  value = azurerm_private_dns_zone.zones["privatelink.database.windows.net"].id
}

output "blob_dns_zone_id" {
  value = azurerm_private_dns_zone.zones["privatelink.blob.core.windows.net"].id
}

output "keyvault_dns_zone_id" {
  value = azurerm_private_dns_zone.zones["privatelink.vaultcore.azure.net"].id
}

output "hsm_dns_zone_id" {
  value = azurerm_private_dns_zone.zones["privatelink.managedhsm.azure.net"].id
}
