# ADR-004: Observability design

Status: Proposed (platform diagnostic routing implemented by issue 75; application
correlation, workbooks, and alerts remain deferred)
Date: 2026-07-08

## Context

The platform must answer: which tenant called which tool, how often, with
what outcome and latency, and alert on abuse or saturation. APIM MCP has a
documented constraint: with global diagnostic logging enabled, frontend
response payload byte logging must be 0 or MCP servers malfunction.

Issue 75 adds platform diagnostic settings for the current resources. These
settings route exportable Azure resource logs and platform metrics to the
durable Log Analytics workspace behind the out-of-band, workspace-based
Application Insights resource. They are necessary platform telemetry, but do
not by themselves provide the request and dependency correlation described by
this ADR.

## Decision (provisional)

The current decision is to make the Log Analytics workspace a required shared
input for the S1 and S2 compositions. Each composition derives its ARM resource
ID from `properties.WorkspaceResourceId` on the workspace-based Application
Insights resource, rather than accepting a second out-of-band workspace input.

Each current target discovers its diagnostic categories at apply time. If the
target offers the `allLogs` category group, the setting enables that group.
Otherwise it enables every returned log category. It also enables every metric
category returned by the diagnostic-category query. Azure's own exportability
rules still apply: enabling a returned category does not claim that Azure will
export a metric marked non-exportable.

Settings initially use the resource-specific `Dedicated` Log Analytics
collection mode. A target-specific `AzureDiagnostics` fallback is permitted
only after an actual gated deployment error proves that target rejects
`Dedicated`. The deployment fails if a target returns neither logs nor metrics.
API Center has no documentation-based category contract for this repository, so
its apply-time category discovery is deliberately fail-closed.

Issue 18's narrow per-tool deny audit path remains separate and unchanged. It
continues to use the Application Insights logger and the ephemeral Event Hubs
gate path. Resource-level diagnostics neither replace nor broaden that audit
mechanism.

## Alternatives considered

To document during v1.2 (e.g. APIM built-in analytics only; third-party
LLM observability tooling).

## Consequences

Platform diagnostic settings cover the two Function Apps, two App Service
plans, two storage accounts and their Blob, File, Queue, and Table service
scopes, the APIM service, API Center, and the Event Hubs namespace. Existing
storage-account mode needs permission to write diagnostic settings on the
caller-supplied account. The collection applies to the entire storage account
and its named service scopes, not only the deployment package.

Broad collection has an intentional cost trade-off. `allLogs` is a Microsoft
managed category group. Azure can add a category to it, which expands
collection and may increase ingestion without a Terraform diff. Cost is
measured after a gated deployment rather than estimated from an assumed
workload. See `docs/cost.md`.

Workbooks, alert rules, and application-level request and dependency
correlation remain deferred. Platform diagnostic settings are not evidence of
end-to-end request correlation. The APIM payload logging constraint remains
enforced in Terraform, not left to portal configuration.

## References

- [Choose between AzureRM and AzAPI Terraform providers](https://learn.microsoft.com/azure/developer/terraform/provider-selection-azurerm-vs-azapi)
- [Diagnostic settings in Azure Monitor](https://learn.microsoft.com/azure/azure-monitor/platform/diagnostic-settings)
- [Diagnostic settings for Azure Storage](https://learn.microsoft.com/azure/azure-monitor/platform/resource-manager-diagnostic-settings#diagnostic-setting-for-azure-storage)
- [Monitor Azure Event Hubs](https://learn.microsoft.com/azure/event-hubs/monitor-event-hubs-reference)
- [Estimate Azure Monitor costs](https://learn.microsoft.com/azure/azure-monitor/fundamentals/cost-estimate)
