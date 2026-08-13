# Identity module - Conditional Access and PIM configuration
# Note: These require Microsoft Graph API and are typically deployed via
# a separate pipeline with Graph API permissions or manual configuration.

variable "org_prefix" {
  type = string
}

variable "common_tags" {
  type = map(string)
}

# Break-glass accounts (create two for redundancy)
resource "azuread_user" "break_glass_1" {
  user_principal_name = "bg-admin-1@${data.azuread_domains.tenant.domains[0].domain_name}"
  display_name        = "Break Glass Admin 1"
  password            = null # Must be set manually during initial setup
  account_enabled     = true
}

resource "azuread_user" "break_glass_2" {
  user_principal_name = "bg-admin-2@${data.azuread_domains.tenant.domains[0].domain_name}"
  display_name        = "Break Glass Admin 2"
  password            = null
  account_enabled     = true
}

data "azuread_domains" "tenant" {
  only_initial = true
}

# Security group for SQL Admins
resource "azuread_group" "sql_admins" {
  display_name     = "sg-sql-admins-cde"
  security_enabled = true
  mail_enabled     = false
}

# Security group for CDE Readers (PIM eligible)
resource "azuread_group" "cde_readers" {
  display_name     = "sg-cde-readers"
  security_enabled = true
  mail_enabled     = false
}

# Conditional Access: Require phishing-resistant MFA for all admins
resource "azuread_conditional_access_policy" "require_phishing_resistant_mfa" {
  display_name = "PCI-Require-PhishingResistant-MFA-Admins"
  state        = "enabled"

  conditions {
    users {
      included_roles = [
        "62e90394-69f5-4237-9190-012177145e10", # Global Administrator
        "194ae4cb-b126-40b2-bd5b-6091b380977d", # Security Administrator
        "f28a1f50-f6e7-4571-818b-6a12f2af6b6c", # SharePoint Administrator
      ]
    }

    applications {
      included_applications = ["All"]
    }

    client_app_types = ["all"]
  }

  grant_controls {
    operator                          = "OR"
    authentication_strength_policy_id = data.azuread_authentication_strength_policy.phishing_resistant.id
  }
}

data "azuread_authentication_strength_policy" "phishing_resistant" {
  display_name = "Phishing-resistant MFA"
}

# Conditional Access: Block legacy authentication
resource "azuread_conditional_access_policy" "block_legacy_auth" {
  display_name = "PCI-Block-Legacy-Authentication"
  state        = "enabled"

  conditions {
    users {
      included_users = ["All"]
    }

    applications {
      included_applications = ["All"]
    }

    client_app_types = ["exchangeActiveSync", "other"]
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["block"]
  }
}

output "sql_admins_group_id" {
  value = azuread_group.sql_admins.object_id
}

output "cde_readers_group_id" {
  value = azuread_group.cde_readers.object_id
}
