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
  description = "FQDN of the Azure SQL Server (private). Null until the data platform is deployed."
  value       = try(module.sql[0].server_fqdn, null)
}

output "front_door_endpoint" {
  description = "Front Door endpoint hostname. Null until Front Door is deployed."
  value       = try(module.front_door[0].endpoint_hostname, null)
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the central Log Analytics workspace"
  value       = module.sentinel.workspace_id
}

output "key_vault_uri" {
  description = "URI of the CDE Key Vault. Null until the key platform is deployed."
  value       = try(module.hsm[0].key_vault_uri, null)
}

output "vpn_gateway_id" {
  description = "Resource ID of the hub VPN Gateway. Null when deploy_vpn_gateway = false."
  value       = module.hub_primary.vpn_gateway_id
}

output "iis_vm_id" {
  description = "Resource ID of the North Europe IIS VM. Null when deploy_compute_vm = false."
  value       = try(module.compute_cde[0].vm_id, null)
}

output "private_link_service_id" {
  description = "North Europe Private Link Service (Front Door priority-1 origin). Approve the Front Door connection here."
  value       = try(module.compute_cde[0].private_link_service_id, null)
}

output "app_load_balancer_private_ip" {
  description = "Private IP of the North Europe internal load balancer (VPN clients / private DNS target)."
  value       = try(module.compute_cde[0].load_balancer_frontend_ip_address, null)
}

output "firewall_public_ip" {
  description = "Primary firewall egress public IP. Client A must allow-list this and any additional firewall public IP."
  value       = module.firewall_primary.public_ip_address
}
