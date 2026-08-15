data "azurerm_resource_group" "shared_observability" {
  name = var.resource_group_name
}

locals {
  name_suffix = substr(sha1(var.resource_group_name), 0, 8)
  tags = merge(var.tags, {
    component = "shared-observability"
    lifecycle = "core"
  })
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "mcp-shared-law-${local.name_suffix}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.shared_observability.name
  retention_in_days   = var.log_analytics_retention_days
  daily_quota_gb      = var.daily_ingestion_cap_gb

  # Existing consumers use resource IDs and managed identities. Shared keys
  # are not a supported path for the replacement workspace.
  local_authentication_enabled = false
  internet_ingestion_enabled   = true
  internet_query_enabled       = true
  tags                         = local.tags
}

resource "azurerm_application_insights" "this" {
  name                = "mcp-shared-appi-${local.name_suffix}"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.shared_observability.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.this.id
  retention_in_days   = var.log_analytics_retention_days

  daily_data_cap_in_gb                 = var.daily_ingestion_cap_gb
  daily_data_cap_notifications_enabled = false
  local_authentication_enabled         = true
  internet_ingestion_enabled           = true
  internet_query_enabled               = true
  tags                                 = local.tags
}
