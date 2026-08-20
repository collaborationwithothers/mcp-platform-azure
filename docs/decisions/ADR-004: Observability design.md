# ADR-004: Observability design

Status: Proposed (platform diagnostic routing and platform metrics implemented;
application correlation, workbooks, and alerts remain deferred)
Date: 2026-07-08 (updated 2026-08-15)

## Context

The platform must answer: which tenant called which tool, how often, with
what outcome and latency, and alert on abuse or saturation. APIM MCP has a
documented constraint: with global diagnostic logging enabled, frontend
response payload byte logging must be 0 or MCP servers malfunction.

Issue 75 added platform diagnostic settings for the current resources. These
settings route exportable Azure resource logs and platform metrics to the
durable Log Analytics workspace in the shared observability core state. That
state also owns the workspace-based Application Insights resource. They are
necessary platform telemetry, but do not by themselves provide the request and
dependency correlation described by this ADR.

## Decision

The current decision is to make the shared observability core state the source
of Log Analytics and Application Insights resource IDs. S1 and S2 read those
outputs through OIDC-authenticated Terraform remote state rather than accepting
direct resource-ID inputs.

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
API Center remains the APIM-linked registry, but it is not a diagnostic target.
Gated run 31162622718 proved Azure Monitor diagnostic settings are unsupported
for API Center. There is no fallback or capability registry for it.

Issue 18's narrow per-tool deny audit path remains separate and unchanged. It
continues to use the Application Insights logger and the ephemeral Event Hubs
gate path. Resource-level diagnostics neither replace nor broaden that audit
mechanism.

Issue 124 adds Azure Managed Grafana as a required platform service. This is a
deliberate product choice, not just a way to render the first AKS dashboards.
The Entra-authenticated Grafana workspace shows the cluster and
platform-component metrics that issue 124 puts in scope:
Kubernetes, the AKS Istio add-on, and Argo CD. Issue 124 does not wait for the
real MCP workload in issue 115 or the gateway cutover in issue 117. Later
observability work in issue 127 may reuse the same workspace for tool-call
success, failure, and token usage dashboards. Issue 124 does not claim those
application signals already exist or bring those later dashboards into scope.

Issue 124 uses Azure Monitor managed service for Prometheus. Prometheus
metrics go to an Azure Monitor workspace, a `Microsoft.Monitor/accounts`
resource that is separate from the existing Log Analytics workspace. The
managed service owns the Prometheus server and long-term metrics store. The AKS
cluster runs only the managed collection add-on and its scrape configuration.

Azure Managed Grafana keeps its public endpoint for this public-demo platform.
Microsoft Entra authentication and Azure role assignments control access. The
Grafana managed identity reads the Azure Monitor workspace directly, so
Grafana needs no route to the AKS internal ingress gateway. Issue 124 does not
add a private endpoint, private DNS, or another exception to the private-network
scope in AGENTS.md.

The Azure Monitor workspace also allows public ingestion and query access.
Azure authorization still controls data access; public network access does not
make the metrics anonymous. Issue 124 creates no Azure Monitor Private Link
Scope, private endpoint, or Grafana managed private endpoint. Production
guidance must identify private monitoring access as the stronger posture.

The Grafana workspace uses the Standard X1 instance size with zone redundancy
disabled and pins Grafana major version 12. Microsoft retired Managed Grafana
11 on 2026-06-15. Issue 124 adds a COMPATIBILITY.md row for the version pin and
the next major-version retirement notice is its re-check trigger. X1 is the
smallest current Standard size and matches the public demo's single-operator
workload. The deployment accepts a workspace outage during an
availability-zone failure because issue 124 has no uptime objective. Zone
redundancy is a production recommendation and a create-time choice, but its
extra cost is not justified for this demo. Repository-owned dashboard JSON
supports workspace recreation; it does not preserve collected metrics.

Human access is group-based and supplied out of band. Terraform accepts
`grafana_admin_principal_ids` and `grafana_viewer_principal_ids`; Hari's
operator group starts in the admin list and the viewer list starts empty. No
Entra object ID is committed. Grafana's system-assigned managed identity has a
separate `Monitoring Data Reader` assignment scoped only to the Azure Monitor
workspace. Human Grafana roles and data-source access are not the same grant.

The existing GitHub Actions workload identity receives `Grafana Editor` scoped
only to the Grafana workspace. That role lets the bootstrap workflow import and
overwrite the repository-owned dashboard without granting `Grafana Admin`.
The workflow identity does not receive the Grafana managed identity's
`Monitoring Data Reader` grant. The automation principal remains distinct from
both human access groups.

Azure Managed Grafana and the Azure Monitor workspace remain provisioned when
the AKS cluster is idled with `az aks stop`. The idle workflow stops only the
cluster. It does not delete or recreate the observability services, so Grafana
remains available for historical investigation and later issue 127 work. The
README and cost guide must state that these services have a lifecycle and cost
independent of the stopped cluster. No monthly figure is published without a
dated pricing basis or a real measurement.

Issue 124 proves this separate lifecycle through configuration, not an AKS
stop/start experiment. Acceptance checks the separate Terraform state, confirms
that the AKS idle workflow does not target the shared composition, and checks
that the runbook explains the continuing service and cost. The gated live test
proves initial metric ingestion and dashboard access. It then exercises the
metrics-only teardown and verifies that managed Prometheus is detached before
Grafana and the Azure Monitor workspace are destroyed. The core Log Analytics
and Application Insights resources remain. Finally, it bootstraps metrics
again, runs the AKS bootstrap to reattach managed Prometheus, re-imports the
repository dashboard, and verifies that Grafana, the dashboard, and collection
are operational. Acceptance must not leave the environment without its metrics
services.

The shared observability boundary is Terraform-owned. Issue 124 creates a new
Log Analytics workspace and a new workspace-based Application Insights resource
alongside the new Azure Monitor workspace and Grafana workspace. It does not
import or adopt the manually created Log Analytics and Application Insights
resources. Hari confirmed on 2026-08-14 that their existing data has no value
that must be retained, so replacement is acceptable.

All four replacement services are placed in the existing shared observability
resource group. Terraform looks up that resource group but does not create,
import, or delete it. The manual and replacement resources coexist there until
cutover. Two shared compositions separate their lifecycles.
`shared-observability-core` owns Log Analytics and Application Insights.
`shared-observability-metrics` owns the Azure Monitor workspace, Grafana, and
their role assignments. Each composition has its own backend state key.
The four Azure resources are declared directly in those compositions. Issue
124 does not add wrapper modules that would only repeat provider arguments and
have no second caller.
Issue 124 adds no Azure management locks. The workflow and repository
governance provide the lifecycle safeguards, while metrics teardown remains an
intentional supported operation.
Both compositions accept the repository's optional `tags` map with a default
of `{}`. Terraform merges it with fixed `component = shared-observability` and
`lifecycle = core|metrics` tags. These tags require no GitHub Environment
variable.
Issue 124 adds no `.tftest.hcl` files. Terraform proof consists of the existing
format and validation checks, reviewed plan output, and the gated live test.
The `live-test` GitHub Environment supplies the existing group name through
`SHARED_OBSERVABILITY_RESOURCE_GROUP`. The workflow passes it to both shared
compositions. This is the only new environment-specific observability input.
Resource names are deterministic and require no additional inputs. Terraform
appends the first eight characters of the resource group name's SHA-1 hash to
the bases `mcp-shared-law`, `mcp-shared-appi`, `mcp-shared-amw`, and
`mcp-grafana`. `mcp-shared-grafana` cannot use the same suffix because its
27-character result exceeds Azure Managed Grafana's
[23-character name limit](https://learn.microsoft.com/azure/managed-grafana/troubleshoot-managed-grafana#azure-managed-grafana-workspace-creation-fails).
All four resources use the existing `LIVE_TEST_LOCATION` value. Issue-start
verification must confirm that Azure Monitor workspace and Managed Grafana are
available there. If either is unavailable, implementation stops instead of
selecting another region silently.

The replacement Log Analytics workspace exposes
`log_analytics_retention_days` as a Terraform variable with a default of `30`.
Issue 124 adds no table-specific long-term retention. The platform has no longer
audit-retention requirement, and the repository does not claim that the old
manual workspace's history was migrated.
The Log Analytics workspace disables local authentication. Current consumers
use diagnostic settings, resource IDs, and managed identities rather than
workspace shared keys. Shared-key ingestion and queries are not a supported
platform path.
Log Analytics and Application Insights keep public ingestion and query access
enabled. Issue 124 adds no Azure Monitor Private Link Scope or private endpoint
for either resource. This preserves access from APIM and public GitHub-hosted
runners. Authorization remains required.

The core composition also exposes `daily_ingestion_cap_gb` with a default of
`5`. The same value configures the Log Analytics and workspace-based Application
Insights daily caps. No GitHub Environment variable is required. The 5 GB/day
value is Hari's 2026-08-14 safety guardrail, not measured usage or a cost
estimate. If the cap is reached, Azure stops collection until the daily reset
and data sent during that gap is lost.
Terraform explicitly sets Application Insights daily-cap email notifications
to disabled. The cap is a documented safety guardrail, not a notification path.
Application Insights keeps local authentication enabled. The existing APIM
audit logger reads its connection string, and issue 124 does not replace that
path with Microsoft Entra-authenticated ingestion. The repository does not
claim an Entra-only ingestion posture.

### Amendment: issue #154

The issue #154 target changes the Application Insights posture. Terraform will
disable local authentication after the APIM audit logger and the MCP pod both
use Entra identities. The APIM logger will keep its system-assigned identity.
The MCP pod will use its workload identity with component-scoped `Monitoring
Metrics Publisher` for ingestion and Reader for the ARM component read.

Azure Monitor OpenTelemetry needs the component connection string to select the
ingestion endpoint even when the workload identity authenticates ingestion. The
pod will receive only the component resource ID through a live-only Kubernetes
Secret. It will read the connection string through ARM at startup and hold that
value only in process memory. The component resource ID and connection string
will never be committed or sent in a promotion payload. Live evidence remains
pending until the recorded run.

Shared observability has its own `workflow_dispatch` workflow. It reuses the
existing `live-test` GitHub Environment, OIDC identity, and `ubuntu-latest`
runner. `bootstrap` applies core first and metrics second. `teardown` destroys
only `shared-observability-metrics`; there is no routine workflow action that
destroys `shared-observability-core`. `verify` is read-only. It checks the
managed Prometheus attachment, Argo CD reconciliation, scrape-target health,
required PromQL queries, and repository dashboard presence. `bootstrap` and
`teardown` require the action name to be typed back exactly. `verify` does not.
Verification writes a concise GitHub job summary and uses the normal workflow
logs for detail. It does not upload a separate evidence artifact.
The runbook warns that metrics teardown deletes historical Prometheus data and
any Grafana state not stored as code.

The ephemeral S1/S2 workflow, AKS platform workflow, and shared-observability
workflow all use `concurrency.group: live-test` with
`cancel-in-progress: false`. The shared group queues operations against the one
live-test environment instead of allowing related Terraform states and the AKS
cluster to be changed concurrently.

Shared-observability bootstrap stops after creating its own resources. It does
not attach or reattach the AKS cluster. The normal `deploy-aks-platform`
bootstrap remains the only routine workflow that applies AKS configuration and
enables managed Prometheus. First deployment and recovery therefore use an
explicit two-step order: shared-observability bootstrap, then AKS bootstrap.

Before metrics teardown destroys the Azure Monitor workspace, it disables the
managed Prometheus add-on on AKS and verifies that collection is detached. The
disable operation removes the in-cluster collector and Azure's collection rule,
endpoint, association, and recording-rule resources. It does not delete stored
Prometheus data; destroying the Azure Monitor workspace does that in the next
step. `s1-aks-platform` exposes `managed_prometheus_enabled`, defaulting to
`true`. Metrics teardown runs a normal plan and apply with that value set to
`false`. It refuses to continue if the plan contains changes outside the
intended AKS monitoring configuration. This updates the AKS resource and its
Terraform state together instead of creating deliberate drift with a direct
Azure CLI update.

S1, S2, and `s1-aks-platform` read shared observability outputs through
read-only `terraform_remote_state`. S1 and S2 consume the replacement
Application Insights and Log Analytics resource IDs from the core state.
`s1-aks-platform` consumes the Log Analytics workspace ID from core and the
Azure Monitor workspace ID from metrics. The existing
`TF_VAR_shared_observability_application_insights_id` GitHub Environment
variable and the equivalent direct Terraform inputs are removed after cutover.
Neither shared state exposes a sensitive output.

Issue 124 ships one repository-owned dashboard as versioned JSON. It lives in
the `MCP Platform` folder, has the title `AKS Platform Overview`, and uses the
stable UID `aks-platform-overview`. The bootstrap workflow imports it
idempotently with overwrite behaviour through the Azure CLI session already
authenticated by workload identity federation. It does not create or store a
Grafana API key, service-account token, GitHub App credential, or personal
access token. Microsoft-managed dashboards remain supporting views rather than
the repository's acceptance artifact.
Required CI performs a lightweight repository-contract check. It proves that
the dashboard file is valid JSON and contains the fixed title, UID, and four
required section names. Live acceptance, not this static check, proves that the
queries work against Azure.

The dashboard uses a hidden Prometheus data-source selector instead of a
hardcoded Grafana data-source UID. It exposes one visible cluster selector and
no namespace selector. Platform namespace filters remain fixed in the queries.
The implementation must discover and verify Azure's actual cluster label from
live data before those queries are accepted.

The overview dashboard has four fixed sections. Collection health distinguishes
a failed scrape from a quiet workload. Kubernetes panels show node readiness,
CPU and memory use, and unhealthy pods. Argo CD panels show application sync and
health status plus reconciliation errors. Istio panels show control-plane
health, request rate, error ratio, and p95 request duration. Detailed
Microsoft-managed dashboards remain drill-down views rather than being copied
into the repository dashboard.

Status colors represent factual states only, such as a scrape target being
down, a pod being unready, or an Argo CD Application being unhealthy or out of
sync. CPU, memory, request rate, error ratio, and duration charts have no
numeric warning or failure thresholds. Issue 124 has no measured baseline or
agreed service objective that would justify those thresholds.

The dashboard defaults to the last six hours and refreshes every minute. A
viewer can change both settings. These are display defaults, not retention or
service-level commitments.

Issue 124 generates no workload traffic. Istio request-rate, error-ratio, and
duration panels may therefore show `No data` until a real caller reaches the
cluster. Acceptance requires the Istio scrape and control-plane health signals
to be present and the traffic queries to load without an error. It does not
require non-empty traffic results or treat their absence as a failed scrape.

The managed Prometheus add-on keeps Microsoft's minimal ingestion profile for
its default AKS targets. Argo CD and Istio use explicit scrape targets and
metric allowlists limited to the panels and live checks that issue 124 owns.
Issue 124 does not enable cluster-wide pod-annotation discovery, collect every
metric from either component, or disable minimal ingestion. This boundary
reduces accidental high-cardinality series and uncontrolled ingestion. A later
change must name the additional metric and its consumer before widening a keep
list.

Every custom Argo CD and Istio target uses a fixed 60-second scrape interval.
The interval is not exposed as a Terraform, workflow, or GitHub Environment
variable. This platform does not require sub-minute detection, and a fixed
slower cadence limits ingestion. The tradeoff is slower visibility than a
shorter interval.

Argo CD uses three explicit ServiceMonitor targets: the application controller
metrics service, repository server metrics service, and API server metrics
service. Dex, notifications, and ApplicationSet metrics remain excluded unless
a later dashboard panel or verification check names them as a dependency.
The Argo CD metric allowlist contains `argocd_app_info`,
`argocd_app_condition`, the `argocd_app_reconcile` histogram family,
`argocd_app_sync_total`, `argocd_git_request_total`,
`argocd_git_fetch_fail_total`, the `argocd_git_request_duration_seconds`
histogram family, and `grpc_server_handled_total`. Prometheus-generated target
health series such as `up` remain available for collection checks.

Istio pod-annotation scraping is limited to `aks-istio-system` and
`aks-istio-ingress`. It excludes the MCP workload namespace. The Istio traffic
panels therefore describe requests observed by the ingress gateway, not
sidecar-to-sidecar workload traffic. This keeps issue 124 inside its platform
observability boundary while preserving ingress request, error, and duration
signals.
The Istio metric allowlist contains `pilot_info`,
`pilot_total_xds_internal_errors`, `pilot_total_xds_rejects`,
`pilot_total_rejected_configs`, the `pilot_proxy_convergence_time` histogram
family, `istio_requests_total`, and the
`istio_request_duration_milliseconds` histogram family.

The public `mcp-platform-kubernetes-manifests` repository owns the Argo CD and
Istio scrape resources. Its `argocd/apps` tree is already the source watched by
this platform's root app-of-apps Application. Issue 124 adds the monitoring
resources there so Argo CD continuously reconciles drift. Planning and history
remain in this repository because the manifests repository has no issue tracker.
Delivery requires a coordinated companion PR in that repository.

The live test accepts the companion manifests PR's immutable 40-character
commit SHA. It validates that input and temporarily changes the root Argo CD
Application to the exact SHA. It disables root self-healing for the short
exercise, then changes the observability child Application to the same SHA.
This lets the child read the unmerged `base/observability` path. The workflow
waits for Argo CD to reconcile the Argo CD and Istio scrape resources, and
proves that the expected targets and queries work. The job summary records the
tested SHA. A cleanup step restores the root Application to `main` and enables
root self-healing after either success or failure. This tests the unmerged
desired state without leaving the platform attached to a feature revision. If
cleanup cannot prove that the root Application is back on `main` and healthy,
the workflow fails before metrics teardown. It leaves Grafana, the Azure Monitor
workspace, and managed Prometheus intact for diagnosis and prints the manual
recovery procedure.

The infrastructure PR is merged and deployed before the companion manifests
PR is merged. Managed Prometheus therefore installs the monitoring custom
resource definitions before Argo CD sees the new scrape resources on `main`.
The short interval between the two merges has default AKS metrics but not the
Argo CD and Istio scrape configuration.

Issue 124 remains open until both PRs merge. Final acceptance verifies that the
root Application tracks `main`, Argo CD has reconciled the scrape resources,
and the Argo CD and Istio targets are healthy. The pre-merge exact-revision
test does not replace this deployed-state check.

Issue 124 does not create alert rules, notification action groups, or paging
routes. Its operational proof ends at metric collection, PromQL queries, and
dashboard rendering. Alert thresholds need an agreed response owner and
notification destination, neither of which this public demo defines. Alerting
can build on the same Azure Monitor workspace in later planning without
blocking this foundation. The 5 GB/day daily cap is not an exception. The
runbook warns that reaching it stops collection and causes unrecoverable gaps,
but issue 124 creates no cap-reached alert.

Issue 124 has no dependency on issue 121's public DNS and Entra single sign-on
for the Argo CD user interface. Managed Prometheus discovers and scrapes Argo
CD metrics inside the cluster. Grafana queries the Azure Monitor workspace, not
the Argo CD interface. The two issues may therefore ship in either order.

## Alternatives considered

Azure Monitor dashboards with Grafana provide a no-cost Azure portal experience
for Azure Monitor data. Microsoft recommends that experience first when Azure
Monitor is the only data source. Issue 124 rejects it because the platform needs
a standalone Grafana service that later observability work can reuse. Azure
Managed Grafana therefore carries a standing service and user cost even when the
AKS cluster is stopped.

Managed Grafana Essential is not an option for a new deployment. Microsoft no
longer allows new Essential workspaces and plans to retire existing ones on
2027-03-31. If issue 124 keeps Azure Managed Grafana, it must use Standard or a
later supported replacement verified at issue start.

Self-hosted Prometheus was rejected. It would add an in-cluster server, storage,
upgrades, and another private connection for Grafana to reach. It would also
duplicate the managed metrics service issue 124 exists to demonstrate. APIM
built-in analytics and third-party LLM observability tooling remain deferred.

A private Grafana endpoint was rejected for this ticket. Microsoft recommends
private endpoints and disabled public access to reduce the production attack
surface. That posture would require a private client and DNS path, and it falls
outside issue 124's public-demo scope. The production guidance remains explicit
rather than being presented as a property of this deployment.

Putting managed observability in the `s1-aks-platform` composition was
rejected. It would reduce workflow and state count, but it would also tie the
shared dashboard and metrics store to one compute platform's destroy lifecycle.

Applying platform scrape manifests directly from `deploy-aks-platform.yml` was
rejected after initially being selected. A workflow reapply would repair drift
only during bootstrap. Argo CD ownership provides continuous reconciliation and
keeps Kubernetes desired state in the existing manifests repository.

Importing the existing Application Insights and Log Analytics resources was
rejected. Issue 124 creates replacements because Hari confirmed that the manual
resources contain no data that must be retained. This avoids importing unknown
portal configuration into the new state, at the cost of a consumer cutover and
no migration of existing history.

Generating synthetic Istio traffic through `kubectl port-forward` during the
bootstrap workflow was rejected. That mechanism would make traffic panels
non-empty without proving the later APIM-to-AKS route. Issue 124 does not use it
as observability evidence.

Running an AKS `idle-stop` and `idle-start` cycle as issue 124 acceptance
evidence was rejected. The issue must not claim that it measured dashboard or
metric continuity across a stopped cluster.

Leaving Log Analytics and Application Insights without daily ingestion caps was
rejected. Both replacement resources use Hari's explicit 5 GB/day guardrail.

## Consequences

Platform diagnostic settings cover 16 supported targets: 14 Function-host
targets across the two Function App instances, the APIM service, and the Event
Hubs namespace. The Function-host targets are the two Function Apps, two App
Service plans, two storage accounts, and their Blob, File, Queue, and Table
service scopes. Existing storage-account mode needs permission to write
diagnostic settings on the caller-supplied account. The collection applies to
the entire storage account and its named service scopes, not only the deployment
package.

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
- [Manage Log Analytics data retention](https://learn.microsoft.com/azure/azure-monitor/logs/data-retention-configure)
- [Set a daily cap on Log Analytics](https://learn.microsoft.com/azure/azure-monitor/logs/daily-cap)
- [Visualize Azure Monitor data with Grafana](https://learn.microsoft.com/azure/azure-monitor/visualize/visualize-grafana-overview)
- [Azure Managed Grafana service tiers](https://learn.microsoft.com/azure/managed-grafana/overview#service-tiers)
- [Enable zone redundancy in Azure Managed Grafana](https://learn.microsoft.com/azure/managed-grafana/how-to-enable-zone-redundancy)
- [Azure Monitor and Prometheus](https://learn.microsoft.com/azure/azure-monitor/metrics/prometheus-metrics-overview)
- [Enable monitoring for AKS clusters](https://learn.microsoft.com/azure/azure-monitor/containers/kubernetes-monitoring-enable)
- [Use private endpoints for an Azure Monitor workspace](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-azure-monitor-workspace)
- [Default Prometheus metrics configuration](https://learn.microsoft.com/azure/azure-monitor/containers/prometheus-metrics-scrape-default)
- [Collect Argo CD metrics](https://learn.microsoft.com/azure/azure-monitor/containers/prometheus-argo-cd-integration)
- [Collect Istio metrics](https://learn.microsoft.com/azure/azure-monitor/containers/prometheus-istio-integration)
- [Secure Azure Managed Grafana](https://learn.microsoft.com/azure/managed-grafana/secure-azure-managed-grafana)
- [Manage access to Azure Managed Grafana](https://learn.microsoft.com/azure/managed-grafana/how-to-manage-access-permissions-users-identities)
- [Create and import an Azure Managed Grafana dashboard](https://learn.microsoft.com/azure/managed-grafana/how-to-create-dashboard#import-a-grafana-dashboard)
