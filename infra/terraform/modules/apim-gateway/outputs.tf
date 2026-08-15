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

output "shared_observability_workspace_id" {
  value       = var.log_analytics_workspace_id
  description = "ARM resource ID of the core-state Log Analytics workspace shared by the issue 18 audit path and the issue 75 platform diagnostic settings. The live gate passes it only as a pointer to the durable observability trail; Event Hubs remains the pass/fail source for per-tool audit events."
}

output "eventhub_logger_name" {
  value       = azapi_resource.eventhub_logger.name
  description = "Name of the Event Hub logger (issue 18), for apim-mcp-server's log-to-eventhub policy logger-id attribute (which references a logger by name, not ARM ID)."
}

output "eventhub_namespace_fqdn" {
  value       = "${azurerm_eventhub_namespace.audit.name}.servicebus.windows.net"
  description = "Fully-qualified domain name of the ephemeral audit Event Hub namespace (issue 18). The live gate connects here with the Event Hubs SDK to consume the per-tool deny audit event; destroyed with this resource group, never queried outside the run that produced it."
}

output "eventhub_name" {
  value       = azurerm_eventhub.audit.name
  description = "Name of the ephemeral audit Event Hub entity (issue 18), within eventhub_namespace_fqdn."
}
