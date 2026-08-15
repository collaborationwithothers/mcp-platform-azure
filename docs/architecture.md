# Architecture

## Observability routing after issue 75

The live-test compositions are ephemeral. The shared observability resources
are not. The `shared-observability-core` Terraform state creates the
workspace-based Application Insights resource and its Log Analytics workspace
in a stable resource group outside the cleanup sweep. S1 and S2 read the core
state through OIDC-authenticated Terraform remote state.

S1 reads the Log Analytics workspace ID from core state. S2 reads that ID and
the Application Insights resource ID from the same state. The modules that own
the target resources add resource-level diagnostic settings and route the
selected exportable logs and metrics to the shared workspace.

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

## Shared observability after issue 124

[The editable Draw.io source](diagrams/issue-124-shared-observability.drawio)
shows the core and metrics state boundary, the AKS metrics path, and the
Argo CD-owned scrape configuration. It is source material for the human-owned
SVG export. The SVG must be exported from Draw.io and embedded here before this
topology change is complete.
