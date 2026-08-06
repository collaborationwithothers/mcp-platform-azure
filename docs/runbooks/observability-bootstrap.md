# Runbook: Observability bootstrap for v1 tracer

Out-of-band procedure for the Log Analytics workspace and Application Insights
resource the s2 composition references as the audit sink for per-tool deny events
(issue 18): these resources are long-lived, provisioned out of band, and live in
a stable resource group distinct from the ephemeral per-run resource group so the
live-test cleanup sweep never deletes them. This runbook must be executed once,
before the first live run of `.github/workflows/ephemeral-env.yml` that deploys
the audit logger; creating resources in a separate, persistent resource group
requires Azure Contributor privilege on the target subscription.

The Application Insights resource id produced by this runbook is not committed to
this repo. It is supplied to the live-test workflow as a GitHub Environment
variable on the `live-test` environment, passed into Terraform as
`TF_VAR_audit_application_insights_id`, exactly like `TF_STATE_STORAGE_ACCOUNT`
is today (see `.github/workflows/ephemeral-env.yml`, `env:` block). No connection
string, instrumentation key, or other secret is committed or stored as a GitHub
Environment secret; the Terraform module reads the connection string at apply time
from the ARM resource, and auth to Application Insights uses APIM's system-assigned
managed identity (Monitoring Metrics Publisher role, granted by Terraform).

Steps below reference the Azure portal
(https://portal.azure.com) and the Azure CLI; both create the same resources.
Verified against Microsoft Learn on 2026-08-06 (citations per step).

## 1. Identify or create the stable resource group

Use a resource group that is NOT the ephemeral s2 composition resource group
(the one the live-test workflow creates per run as `rg-...-<github.run_id>` and
deletes at the end). The observability resources must NOT carry the expiry tag
(`expires-after`) used by the cleanup sweep, and must NOT live in the ephemeral
resource group that the cleanup sweep deletes.

A dedicated resource group named e.g. `rg-mcp-platform-observability` is
recommended. If you already have a stable non-ephemeral resource group (e.g. the
one holding the Terraform state storage account), you may reuse it instead.

### Using the Azure CLI

```sh
az group create \
  --name rg-mcp-platform-observability \
  --location <same-region-as-s2-deployment>
```

Do NOT add the expiry tag. ([Create a resource
group](https://learn.microsoft.com/azure/azure-resource-manager/management/manage-resource-groups-cli))

## 2. Create a Log Analytics workspace

Workspace-based Application Insights requires an underlying Log Analytics
workspace. ([Create a workspace-based Application Insights
resource](https://learn.microsoft.com/azure/azure-monitor/app/create-workspace-resource))

### Using the Azure portal

1. In the portal, search for **Log Analytics workspaces** and select
   **Create**.
2. Select the stable resource group from step 1.
3. Enter a name, e.g. `log-mcp-platform-observability`. Select the same
   region as the s2 composition deployment.
4. Leave all other settings at their defaults. Select **Review + Create**,
   then **Create**.

### Using the Azure CLI

```sh
az monitor log-analytics workspace create \
  --resource-group rg-mcp-platform-observability \
  --workspace-name log-mcp-platform-observability \
  --location <same-region-as-s2-deployment>
```

## 3. Create a workspace-based Application Insights resource

Workspace-based mode (backed by a Log Analytics workspace) is the current
recommended mode; the classic (non-workspace-based) Application Insights
resource type is being retired. ([Create a workspace-based Application Insights
resource](https://learn.microsoft.com/azure/azure-monitor/app/create-workspace-resource))

### Using the Azure portal

1. In the portal, search for **Application Insights** and select **Create**.
2. Select the stable resource group from step 1.
3. Enter a name, e.g. `appi-mcp-platform-audit`.
4. Select **Resource Mode: Workspace-based**.
5. Under **Log Analytics Workspace**, select the workspace created in step 2.
6. Select the same region as the s2 composition deployment.
7. Leave all other settings at their defaults. Select **Review + Create**,
   then **Create**.

### Using the Azure CLI

```sh
# Retrieve the Log Analytics workspace resource id
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group rg-mcp-platform-observability \
  --workspace-name log-mcp-platform-observability \
  --query id -o tsv)

az monitor app-insights component create \
  --app appi-mcp-platform-audit \
  --resource-group rg-mcp-platform-observability \
  --location <same-region-as-s2-deployment> \
  --workspace "$WORKSPACE_ID"
```

([az monitor app-insights component
create](https://learn.microsoft.com/cli/azure/monitor/app-insights/component#az-monitor-app-insights-component-create))

## 4. Record the resource id

From the Application Insights resource's **Overview** page in the portal, or
via the CLI:

```sh
az monitor app-insights component show \
  --app appi-mcp-platform-audit \
  --resource-group rg-mcp-platform-observability \
  --query id -o tsv
```

The output is an ARM resource id of the form:
```
/subscriptions/<subscription-id>/resourceGroups/rg-mcp-platform-observability/providers/microsoft.insights/components/appi-mcp-platform-audit
```

This value becomes `TF_VAR_audit_application_insights_id`. Do NOT record the
connection string or instrumentation key; the Terraform module reads the
connection string at apply time from the ARM resource using APIM's managed
identity, and no key-shaped value needs to be stored anywhere.

## 5. Add the resource id to the live-test GitHub Environment

1. In the GitHub repository, go to **Settings > Environments > live-test**.
2. Under **Environment variables** (NOT secrets), add a new variable:
   - **Name**: `TF_VAR_audit_application_insights_id`
   - **Value**: the ARM resource id from step 4.
3. Save. The workflow's `env:` block picks up all `TF_VAR_*` environment
   variables automatically (see `.github/workflows/ephemeral-env.yml`,
   `env:` block, where `TF_VAR_*` from the environment are listed alongside
   `TF_STATE_STORAGE_ACCOUNT`).

The variable is NOT a secret: the ARM resource id is not sensitive (it is a
stable identifier, not a key or credential). Storing it as a variable (not a
secret) keeps the environment's secret count low and makes it auditable.

## Values this runbook produces, and where they are consumed

| Value | Consumed by |
|---|---|
| Application Insights ARM resource id | `audit_application_insights_id` variable in the s2 composition, supplied as `TF_VAR_audit_application_insights_id` on the `live-test` GitHub Environment; never committed |

The Terraform module (`infra/terraform/modules/apim-gateway`) derives the
connection string from this resource id at apply time using an azapi data source,
grants APIM's system-assigned managed identity the Monitoring Metrics Publisher
role on this resource, and creates the APIM Application Insights logger with
managed-identity credential mode. No instrumentation key, connection string, or
other secret is needed as a GitHub variable or secret; the Terraform apply reads
what it needs live from Azure.
