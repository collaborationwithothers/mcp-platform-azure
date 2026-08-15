data "azurerm_resource_group" "shared_observability" {
  name = var.resource_group_name
}

# The identity running this composition is the existing live-test GitHub
# Actions workload identity. Its Grafana Editor grant lets the workflow import
# the repository dashboard without a Grafana API key or service account token.
data "azurerm_client_config" "current" {}

locals {
  name_suffix = substr(sha1(var.resource_group_name), 0, 8)
  tags = merge(var.tags, {
    component = "shared-observability"
    lifecycle = "metrics"
  })
}

resource "azurerm_monitor_workspace" "this" {
  name                = "mcp-shared-amw-${local.name_suffix}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.shared_observability.name

  # Public access is intentional for the public-demo profile. Azure RBAC still
  # controls metric ingestion and queries.
  public_network_access_enabled = true
  tags                          = local.tags
}

resource "azurerm_dashboard_grafana" "this" {
  name                  = "mcp-shared-grafana-${local.name_suffix}"
  location              = var.location
  resource_group_name   = data.azurerm_resource_group.shared_observability.name
  sku                   = "Standard"
  sku_size              = "X1"
  grafana_major_version = "12"

  api_key_enabled               = false
  public_network_access_enabled = true
  zone_redundancy_enabled       = false
  tags                          = local.tags

  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.this.id
  }
}

resource "azurerm_role_assignment" "grafana_monitoring_data_reader" {
  scope                = azurerm_monitor_workspace.this.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.this.identity[0].principal_id
}

resource "azurerm_role_assignment" "github_actions_grafana_editor" {
  scope                = azurerm_dashboard_grafana.this.id
  role_definition_name = "Grafana Editor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "grafana_admin" {
  for_each = var.grafana_admin_principal_ids

  scope                = azurerm_dashboard_grafana.this.id
  role_definition_name = "Grafana Admin"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "grafana_viewer" {
  for_each = var.grafana_viewer_principal_ids

  scope                = azurerm_dashboard_grafana.this.id
  role_definition_name = "Grafana Viewer"
  principal_id         = each.value
}
