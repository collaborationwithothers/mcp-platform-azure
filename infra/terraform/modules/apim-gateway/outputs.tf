output "apim_id" {
  value       = module.apim.resource_id
  description = "ARM resource ID of the API Management service."
}

output "apim_name" {
  value       = module.apim.name
  description = "Name of the API Management service."
}

output "gateway_url" {
  value       = module.apim.apim_gateway_url
  description = "Gateway URL of the API Management service (https://<name>.azure-api.net)."
}

output "prm_url" {
  value       = local.prm_url
  description = "Gateway-root protected resource metadata URL (https://<gateway>/.well-known/oauth-protected-resource), per RFC 9728. Served at the gateway root, not under any API subpath. apim-mcp-server's 401 challenge points callers here."
}

output "identity_principal_id" {
  value       = module.apim.resource.identity[0].principal_id
  description = "Principal ID of the API Management service's system-assigned managed identity. Unused in the tracer; present for the thick interface (e.g. future RBAC wiring)."
  sensitive   = true
}
