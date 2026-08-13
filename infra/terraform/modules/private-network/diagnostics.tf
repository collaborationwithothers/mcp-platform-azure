# Resource-level platform diagnostics (issue 75's pattern, extended to this
# child's resources): apply-time category discovery, allLogs if the target
# offers it, individual categories otherwise, every returned metric
# category, and a precondition that fails loudly if Azure returns neither.
#
# Only the three NSGs are wired here, not azurerm_virtual_network.this
# itself. Verified at issue start (COMPATIBILITY.md): a virtual network
# exposes exactly one log category ("VM protection alerts"), and that
# category has no active destination table in the current Azure Monitor
# schema -- wiring it would pass this module's own precondition (the VNet's
# DDoS-related metric categories are real) but deliver no meaningful log
# signal, which does not meet this repo's honesty rule for what
# "observable" claims. NSGs, by contrast, have real, populated log
# categories (NetworkSecurityGroupEvent, NetworkSecurityGroupRuleCounter,
# NetworkSecurityGroupRuleFlowEvent).
locals {
  diagnostic_target_resource_ids = {
    nsg_aks_nodes     = azurerm_network_security_group.aks_nodes.id
    nsg_istio_ingress = azurerm_network_security_group.istio_ingress.id
    nsg_apim_outbound = azurerm_network_security_group.apim_outbound.id
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
