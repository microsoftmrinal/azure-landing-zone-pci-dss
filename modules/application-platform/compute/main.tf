variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "org_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "subnet_id" {
  description = "Subnet ID for VMs"
  type        = string
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "common_tags" {
  type = map(string)
}

locals {
  region_code = var.location == "northeurope" ? "neu" : "weu"
}

# Trusted Launch VM with secure boot and vTPM
resource "azurerm_linux_virtual_machine" "cde" {
  name                            = "vm-${var.org_prefix}-cde-${var.environment}-${local.region_code}-001"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = "Standard_D4s_v5"
  admin_username                  = "azureadmin"
  disable_password_authentication = true
  zone                            = "1"
  encryption_at_host_enabled      = true
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  tags                            = var.common_tags

  admin_ssh_key {
    username   = "azureadmin"
    public_key = "" # Injected via CI/CD or Key Vault
  }

  network_interface_ids = [azurerm_network_interface.cde.id]

  os_disk {
    caching                = "ReadOnly"
    storage_account_type   = "Premium_ZRS"
    disk_encryption_set_id = "" # Link to DES using HSM key
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_network_interface" "cde" {
  name                = "nic-vm-${var.org_prefix}-cde-${var.environment}-${local.region_code}-001"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

# Diagnostic settings
resource "azurerm_monitor_diagnostic_setting" "vm_nic" {
  name                       = "diag-nic-to-law"
  target_resource_id         = azurerm_network_interface.cde.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

output "vm_id" {
  value = azurerm_linux_virtual_machine.cde.id
}

output "vm_identity_principal_id" {
  value = azurerm_linux_virtual_machine.cde.identity[0].principal_id
}
