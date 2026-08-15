output "log_analytics_workspace_id" {
  value       = azurerm_log_analytics_workspace.this.id
  description = "ARM resource ID of the replacement shared Log Analytics workspace."
}

output "application_insights_id" {
  value       = azurerm_application_insights.this.id
  description = "ARM resource ID of the replacement workspace-based Application Insights resource."
}
