output "function_app_id" {
  value       = module.function_app.resource_id
  description = "ARM resource ID of the Function App."
  sensitive   = true
}

output "function_app_name" {
  value       = module.function_app.name
  description = "Name of the Function App."
}

output "default_hostname" {
  value       = module.function_app.resource_uri
  description = "Default hostname of the Function App (e.g. <name>.azurewebsites.net)."
}

output "mcp_backend_base_url" {
  value       = "https://${module.function_app.resource_uri}"
  description = "Base URL the apim-mcp-server module points serviceUrl at. The exact MCP endpoint path is confirmed against the current Functions MCP extension docs in ticket 3, not hard-coded here."
}

output "identity_principal_id" {
  value       = module.function_app.identity_principal_id
  description = "Principal ID of the Function App's system-assigned managed identity. Unused in the tracer (no downstream call); present for later RBAC (OBO issue) per the thick interface."
  sensitive   = true
}
