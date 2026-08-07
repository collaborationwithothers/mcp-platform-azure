# Observability

## Current platform diagnostic routing

Issue 75 configures required Azure Monitor diagnostic settings for 17 current
resource-level targets. The two S1 Function App instances each contribute the
Function App, App Service plan, storage account, and Blob, File, Queue, and
Table service scopes. S2 contributes the APIM service, API Center service, and
Event Hubs namespace.

Each target discovers its logs, category groups, and metric categories at apply
time. The setting uses `allLogs` when Azure offers it. Otherwise it enables each
returned log category and every returned metric category. This is broad
collection of what the target reports as selectable, not a claim that Azure
exports platform metrics it marks non-exportable. Azure documents the category
and metric limits in [Diagnostic settings in Azure
Monitor](https://learn.microsoft.com/azure/azure-monitor/platform/diagnostic-settings).

The destination is the Log Analytics workspace behind the durable,
workspace-based Application Insights resource. S1 and S2 receive only
`shared_observability_application_insights_id`. They read that resource's
`WorkspaceResourceId` property to derive the workspace ARM ID. The value is
supplied out of band as
`TF_VAR_shared_observability_application_insights_id`, never committed.

The first attempted destination type is `Dedicated`, which produces
resource-specific tables where Azure accepts it. A specific target can switch to
`AzureDiagnostics` only after a gated live deployment returns an Azure error
proving that `Dedicated` is not accepted for that target. Microsoft describes
resource-specific and `AzureDiagnostics` collection modes in [Resource logs in
Azure Monitor](https://learn.microsoft.com/azure/azure-monitor/platform/resource-logs#collection-mode).

## Boundaries and proof

The setting fails before creation if a target has neither returned logs nor
metrics. API Center is fail-closed. Microsoft Learn does not establish an API
Center diagnostic-category contract usable here, so the category claim is
**UNVERIFIABLE**. A rejected query, an empty result, or an Azure rejection of
the setting blocks the deployment rather than silently omitting API Center.

Storage diagnostics include the whole existing or created account and its Blob,
File, Queue, and Table service scopes. Existing-account mode therefore requires
permission to write diagnostic settings on the caller-supplied account. It does
not restrict collection to the `deploymentpackage` container. The service-scope
shape is documented in [Azure Storage diagnostic settings](https://learn.microsoft.com/azure/azure-monitor/platform/resource-manager-diagnostic-settings#diagnostic-setting-for-azure-storage).

The Event Hubs target is the namespace, not an Event Hub entity. Its categories
are discovered at apply time. The [Event Hubs monitoring
reference](https://learn.microsoft.com/azure/event-hubs/monitor-event-hubs-reference)
is re-checked when that target changes.

Issue 18's narrow per-tool deny audit is unchanged. Its APIM Application
Insights logger and ephemeral Event Hubs gate path are independent of these
resource-level settings. Platform diagnostics do not complete ADR-004's
application request or dependency correlation. They also do not create a
workbook, alert, or telemetry-ingestion assertion.

`allLogs` can expand when Azure adds a category to the group. That can increase
ingestion without a Terraform diff. The first successful gated apply proves
Azure accepts the settings. It does not measure cost or prove telemetry arrival.
Follow the dated procedure in `docs/cost.md` after deployment.
