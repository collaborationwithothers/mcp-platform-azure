output "mcp_server_api_id" {
  value       = azapi_resource.mcp_server.id
  description = "ARM resource ID of the MCP server API."
}

output "mcp_server_url" {
  value       = local.mcp_server_url
  description = "Client-facing MCP endpoint (https://<gateway>/<server_path>/mcp for the tracer's streamable transport)."
}

output "prm_url" {
  value       = local.prm_url
  description = "Gateway root protected resource metadata URL (https://<gateway>/.well-known/oauth-protected-resource), per RFC 9728. Not under the API subpath."
}
