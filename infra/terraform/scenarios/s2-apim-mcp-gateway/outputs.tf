output "apim_id" {
  value       = module.apim_gateway.apim_id
  description = "ARM resource ID of the API Management service."
}

output "gateway_url" {
  value       = module.apim_gateway.gateway_url
  description = "Gateway URL of the API Management service."
}

output "mcp_server_url" {
  value       = module.apim_mcp_server.mcp_server_url
  description = "Client-facing MCP endpoint. The McpTestClient session/tool assertions and the demo script target this URL (docs/specs/v1-tracer-bullet.md, Testing Decisions)."
}

output "prm_url" {
  value       = module.apim_gateway.prm_url
  description = "Gateway-root protected resource metadata URL, per RFC 9728. The no-token discovery assertion checks the WWW-Authenticate challenge points here."
}

output "registry_endpoint_url" {
  value       = module.api_center_registry.registry_endpoint_url
  description = "Data-plane MCP registry endpoint. The bounded registry poll asserts the tracer server appears here within the timeout."
}

output "api_center_name" {
  value       = module.api_center_registry.api_center_name
  description = "Resource name of the API Center service."
}
