output "api_center_name" {
  value       = azapi_resource.api_center.name
  description = "Resource name of the API Center service."
}

output "api_center_id" {
  value       = azapi_resource.api_center.id
  description = "ARM resource ID of the API Center service."
}

output "registry_endpoint_url" {
  value       = local.registry_endpoint_url
  description = "Data-plane MCP registry endpoint, https://<name>.data.<region>.azure-apicenter.ms/workspaces/default/v0.1/servers. The ticket-5 bounded poll asserts the synced MCP server appears here."
}

output "workspace_name" {
  value       = azapi_resource.workspace.name
  description = "Name of the single API Center workspace (always \"default\"), the /workspaces/default segment of the registry endpoint."
}

output "environment_id" {
  value       = azapi_resource.environment.id
  description = "ARM resource ID of the API Center environment the synced MCP server is associated with."
}

output "api_source_id" {
  value       = azapi_resource.apim_source.id
  description = "ARM resource ID of the APIM auto-sync api source."
}

output "identity_principal_id" {
  value       = azapi_resource.api_center.identity[0].principal_id
  description = "Principal ID of the API Center service's system-assigned identity. Holds the API Management Service Reader role on apim_source_id when assign_apim_reader_role is true; exposed for compositions that assign that role out of band instead."
}
