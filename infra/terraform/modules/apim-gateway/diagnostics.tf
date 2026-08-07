# Resource-level platform diagnostics are supplemental to the issue 18
# per-API Application Insights audit diagnostic setting. The targets remain
# AVM-managed; apply-time category discovery avoids a module input/output cycle.
locals {
  diagnostic_targets = {
    apim_service = {
      resource_id  = module.apim.resource_id
      setting_name = "issue-75-apim-service-diagnostics"
    }
    audit_eventhub_namespace = {
      resource_id  = azurerm_eventhub_namespace.audit.id
      setting_name = "issue-75-audit-eventhub-namespace-diagnostics"
    }
  }
}

data "azurerm_monitor_diagnostic_categories" "this" {
  for_each = local.diagnostic_targets

  resource_id = each.value.resource_id
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  for_each = local.diagnostic_targets

  name                           = each.value.setting_name
  target_resource_id             = each.value.resource_id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  dynamic "enabled_log" {
    for_each = contains(data.azurerm_monitor_diagnostic_categories.this[each.key].log_category_groups, "allLogs") ? toset(["allLogs"]) : toset(data.azurerm_monitor_diagnostic_categories.this[each.key].log_category_types)

    content {
      category       = contains(data.azurerm_monitor_diagnostic_categories.this[each.key].log_category_groups, "allLogs") ? null : enabled_log.value
      category_group = contains(data.azurerm_monitor_diagnostic_categories.this[each.key].log_category_groups, "allLogs") ? enabled_log.value : null
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
      condition     = contains(data.azurerm_monitor_diagnostic_categories.this[each.key].log_category_groups, "allLogs") || length(data.azurerm_monitor_diagnostic_categories.this[each.key].log_category_types) > 0 || length(data.azurerm_monitor_diagnostic_categories.this[each.key].metrics) > 0
      error_message = "Diagnostic categories for ${each.value.resource_id} contain neither logs nor metrics."
    }
  }
}
