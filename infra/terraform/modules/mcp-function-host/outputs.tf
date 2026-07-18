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
  value       = local.base_url
  description = "Base URL the apim-mcp-server module points serviceUrl at. The exact MCP endpoint path is confirmed against the current Functions MCP extension docs in ticket 3, not hard-coded here."
}

output "base_url" {
  value       = local.base_url
  description = "Base URL of this instance, identical to mcp_backend_base_url. Generically named for non-MCP reuse of this module (issue 10: the downstream Orders API instance), which is not itself an MCP backend. mcp_backend_base_url is kept for its existing consumer (s2-apim-mcp-gateway's remote-state read); new non-MCP consumers should read this output instead."
}

output "identity_principal_id" {
  value       = module.function_app.identity_principal_id
  description = "Principal ID of the Function App's system-assigned managed identity. Issue 10: federated onto the server app registration as a client-assertion credential source (docs/runbooks/obo-app-registrations.md), so McpTools.Downstream.ManagedIdentityOboTokenAcquirer's OBO exchange authenticates with no stored secret."
  sensitive   = true
}

locals {
  base_url = "https://${module.function_app.resource_uri}"
}
