output "function_app_id" {
  value       = module.mcp_function_host.function_app_id
  description = "ARM resource ID of the Function App."
  sensitive   = true
}

output "function_app_name" {
  value       = module.mcp_function_host.function_app_name
  description = "Name of the Function App."
}

output "default_hostname" {
  value       = module.mcp_function_host.default_hostname
  description = "Default hostname of the Function App (e.g. <name>.azurewebsites.net). Ticket 5's shadow-key negative test runs against this host directly, as well as the gateway."
}

output "mcp_backend_base_url" {
  value       = module.mcp_function_host.mcp_backend_base_url
  description = "Base URL of the deployed backend. The s2-apim-mcp-gateway composition reads this via terraform_remote_state to wire apim-mcp-server's backend_service_url (docs/specs/v1-tracer-bullet.md, Delivery shape, Composition interface)."
}

output "identity_principal_id" {
  value       = module.mcp_function_host.identity_principal_id
  description = "Principal ID of the Function App's system-assigned managed identity. Issue 10: the out-of-band runbook step (docs/runbooks/obo-app-registrations.md) federates this identity onto the server app registration as a client-assertion credential source, so the OBO exchange authenticates with no stored secret."
  sensitive   = true
}

output "downstream_function_app_name" {
  value       = module.downstream_orders_api.function_app_name
  description = "Name of the downstream Orders API's Function App. Issue 10: the live-test gate deploys src/DownstreamOrdersApi here, the same config-zip pattern used for the MCP server."
}

output "downstream_base_url" {
  value       = module.downstream_orders_api.base_url
  description = "Base URL of the downstream Orders API. Issue 10: tests/integration/obo-passthrough-negative.ps1 calls <downstream_base_url>/api/orders/<id> directly with the MCP server's token to prove passthrough is rejected."
}
