output "azure_monitor_workspace_id" {
  value       = azurerm_monitor_workspace.this.id
  description = "ARM resource ID of the Azure Monitor workspace that stores managed Prometheus metrics."
}

output "grafana_id" {
  value       = azurerm_dashboard_grafana.this.id
  description = "ARM resource ID of the Azure Managed Grafana workspace."
}

output "grafana_name" {
  value       = azurerm_dashboard_grafana.this.name
  description = "Name of the Azure Managed Grafana workspace used by the dashboard import workflow."
}
