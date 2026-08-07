# Diagnostic settings guidance

This guidance applies when a future v1 scenario adds an Azure resource that
must route platform telemetry to the shared Log Analytics workspace. It is a
rule for implementation and review. It is not a capability matrix or a
registry of resource types.

## Required approach

Use the AzureRM provider for `azurerm_monitor_diagnostic_categories` and
`azurerm_monitor_diagnostic_setting` when the provider can express the
setting. AzureRM is the normal Terraform choice for supported, stable resource
types. Do not introduce an AzAPI diagnostic-setting resource merely because a
new target is unfamiliar. If AzureRM cannot express a required setting, stop,
verify the ARM contract, and obtain an explicit decision before considering an
AzAPI fallback. [Choose between AzureRM and AzAPI Terraform
providers](https://learn.microsoft.com/azure/developer/terraform/provider-selection-azurerm-vs-azapi)
explains that AzureRM is the default for supported resources.

For every concrete target resource ID, query categories at apply time. Do not
hard-code a service's log or metric names, and do not introduce a capability
registry, scanner, matrix, or diagnostics-specific CI check.

1. Require the target module to receive a non-null Log Analytics workspace ARM
   resource ID.
2. Query the target with `azurerm_monitor_diagnostic_categories`.
3. If its returned log category groups contain `allLogs`, enable exactly that
   category group. Otherwise enable every value returned as an individual log
   category.
4. Enable every metric category returned by the query.
5. Add a lifecycle precondition that fails when the query returns neither a log
   category or group nor a metric category.
6. Create the setting with `Dedicated` as the Log Analytics destination type.
   Use `AzureDiagnostics` only for the specific target that a gated deployment
   proves rejects `Dedicated`.

Diagnostic settings collect resource logs and can route platform metrics, but
Azure documents that not all platform metrics are exportable. Enabling every
returned metric category must never be described as exporting a metric Azure
marks non-exportable. [Diagnostic settings in Azure
Monitor](https://learn.microsoft.com/azure/azure-monitor/platform/diagnostic-settings)
documents the source categories, category groups, metric limitation, and
destination behavior.

`allLogs` is intentionally broad. Microsoft can add categories to that group,
so collection and cost can expand without a Terraform configuration diff. A
new target also needs a post-deployment measurement before a cost claim is
made. See `docs/cost.md`.

## Mandatory proof and exceptions

The diagnostic setting is configuration proof only after the existing gated
apply succeeds. Do not add a telemetry-ingestion assertion to the live-test
workflow. If category discovery, the precondition, or the setting itself fails,
use the actual Azure error to decide the next action. Do not weaken the target
set to make the deployment pass.

API Center is not a diagnostic target. Azure Monitor's [supported resource-log
categories](https://learn.microsoft.com/azure/azure-monitor/reference/supported-logs/logs-index)
index and [built-in diagnostic-settings policy support
list](https://learn.microsoft.com/azure/azure-monitor/platform/diagnostic-settings-policy-built-in#supported-resources)
omit `Microsoft.ApiCenter/services`. Gated run 31162622718 then proved Azure
Monitor diagnostic settings are unsupported for API Center. It remains the
APIM-linked registry. Do not add category discovery, a fallback, or a
capability registry for API Center diagnostics.

For Storage, use the account resource and the documented Blob, File, Queue, and
Table service scopes. A module that accepts an existing account must document
that the deploying principal needs diagnostic-setting write permission on that
account, and that collection covers the entire account and those service scopes,
not only the deployment-package container. [Azure Storage diagnostic-setting
scopes](https://learn.microsoft.com/azure/azure-monitor/platform/resource-manager-diagnostic-settings#diagnostic-setting-for-azure-storage)
documents the separate service-scope pattern.

For Event Hubs, configure the namespace unless current Microsoft documentation
and the implementation ticket establish a different target. Do not infer that
an Event Hub entity needs its own setting from the existence of entity-level
dimensions in namespace telemetry. [Event Hubs monitoring
reference](https://learn.microsoft.com/azure/event-hubs/monitor-event-hubs-reference)
is the service reference to re-check.
