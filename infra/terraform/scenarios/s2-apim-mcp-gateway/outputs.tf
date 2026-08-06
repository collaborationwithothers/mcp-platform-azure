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
  description = "Client-facing MCP endpoint for server 1. The McpTestClient session/tool assertions and the demo script target this URL (docs/specs/v1-tracer-bullet.md, Testing Decisions)."
}

output "mcp_server_2_url" {
  value       = module.apim_mcp_server_2.mcp_server_url
  description = "Client-facing MCP endpoint for server 2 (issue 17). The cross-server negative asserts the server-1-only client is rejected here (403 insufficient_scope)."
}

output "mcp_server_api_id" {
  value       = module.apim_mcp_server.mcp_server_api_id
  description = "ARM resource ID of the passthrough MCP server API (server 1). Consumed by the live gate's call-stage diagnostics to dump the effective backendId/serviceUrl/mcpProperties."
}

output "mcp_server_2_api_id" {
  value       = module.apim_mcp_server_2.mcp_server_api_id
  description = "ARM resource ID of the second passthrough MCP server API (issue 17)."
}

output "prm_url" {
  value       = module.apim_gateway.prm_url
  description = "Gateway-root protected resource metadata URL, per RFC 9728. Serves server 1's document; retained as the s3.3 fail-closed guard. The no-token discovery assertion checks the client-visible challenge."
}

output "tool_authorization_map_keys" {
  value       = join(",", keys(var.tool_authorization_map))
  description = "Server 1's tool_authorization_map key set, comma-joined (issue 18). The live gate's per-server set-equality assertion compares this against the deployed server's own tools/list, failing on any difference in either direction."
}

output "server_2_tool_authorization_map_keys" {
  value       = join(",", keys(var.server_2_tool_authorization_map))
  description = "Server 2's tool_authorization_map key set, comma-joined (issue 18)."
}

output "prm_server_urls" {
  value       = module.apim_gateway.prm_server_urls
  description = "Map of RFC 9728 s3.1 path-inserted PRM URLs keyed by each server's resource URL (issue 17). The gate asserts each returns 200 with resource equal to that server's URL exactly."
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
