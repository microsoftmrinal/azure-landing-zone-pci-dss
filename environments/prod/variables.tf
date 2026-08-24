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

# --- Feature flags (phased rollout) ---
# Phase 1 minimum = governance + connectivity (hub/VPN GW/firewall/spoke) + key platform + client VM.
# Flip these to true and re-run `terraform apply` to layer in data and app platforms later.
variable "deploy_vpn_gateway" {
  description = "Deploy the hub VPN Gateway and enable spoke gateway transit (hub/spoke S2S)."
  type        = bool
  default     = true
}

variable "deploy_key_platform" {
  description = "Deploy the Managed HSM / Key Vault / Disk Encryption Set. Required by the client VM (CMK disk encryption)."
  type        = bool
  default     = true
}

variable "deploy_compute_vm" {
  description = "Deploy the client VM into the CDE spoke compute subnet."
  type        = bool
  default     = true
}

variable "deploy_data_platform" {
  description = "Deploy Azure SQL + immutable audit storage. Off for the phase-1 minimum."
  type        = bool
  default     = false
}

variable "deploy_application_platform" {
  description = "Deploy App Service + Front Door Premium/WAF. Off for the phase-1 minimum (Front Door has no origin without App Service)."
  type        = bool
  default     = false
}

# --- Firewall ---
variable "firewall_sku_tier" {
  description = "Azure Firewall SKU tier. Standard for phase 1; upgrade to Premium (in place) for IDPS + TLS inspection before go-live in PCI scope."
  type        = string
  default     = "Standard"
  validation {
    condition     = contains(["Standard", "Premium"], var.firewall_sku_tier)
    error_message = "firewall_sku_tier must be 'Standard' or 'Premium'. PCI-DSS CDE scope ultimately requires Premium for IDPS and TLS inspection."
  }
}

# --- VPN Gateway ---
variable "vpn_gateway_sku" {
  description = "VPN Gateway SKU. *AZ SKUs are zone-redundant (recommended)."
  type        = string
  default     = "VpnGw2AZ"
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
  description = "SSH public key for VM admin user (retrieve from Key Vault in pipeline). Required when deploy_compute_vm = true."
  type        = string
  sensitive   = true
  default     = null
}
