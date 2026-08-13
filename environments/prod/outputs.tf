output "hub_vnet_id" {
  description = "Resource ID of the hub virtual network"
  value       = module.hub_primary.vnet_id
}

output "firewall_private_ip" {
  description = "Private IP of the Azure Firewall"
  value       = module.firewall_primary.private_ip_address
}

output "spoke_cde_vnet_id" {
  description = "Resource ID of the CDE spoke virtual network"
  value       = module.spoke_cde_primary.vnet_id
}

output "sql_server_fqdn" {
  description = "FQDN of the Azure SQL Server (private)"
  value       = module.sql.server_fqdn
}

output "front_door_endpoint" {
  description = "Front Door endpoint hostname"
  value       = module.front_door.endpoint_hostname
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the central Log Analytics workspace"
  value       = module.sentinel.workspace_id
}

output "key_vault_uri" {
  description = "URI of the CDE Key Vault"
  value       = module.hsm.key_vault_uri
}
