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
  description = "Gateway-root protected resource metadata URL (https://<gateway>/.well-known/oauth-protected-resource), per RFC 9728. Serves the primary server's document; retained as the s3.3 fail-closed guard for clients that fall back to root while targeting another server."
}

output "prm_server_urls" {
  value = {
    for k, v in local.prm_servers : v.resource => "${local.prm_url}${v.path}"
  }
  description = "Map of RFC 9728 s3.1 path-inserted PRM URLs keyed by each server's resource URL (issue 17). Each value is the well-known location a spec client resolves for that server: the gateway-root well-known URL with the server's resource path inserted after it. The gate asserts each returns 200 with resource equal to that server's URL exactly."
}

output "identity_principal_id" {
  value       = module.apim.resource.identity[0].principal_id
  description = "Principal ID of the API Management service's system-assigned managed identity. Unused in the tracer; present for the thick interface (e.g. future RBAC wiring)."
  sensitive   = true
}

output "audit_logger_id" {
  value       = azapi_resource.audit_logger.id
  description = "ARM resource ID of the Application Insights audit logger (issue 18). Passed to apim-mcp-server instances as audit_logger_id for the per-API diagnostic setting that captures per-tool deny events at verbosity = error."
}

output "audit_workspace_id" {
  value       = local.audit_workspace_id
  description = "ARM resource ID of the Log Analytics workspace underlying the out-of-band Application Insights resource (issue 18). The live gate resolves this to the workspace's own GUID (az monitor log-analytics workspace show --query customerId) before running its audit-event KQL assertion."
}
