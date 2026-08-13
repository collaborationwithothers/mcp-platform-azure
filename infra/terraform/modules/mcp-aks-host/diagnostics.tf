# Resource-level platform diagnostics (issue 75's pattern, extended to this
# child's cluster): apply-time category discovery, allLogs if the target
# offers it, individual categories otherwise, every returned metric
# category, and a precondition that fails loudly if Azure returns neither.
# AKS control-plane logs (kube-apiserver, kube-audit, cluster-autoscaler,
# and siblings) and cluster metrics are both supported diagnostic settings
# targets for Microsoft.ContainerService/managedClusters; verified at issue
# start (see COMPATIBILITY.md).
locals {
  diagnostic_target_resource_ids = {
    aks_cluster = module.aks.resource_id
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
