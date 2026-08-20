# Observability

The platform has two shared observability states. Core state holds the Log
Analytics workspace and workspace-based Application Insights resource used by
S1 and S2. Metrics state holds the Azure Monitor workspace and Azure Managed
Grafana used by AKS. Destroying metrics state must not destroy the core state.

## Shared resources and consumers

`infra/compositions/shared-observability-core` creates a Log Analytics
workspace and a workspace-based Application Insights resource. Both have a
30-day retention setting and a 5 GB daily cap. The cap is a guardrail. It is
not a cost estimate. Reaching it stops collection and leaves an unrecoverable
gap until the next day.

The core Log Analytics workspace disables local authentication. The issue #154 target disables Application Insights local authentication. The existing APIM
audit logger uses its system-assigned managed identity. The target MCP pod uses its workload identity. Both need the `Monitoring Metrics Publisher` role on
the Application Insights component.

The target Azure Monitor OpenTelemetry distribution still needs the component connection string to select the ingestion endpoint. That string is not an
ingestion credential when the distribution has an Entra credential. The target
pod will read it at startup through ARM with its workload identity. A live-only
Kubernetes Secret will supply only the component resource ID. Neither value is committed or dispatched to the GitOps repository. The workload identity will
have component-scoped Reader for that ARM read and `Monitoring Metrics
Publisher` for telemetry ingestion.

Both resources allow public ingestion and query for the public-demo profile.
Public network access does not allow anonymous ingestion. The issue #154 target
requires both writers to authenticate through Entra. Live evidence remains
pending until the recorded run.

S1 and S2 read the core state through OIDC-authenticated Terraform remote
state. S1 uses the Log Analytics workspace ID for Function-host diagnostic
settings. S2 also reads the Application Insights ID for the existing APIM audit
logger. The former direct input
`TF_VAR_shared_observability_application_insights_id` is removed.

`infra/compositions/shared-observability-metrics` creates an Azure Monitor
workspace and an Azure Managed Grafana workspace. Azure Monitor workspaces
store Prometheus metrics and are different from Log Analytics workspaces, which
store logs and traces. The Grafana workspace runs on Standard X1, uses Grafana
12, has a public endpoint, and uses a system-assigned managed identity with
`Monitoring Data Reader` only on the Azure Monitor workspace. Microsoft
documents that Grafana can query managed Prometheus through this integration in
[Azure Monitor and Prometheus](https://learn.microsoft.com/azure/azure-monitor/metrics/prometheus-metrics-overview).

The GitHub Actions workload identity receives `Grafana Editor` only on the
Grafana workspace. It imports the repository dashboard without an API key,
service account token, or personal access token. Human Grafana Admin and Viewer
principal IDs are optional Terraform inputs supplied outside the repository.

## AKS collection and scrape limits

The AKS composition reads both shared states. It enables the Azure Monitor
managed Prometheus add-on and creates the endpoint, rule, and associations that
send metrics to the Azure Monitor workspace. Its
`managed_prometheus_enabled` input defaults to `true`. Setting it to `false`
removes the add-on attachment and the scenario-owned collection resources. The
normal AKS bootstrap restores the attachment after metrics state is recreated.

The managed Prometheus add-on keeps Microsoft's minimal ingestion profile for
default Kubernetes targets. Argo CD and Istio are separate, limited targets in
the companion manifests repository:

- Three ServiceMonitors scrape only the Argo CD controller, repository server,
  and API server every 60 seconds. Their keep lists contain only the Argo
  metrics used by the dashboard and verification checks, plus `up`.
- Pod annotation scraping is limited to `aks-istio-system` and
  `aks-istio-ingress`, also every 60 seconds. It does not scrape the MCP
  workload namespace. Its keep list contains only the selected Istio control
  plane and ingress traffic metrics, plus `up`.

Azure Monitor installs the ServiceMonitor custom resource definition when the
managed Prometheus add-on is enabled. The companion manifests PR therefore
merges only after this infrastructure PR is deployed. Microsoft documents the
Argo CD ServiceMonitor shape in [Collect Argo CD metrics](https://learn.microsoft.com/azure/azure-monitor/containers/prometheus-argo-cd-integration)
and the Istio namespace setting in [Collect Istio metrics](https://learn.microsoft.com/azure/azure-monitor/containers/prometheus-istio-integration).

## Dashboard and proof

The repository dashboard is
`observability/grafana/aks-platform-overview.json`. Bootstrap imports it into
the `MCP Platform` folder with UID `aks-platform-overview` and title `AKS
Platform Overview`. It has four sections: Collection health, Kubernetes, Argo
CD, and Istio. The hidden Prometheus data-source selector avoids committing a
Grafana data-source UID. The visible cluster selector discovers the actual
cluster label from the data source.

Status panels use colors only for factual states, such as a scrape target being
down or a pod being unready. CPU, memory, request rate, error ratio, and
duration charts have no warning or failure thresholds. The dashboard defaults
to the last six hours and refreshes each minute. Those are display defaults,
not retention or service commitments.

The verification workflow checks the Grafana folder and dashboard, the managed
Prometheus attachment, live Kubernetes, Argo CD, and Istio control-plane
queries, and the Argo CD-owned resources. It also records the cluster label it
observed. It does not generate traffic. Istio request-rate, error-ratio, and
duration queries can return no samples while still loading successfully.

The Prometheus API requires a Microsoft Entra token and `Monitoring Data
Reader` access to the Azure Monitor workspace. The workflow uses the workspace
query endpoint and the `/api/v1/query` API documented in [Query Prometheus
metrics using the API and PromQL](https://learn.microsoft.com/azure/azure-monitor/metrics/prometheus-api-promql).

## Boundaries

This work does not add application request, tool-call, token, dependency, or
latency metrics. It does not add alerts, action groups, paging, private
endpoints, Azure Monitor Private Link Scope, private DNS, management locks, or
synthetic traffic. Issue 18's per-tool deny audit remains unchanged.

Grafana and the Azure Monitor workspace remain provisioned while AKS is
stopped. They have their own lifecycle and may continue to incur charges. The
platform does not publish a monthly cost because it has not measured one. See
[docs/cost.md](cost.md) for the measurement procedure and
[docs/runbooks/observability-bootstrap.md](runbooks/observability-bootstrap.md)
for the operator sequence.
