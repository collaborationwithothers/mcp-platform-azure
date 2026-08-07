# Runbook: Observability bootstrap for v1 tracer

Out-of-band procedure for the Log Analytics workspace and workspace-based
Application Insights resource shared by the S1 and S2 compositions. These
resources are long-lived, provisioned out of band, and live in a stable resource
group distinct from the ephemeral per-run resource group so the live-test cleanup
sweep never deletes them. The resource remains the issue 18 audit sink for
per-tool deny events. Issue 75 also derives the shared Log Analytics workspace
ARM ID from it for resource-level diagnostics. This runbook must be executed
once before the first live run of `.github/workflows/ephemeral-env.yml` that
uses the renamed input. Creating resources in a separate, persistent resource
group requires Azure Contributor privilege on the target subscription.

The Application Insights resource ID produced by this runbook is not committed to
this repo. It is supplied to the live-test workflow as a GitHub Environment
variable on the `live-test` environment and explicitly named in
`.github/workflows/ephemeral-env.yml`'s `env:` block as
`TF_VAR_shared_observability_application_insights_id: ${{ vars.TF_VAR_shared_observability_application_insights_id }}`.
This follows the same pattern as `TF_STATE_STORAGE_ACCOUNT` and the other
explicitly wired environment variables in that block. No connection string,
instrumentation key, or other secret is committed or stored as a GitHub
Environment secret. The scenarios read `WorkspaceResourceId` from the ARM
resource at apply time. `apim-gateway` retains the issue 18 connection-string
lookup internally for its unchanged deny audit logger, where APIM authenticates
with its system-assigned managed identity.

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

This value becomes `TF_VAR_shared_observability_application_insights_id`. Do NOT
record the connection string or instrumentation key. S1 and S2 read the
workspace ARM ID from `WorkspaceResourceId` at apply time, while `apim-gateway`
keeps the issue 18 connection-string lookup internal to its audit logger. No
key-shaped value needs to be stored anywhere.

## 5. Add the resource id to the live-test GitHub Environment

1. Before the first issue 75 live test, in the GitHub repository go to
   **Settings > Environments > live-test**.
2. Under **Environment variables** (NOT secrets), create the renamed variable:
   - **Name**: `TF_VAR_shared_observability_application_insights_id`
   - **Value**: the ARM resource id from step 4.
3. Save. Note that `.github/workflows/ephemeral-env.yml` names every
   `TF_VAR_*` variable explicitly in its `env:` block -- they are NOT
   picked up automatically. The workflow must include an entry for this
   variable:
   ```yaml
   TF_VAR_shared_observability_application_insights_id: ${{ vars.TF_VAR_shared_observability_application_insights_id }}
   ```
   Adding the GitHub Environment variable is the prerequisite. It is available
   to both scenario applies and both destroys through the job-level environment.
4. After the renamed variable is in use and the cutover has completed, remove
   the pre-cutover Application Insights Environment variable. There is no
   compatibility alias.

The variable is NOT a secret: the ARM resource id is not sensitive (it is a
stable identifier, not a key or credential). Storing it as a variable (not a
secret) keeps the environment's secret count low and makes it auditable.

## Values this runbook produces, and where they are consumed

| Value | Consumed by |
|---|---|
| Application Insights ARM resource ID | `shared_observability_application_insights_id` in both S1 and S2, supplied as `TF_VAR_shared_observability_application_insights_id` on the `live-test` GitHub Environment; never committed |

Both scenarios use the Application Insights resource's `WorkspaceResourceId`
property as the required Log Analytics workspace ID for platform diagnostics.
The `apim-gateway` module still derives the connection string from this resource
at apply time, grants APIM's system-assigned managed identity the Monitoring
Metrics Publisher role on this resource, and creates the issue 18 APIM
Application Insights logger with managed-identity credential mode. No
instrumentation key, connection string, or other secret is needed as a GitHub
variable or secret; Terraform reads what it needs live from Azure.
