# Architecture

## Observability routing after issue 75

The live-test compositions are ephemeral. The shared observability resources
are not. Hari provisions a workspace-based Application Insights resource and
its Log Analytics workspace in a stable resource group outside the cleanup
sweep. The GitHub `live-test` Environment supplies the Application Insights ARM
resource ID as `TF_VAR_shared_observability_application_insights_id`.

Both S1 and S2 read `properties.WorkspaceResourceId` from that Application
Insights resource. They pass the derived workspace ARM ID to the modules that
own the target resources. Those modules add resource-level diagnostic settings
for the current target set and route the selected exportable logs and metrics to
the shared workspace.

![Issue 75 diagnostic routing: the 16 supported Function-host, API Management,
and Event Hubs targets route exportable platform diagnostics to the persistent
Log Analytics workspace. API Center remains an APIM-linked registry without
Azure Monitor diagnostics, and the separate issue 18 deny audit route remains
unchanged.](diagrams/diagnostic-routing.drawio.svg)

API Center remains the APIM-linked registry. It is not a diagnostic target:
gated run 31162622718 proved that Azure Monitor diagnostic settings are
unsupported for API Center.

The route is separate from issue 18. Issue 18 keeps its narrow APIM per-tool
deny audit path to the Application Insights logger and its ephemeral Event Hubs
gate signal. The new settings do not replace that path and do not change its
authorization decision or audit semantics.

This routing provides platform resource telemetry. It is not application
instrumentation and does not complete distributed request or dependency
correlation. Workbooks and alerts remain deferred by ADR-004. The diagram above
is the human-exported editable SVG; its Draw.io source remains alongside it.
