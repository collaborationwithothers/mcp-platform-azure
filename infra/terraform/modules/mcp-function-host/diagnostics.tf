# Resource-specific categories vary by Azure resource type. Querying each
# concrete resource ID at apply time keeps this wrapper aligned with the
# categories Azure exposes for the Function App, plan, and storage scopes.
locals {
  diagnostic_target_resource_ids = {
    function_app          = module.function_app.resource_id
    service_plan          = azurerm_service_plan.this.id
    storage_account       = local.storage_account_id
    storage_blob_service  = "${local.storage_account_id}/blobServices/default"
    storage_file_service  = "${local.storage_account_id}/fileServices/default"
    storage_queue_service = "${local.storage_account_id}/queueServices/default"
    storage_table_service = "${local.storage_account_id}/tableServices/default"
  }
}

data "azurerm_monitor_diagnostic_categories" "this" {
  for_each = local.diagnostic_target_resource_ids

  resource_id = each.value
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  for_each = local.diagnostic_target_resource_ids

  name                           = "mcp-${each.key}-diagnostics"
  target_resource_id             = each.value
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  dynamic "enabled_log" {
    for_each = contains(data.azurerm_monitor_diagnostic_categories.this[each.key].log_category_groups, "allLogs") ? {
      all_logs = {
        category       = null
        category_group = "allLogs"
      }
      } : {
      for category in data.azurerm_monitor_diagnostic_categories.this[each.key].log_category_types : category => {
        category       = category
        category_group = null
      }
    }

    content {
      category       = enabled_log.value.category
      category_group = enabled_log.value.category_group
    }
  }

  dynamic "enabled_metric" {
    for_each = toset(data.azurerm_monitor_diagnostic_categories.this[each.key].metrics)

    content {
      category = enabled_metric.value
    }
  }

  lifecycle {
    precondition {
      condition = contains(data.azurerm_monitor_diagnostic_categories.this[each.key].log_category_groups, "allLogs") || length(data.azurerm_monitor_diagnostic_categories.this[each.key].log_category_types) > 0 || length(data.azurerm_monitor_diagnostic_categories.this[each.key].metrics) > 0

      error_message = "Azure exposed no allLogs group, log category, or metric category for ${each.value}. Diagnostic settings require at least one category."
    }
  }
}
