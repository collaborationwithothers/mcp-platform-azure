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

output "identity_principal_id" {
  value       = module.apim.resource.identity[0].principal_id
  description = "Principal ID of the API Management service's system-assigned managed identity. Unused in the tracer; present for the thick interface (e.g. future RBAC wiring)."
}
