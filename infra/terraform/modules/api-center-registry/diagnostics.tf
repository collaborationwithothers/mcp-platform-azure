# API Center does not publish an authoritative Azure Monitor category list.
# Discover the categories at apply time from the deployed service and fail
# closed if that query does not yield a usable log group, log category, or
# metric category. The generic AzureRM diagnostic setting is supplemental to
# the azapi-managed API Center resource; do not replace it with an AzAPI
# diagnostic resource without first verifying an ARM payload and updating the
# compatibility record.
data "azurerm_monitor_diagnostic_categories" "api_center" {
  resource_id = azapi_resource.api_center.id
}

locals {
  # allLogs takes precedence when Azure exposes it. Azure maintains the group,
  # so new log categories are included without a Terraform change. If it is
  # absent, retain the explicit categories Azure returns instead.
  api_center_diagnostic_log_groups        = contains(data.azurerm_monitor_diagnostic_categories.api_center.log_category_groups, "allLogs") ? toset(["allLogs"]) : toset([])
  api_center_diagnostic_log_categories    = contains(data.azurerm_monitor_diagnostic_categories.api_center.log_category_groups, "allLogs") ? toset([]) : toset(data.azurerm_monitor_diagnostic_categories.api_center.log_category_types)
  api_center_diagnostic_metric_categories = toset(data.azurerm_monitor_diagnostic_categories.api_center.metrics)
}

resource "azurerm_monitor_diagnostic_setting" "api_center" {
  name                           = "mcp-platform-diagnostics"
  target_resource_id             = azapi_resource.api_center.id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  dynamic "enabled_log" {
    for_each = local.api_center_diagnostic_log_groups

    content {
      category_group = enabled_log.value
    }
  }

  dynamic "enabled_log" {
    for_each = local.api_center_diagnostic_log_categories

    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_metric" {
    for_each = local.api_center_diagnostic_metric_categories

    content {
      category = enabled_metric.value
    }
  }

  lifecycle {
    precondition {
      condition = (
        length(local.api_center_diagnostic_log_groups) +
        length(local.api_center_diagnostic_log_categories) +
        length(local.api_center_diagnostic_metric_categories)
      ) > 0
      error_message = "API Center did not return a usable diagnostic log group, log category, or metric category. API Center diagnostics are mandatory, so apply stops rather than omitting this target."
    }
  }
}
