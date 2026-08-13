# --- Subscription IDs ---
variable "connectivity_subscription_id" {
  description = "Subscription ID for the connectivity (hub) resources"
  type        = string
}

variable "management_subscription_id" {
  description = "Subscription ID for management resources (Log Analytics, Sentinel)"
  type        = string
}

variable "cde_subscription_id" {
  description = "Subscription ID for the CDE workload"
  type        = string
}

# --- Region ---
variable "primary_location" {
  description = "Primary Azure region"
  type        = string
  default     = "northeurope"
}

variable "dr_location" {
  description = "Disaster recovery Azure region"
  type        = string
  default     = "westeurope"
}

# --- Naming ---
variable "environment" {
  description = "Environment name (prod, dr)"
  type        = string
  default     = "prod"
}

variable "org_prefix" {
  description = "Organisation prefix for resource naming"
  type        = string
  default     = "p24"
}

# --- Networking ---
variable "hub_address_space_primary" {
  description = "Hub VNet address space for primary region"
  type        = list(string)
  default     = ["10.1.0.0/16"]
}

variable "hub_address_space_dr" {
  description = "Hub VNet address space for DR region"
  type        = list(string)
  default     = ["10.2.0.0/16"]
}

variable "spoke_cde_address_space_primary" {
  description = "CDE spoke address space for primary region"
  type        = list(string)
  default     = ["10.10.0.0/16"]
}

variable "spoke_cde_address_space_dr" {
  description = "CDE spoke address space for DR region"
  type        = list(string)
  default     = ["10.20.0.0/16"]
}

# --- Firewall ---
variable "firewall_sku_tier" {
  description = "Azure Firewall SKU tier"
  type        = string
  default     = "Premium"
  validation {
    condition     = var.firewall_sku_tier == "Premium"
    error_message = "PCI-DSS requires Firewall Premium for IDPS and TLS inspection."
  }
}

# --- SQL ---
variable "sql_admin_object_id" {
  description = "Entra ID object ID of the SQL administrator group"
  type        = string
}

variable "sql_admin_login_name" {
  description = "Display name of the SQL Entra admin group"
  type        = string
  default     = "sg-sql-admins-cde"
}

# --- Tags ---
variable "common_tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Environment        = "Production"
    PCIScope           = "CDE"
    DataClassification = "CardholderData"
    ManagedBy          = "Terraform"
    Workload           = "Payment24-CDE"
  }
}

# --- VPN ---
variable "vpn_shared_key" {
  description = "Pre-shared key for VPN Gateway connection (use Key Vault reference in CI/CD)"
  type        = string
  sensitive   = true
  default     = null
}

variable "on_prem_gateway_ip" {
  description = "On-premises VPN gateway public IP"
  type        = string
  default     = null
}

variable "on_prem_address_spaces" {
  description = "On-premises network address spaces for VPN"
  type        = list(string)
  default     = []
}

# --- HSM ---
variable "hsm_admin_object_ids" {
  description = "Entra ID object IDs for HSM administrators"
  type        = list(string)
}

# --- Front Door ---
variable "custom_domain_name" {
  description = "Custom domain for Front Door (e.g., app.payment24.com)"
  type        = string
  default     = null
}

# --- Compute ---
variable "admin_ssh_public_key" {
  description = "SSH public key for VM admin user (retrieve from Key Vault in pipeline)"
  type        = string
  sensitive   = true
}

variable "disk_encryption_set_id" {
  description = "Disk Encryption Set ID for VM OS disk encryption (linked to HSM key)"
  type        = string
}
