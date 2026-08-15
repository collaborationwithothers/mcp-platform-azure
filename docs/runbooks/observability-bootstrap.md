# Runbook: Shared observability

This runbook creates and operates the persistent observability services. It
uses the `Shared observability` workflow in the `live-test` GitHub Environment.
The workflow owns Terraform apply and destroy. Do not run Terraform apply or
destroy from a local shell.

The core state contains logs and traces. The metrics state contains Prometheus
metrics and Grafana. Core is never a routine teardown target. Metrics teardown
deletes Prometheus history and any Grafana change that is not stored in this
repository.

## Before the first bootstrap

Create a stable resource group in the same region as `LIVE_TEST_LOCATION`. It
must not be an ephemeral S1/S2 resource group and must not have the
`expires-after` cleanup tag. The shared Terraform compositions look up this
resource group. They do not create or manage it.

For example, from a shell authenticated to the intended subscription:

```sh
az group create \
  --name rg-mcp-platform-observability \
  --location <live-test-location>
```

In the `live-test` GitHub Environment, set these variables:

| Name | Required | Value |
| --- | --- | --- |
| `SHARED_OBSERVABILITY_RESOURCE_GROUP` | Yes | The stable resource group name. |
| `GRAFANA_ADMIN_PRINCIPAL_IDS` | No | A Terraform JSON set of Microsoft Entra object IDs, for example `["<object-id>"]`. |
| `GRAFANA_VIEWER_PRINCIPAL_IDS` | No | A Terraform JSON set of Microsoft Entra object IDs. |

The object-ID variables are not secrets, but they must not be committed. Leave
them unset to create no human Grafana grants. The workflow grants its own OIDC
identity `Grafana Editor` on the Grafana workspace so it can import the
repository dashboard.

The existing `TF_STATE_STORAGE_ACCOUNT`, `TF_STATE_CONTAINER`, Azure OIDC, AKS
platform, and `LIVE_TEST_LOCATION` environment variables remain prerequisites.
Remove the retired
`TF_VAR_shared_observability_application_insights_id` environment variable after
the core state has been deployed and consumers have cut over.

## Bootstrap

1. In Actions, run `Shared observability` with `action=bootstrap` and type
   `bootstrap` in `confirm`.
2. Wait for the workflow to create or update core state first, metrics state
   second, and import `AKS Platform Overview` into Grafana's `MCP Platform`
   folder.
3. In Actions, run `Deploy AKS platform` with `action=bootstrap` and type
   `bootstrap` in `confirm`. That workflow is the only normal owner of the
   managed Prometheus attachment.
4. After the companion manifests PR has merged, run `Shared observability`
   with `action=verify`. It reads the live state only. It checks the dashboard,
   the add-on attachment, the Argo CD-owned scrape resources, and the required
   PromQL queries.

`verify` can report no Istio traffic samples. This is not a failure if the
query loads and the Istio control-plane and scrape-health checks pass. The
workflow creates no synthetic traffic.

## Exercise an unmerged companion revision and teardown metrics

Use this procedure only for the issue 124 live acceptance exercise. It is
destructive to metrics state.

1. Obtain the exact 40-character lowercase commit SHA from the companion
   manifests PR. Do not use a branch name.
2. Run `Shared observability` with `action=teardown`, type `teardown` in
   `confirm`, and pass the SHA as `companion_revision`.
3. The workflow temporarily points the root and observability child Argo CD
   Applications at that SHA. It disables root self-healing only during this
   exercise, so the child can use the unmerged revision. It waits for the
   ConfigMap and the three ServiceMonitors. It then checks Argo CD and Istio
   metrics through the Azure Monitor workspace query endpoint.
4. The workflow restores the root Application to `main`, re-enables root
   self-healing, and proves the restoration before it changes AKS or destroys
   metrics state. If restoration fails, it stops before teardown. Recover
   manually with:

   ```sh
   kubectl patch application mcp-platform-app-of-apps -n argocd \
     --type merge \
     -p '{"spec":{"source":{"targetRevision":"main"},"syncPolicy":{"automated":{"selfHeal":true}}}}'
   ```

5. The workflow plans AKS with `managed_prometheus_enabled=false`. It refuses
   a plan with unrelated changes. It applies the planned detachment, confirms
   the add-on is off, then destroys only `shared-observability-metrics`.

The workflow never destroys `shared-observability-core`. Do not use a direct
Azure CLI update to disable the add-on. That would leave Terraform state out of
sync with AKS.

## Recovery after metrics teardown

Run these actions in order:

1. `Shared observability`, `action=bootstrap`, confirmation `bootstrap`.
2. `Deploy AKS platform`, `action=bootstrap`, confirmation `bootstrap`.
3. `Shared observability`, `action=verify`.

The first action recreates the Azure Monitor workspace and Grafana and imports
the dashboard. The second reads the new metrics-state output and reattaches
managed Prometheus. The final action proves the recovered state.

## Operational boundaries

AKS idle stop and start do not destroy or reconfigure either shared state.
Grafana and the Azure Monitor workspace remain provisioned while AKS is
stopped, so their billing lifecycle continues. This project has not measured a
monthly amount.

The Log Analytics and Application Insights 5 GB daily caps are safeguards, not
budgets. A cap hit stops data collection for the rest of the day and leaves a
gap. There is no alert for it in this issue.

The public-demo profile keeps Grafana public and zone redundancy disabled.
Private monitoring access and zone redundancy are stronger production choices,
but they require network and cost decisions outside this issue. Microsoft
documents Grafana access options in [Secure Azure Managed
Grafana](https://learn.microsoft.com/azure/managed-grafana/secure-azure-managed-grafana)
and zone redundancy in [Enable zone redundancy](https://learn.microsoft.com/azure/managed-grafana/how-to-enable-zone-redundancy).
