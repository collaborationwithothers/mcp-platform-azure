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

output "mcp_server_api_id" {
  value       = module.apim_mcp_server.mcp_server_api_id
  description = "ARM resource ID of the passthrough MCP server API. Consumed by the live gate's call-stage diagnostics to dump the effective backendId/serviceUrl/mcpProperties."
}

output "prm_url" {
  value       = module.apim_gateway.prm_url
  description = "Gateway-root protected resource metadata URL, per RFC 9728. The no-token discovery assertion checks the WWW-Authenticate challenge points here."
}

output "registry_endpoint_url" {
  value       = module.api_center_registry.registry_endpoint_url
  description = "Data-plane MCP registry endpoint (/workspaces/default/v0.1/servers). The gate's anonymous secure-by-default probe targets this; it is portal-auth-only, not a headless-bearer surface (COMPATIBILITY.md, ADR-007)."
}

output "api_center_name" {
  value       = module.api_center_registry.api_center_name
  description = "Resource name of the API Center service."
}

output "api_center_id" {
  value       = module.api_center_registry.api_center_id
  description = "ARM resource ID of the API Center service. The gate's non-blocking convergence evidence reads the control-plane apis inventory (.../workspaces/default/apis) under this id to check the auto-synced MCP server appeared (kind=mcp)."
}
