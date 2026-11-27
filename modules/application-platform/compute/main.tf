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
  description = "Compute subnet ID for the VM NIC and the internal load balancer frontend"
  type        = string
}

variable "private_link_nat_subnet_id" {
  description = "Subnet ID (private link service network policies disabled) for the Private Link Service NAT IP"
  type        = string
}

variable "admin_username" {
  description = "Local administrator user name for the IIS VM"
  type        = string
  default     = "azureadmin"
}

variable "admin_password" {
  description = "Local administrator password (retrieve from Key Vault in CI/CD; never commit)"
  type        = string
  sensitive   = true
}

variable "disk_encryption_set_id" {
  description = "Disk Encryption Set ID linked to HSM key"
  type        = string
}

variable "app_port" {
  description = "HTTPS port IIS listens on. Used for the load balancer rule, probe and Windows Firewall."
  type        = number
  default     = 8082
}

variable "health_probe_path" {
  description = "HTTPS readiness path served by IIS on app_port. Must report readiness, not just that the port is open."
  type        = string
  default     = "/health"
}

variable "app_allowed_source_prefixes" {
  description = "Source prefixes allowed by Windows Firewall to reach app_port (Private Link Service NAT subnet, VPN client ranges). Empty = any source (NSG still applies)."
  type        = list(string)
  default     = []
}

variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}

variable "availability_zone" {
  type    = string
  default = "1"
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "common_tags" {
  type = map(string)
}

locals {
  region_code = var.location == "northeurope" ? "neu" : "weu"
  suffix      = "${var.org_prefix}-cde-${var.environment}-${local.region_code}"

  # 168.63.129.16 is the Azure platform address that sources load balancer probes.
  firewall_remote_addresses = length(var.app_allowed_source_prefixes) > 0 ? join(",", concat(var.app_allowed_source_prefixes, ["168.63.129.16"])) : "Any"
}

# Trusted Launch Windows Server VM running IIS (no public IP)
resource "azurerm_windows_virtual_machine" "iis" {
  name                       = "vm-${local.suffix}-001"
  computer_name              = substr("${var.org_prefix}iis${local.region_code}01", 0, 15)
  resource_group_name        = var.resource_group_name
  location                   = var.location
  size                       = var.vm_size
  admin_username             = var.admin_username
  admin_password             = var.admin_password
  zone                       = var.availability_zone
  provision_vm_agent         = true
  patch_mode                 = "AutomaticByPlatform"
  encryption_at_host_enabled = true
  secure_boot_enabled        = true
  vtpm_enabled               = true
  tags                       = var.common_tags

  network_interface_ids = [azurerm_network_interface.iis.id]

  os_disk {
    caching                = "ReadWrite"
    storage_account_type   = "Premium_ZRS"
    disk_encryption_set_id = var.disk_encryption_set_id
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    ignore_changes = [admin_password]
  }
}

resource "azurerm_network_interface" "iis" {
  name                = "nic-vm-${local.suffix}-001"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

# Installs the IIS role and opens the app port. The site, the 8082 HTTPS binding and
# the certificate for the application FQDN are deployed by the application pipeline.
resource "azurerm_virtual_machine_extension" "iis" {
  name                       = "iis-role"
  virtual_machine_id         = azurerm_windows_virtual_machine.iis.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  tags                       = var.common_tags

  settings = jsonencode({
    commandToExecute = "powershell.exe -ExecutionPolicy Bypass -Command \"Install-WindowsFeature -Name Web-Server -IncludeManagementTools; New-NetFirewallRule -DisplayName 'App-HTTPS-${var.app_port}' -Direction Inbound -Protocol TCP -LocalPort ${var.app_port} -RemoteAddress ${local.firewall_remote_addresses} -Action Allow\""
  })
}

# Entra ID sign-in for administrators (RDP via Bastion); avoids shared local credentials.
resource "azurerm_virtual_machine_extension" "aad_login" {
  name                       = "aad-login"
  virtual_machine_id         = azurerm_windows_virtual_machine.iis.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "2.0"
  auto_upgrade_minor_version = true
  tags                       = var.common_tags
}

# --- Internal load balancer fronting IIS (target of the Private Link Service) ---
resource "azurerm_lb" "app" {
  name                = "lbi-${local.suffix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  tags                = var.common_tags

  frontend_ip_configuration {
    name                          = "fe-app"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    zones                         = ["1", "2", "3"]
  }
}

resource "azurerm_lb_backend_address_pool" "app" {
  name            = "be-iis"
  loadbalancer_id = azurerm_lb.app.id
}

resource "azurerm_network_interface_backend_address_pool_association" "iis" {
  network_interface_id    = azurerm_network_interface.iis.id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.app.id
}

resource "azurerm_lb_probe" "app" {
  name                = "probe-https-${var.app_port}"
  loadbalancer_id     = azurerm_lb.app.id
  protocol            = "Https"
  port                = var.app_port
  request_path        = var.health_probe_path
  interval_in_seconds = 15
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "app" {
  name                           = "rule-https-${var.app_port}"
  loadbalancer_id                = azurerm_lb.app.id
  protocol                       = "Tcp"
  frontend_port                  = var.app_port
  backend_port                   = var.app_port
  frontend_ip_configuration_name = "fe-app"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.app.id]
  probe_id                       = azurerm_lb_probe.app.id
  enable_tcp_reset               = true
}

# Private Link Service: Front Door Premium reaches IIS through a Front Door-managed
# private endpoint. The connection request must be approved on this resource.
resource "azurerm_private_link_service" "app" {
  name                                        = "pls-${local.suffix}"
  location                                    = var.location
  resource_group_name                         = var.resource_group_name
  load_balancer_frontend_ip_configuration_ids = [azurerm_lb.app.frontend_ip_configuration[0].id]
  tags                                        = var.common_tags

  nat_ip_configuration {
    name                       = "nat-primary"
    primary                    = true
    private_ip_address_version = "IPv4"
    subnet_id                  = var.private_link_nat_subnet_id
  }
}

# Diagnostic settings
resource "azurerm_monitor_diagnostic_setting" "vm_nic" {
  name                       = "diag-nic-to-law"
  target_resource_id         = azurerm_network_interface.iis.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

resource "azurerm_monitor_diagnostic_setting" "lb" {
  name                       = "diag-lb-to-law"
  target_resource_id         = azurerm_lb.app.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

output "vm_id" {
  value = azurerm_windows_virtual_machine.iis.id
}

output "vm_identity_principal_id" {
  value = azurerm_windows_virtual_machine.iis.identity[0].principal_id
}

output "vm_private_ip_address" {
  value = azurerm_network_interface.iis.private_ip_address
}

output "load_balancer_frontend_ip_address" {
  description = "Private IP of the internal load balancer (target for VPN clients and private DNS)"
  value       = azurerm_lb.app.frontend_ip_configuration[0].private_ip_address
}

output "private_link_service_id" {
  description = "Resource ID of the Private Link Service used as the Front Door origin"
  value       = azurerm_private_link_service.app.id
}
