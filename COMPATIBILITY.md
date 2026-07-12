# COMPATIBILITY

This repo depends on Azure features that are preview or newly GA, and on ARM
API versions that are still -preview even where the feature is GA. This file
tracks what we depend on, what we have pinned, and when each claim was last
verified against Microsoft documentation.

Rules:
- Every azapi resource in /infra pins an explicit ARM API version and has a
  row here.
- Any PR that adds or changes a pin updates this file in the same PR.
- "Last verified" means a human or agent checked the linked doc on that date,
  not that the doc was published then.
- If CI or a live test breaks because a preview surface changed, the fix PR
  updates this table and notes the breakage under History.

## Feature status (seeded from blueprint research, verified 2026-07-08)

| Component | Status | Notes | Last verified |
|---|---|---|---|
| Azure Functions MCP extension (tool triggers) | GA (announced Nov 2025) | .NET isolated worker. Exact package pinned at ticket 2: Microsoft.Azure.Functions.Worker.Extensions.Mcp 1.5.1 (stable, published 2026-06-23). The earlier post-GA "-preview" signal was interim preview builds (e.g. 1.5.0-preview.1) published ahead of each stable release; the current latest is stable. See Pinned versions below. | 2026-07-12 |
| Functions MCP extension: resource triggers | GA | | 2026-07-08 |
| Functions MCP extension: prompt triggers, MCP Apps, one-click auth | Preview | not used in v1 | 2026-07-08 |
| Functions self-hosted MCP SDK servers (custom handlers) | Preview | stateless only; gated phase, not v1 | 2026-07-08 |
| APIM MCP servers (expose REST as MCP, passthrough) | GA (feature) | REST-export servers: tools only; not on Consumption tier; not in workspaces | 2026-07-08 |
| APIM MCP server ARM surface | Preview API version | Microsoft.ApiManagement/service/apis, apiType=mcp, API version 2025-09-01-preview at time of research | 2026-07-08 |
| APIM llm-content-safety for MCP tool calls | GA (Build 2026) | | 2026-07-08 |
| API Center data plane MCP registry | GA | no azurerm resource (provider issue #26200); azapi with 2024-06-01-preview API version at time of research | 2026-07-08 |
| MCP Enterprise-Managed Authorization (EMA) extension | Spec stable 2026-06-18 | Okta first spec-level IdP; native Entra ID spec-level support UNVERIFIED; not built in this repo, see ADR-006 | 2026-07-08 |

## Pinned versions

Populated as code lands. One row per pin.

| What | Pin | Where | Rationale | Last verified | Doc link |
|---|---|---|---|---|---|
| terraform required_version | >= 1.15.8, < 2.0.0 | infra/terraform/modules/mcp-function-host/versions.tf | Matches the spec's Terraform and state pin | 2026-07-11 | https://checkpoint-api.hashicorp.com/v1/check/terraform |
| azurerm provider | ~> 4.80 | infra/terraform/modules/mcp-function-host/versions.tf | Matches the spec's Terraform and state pin | 2026-07-11 | https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0 |
| azapi provider | ~> 2.10 | infra/terraform/modules/mcp-function-host/versions.tf | avm-res-web-site 0.22.0 depends on azapi ~> 2.9; pinned to the spec's floor | 2026-07-12 | https://registry.terraform.io/providers/azure/azapi/2.10.0 |
| avm-res-web-site | 0.22.0 (exact) | infra/terraform/modules/mcp-function-host/main.tf | Issue-1 AVM capability check (below): expresses both Flex Consumption and Entra built-in auth on this version, no fallback needed | 2026-07-12 | https://registry.terraform.io/modules/Azure/avm-res-web-site/azurerm/0.22.0 |
| azurerm_service_plan sku_name | FC1 (os_type = Linux) | infra/terraform/modules/mcp-function-host/main.tf | avm-res-web-site requires an externally-provisioned service plan; native azurerm support for FC1 shipped in provider v3.111.0, well before ~> 4.80 | 2026-07-12 | https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/service_plan |
| Flex Consumption functionAppConfig.runtime.version (dotnet-isolated, .NET 10) | "10.0" (major.minor, matching "8.0"/"9.0") | infra/terraform/modules/mcp-function-host/variables.tf (runtime.version default) | dotnet-isolated runtime versions use the major.minor form; the official Azure-Samples Flex Consumption bicep parameters pair dotnet-isolated with "10.0", and the Az.Functions runtimes list reports dotnet-isolated 10.0. A bare "10" appears in some sample allowed-value lists (it belongs to the node/java stacks), so reconfirm at the live gate with `az functionapp list-flexconsumption-runtimes`. | 2026-07-12 | https://github.com/Azure-Samples/azure-functions-flex-consumption-samples/blob/main/IaC/bicep/main.bicepparam |
| Flex Consumption instance_memory_in_mb | 2048 (valid set: 512, 2048, 4096) | infra/terraform/modules/mcp-function-host/variables.tf | Default sizing for the tracer's small demo footprint | 2026-07-12 | https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#instance-sizes |
| Flex Consumption maximum_instance_count | 40 (valid range: 1-1000) | infra/terraform/modules/mcp-function-host/variables.tf | Default sizing for the tracer's small demo footprint; 40 is a sizing choice, not a platform minimum | 2026-07-12 | https://learn.microsoft.com/azure/azure-functions/event-driven-scaling#flex-consumption-plan |
| azurerm_storage_container parent reference | storage_account_id (preferred over deprecated storage_account_name) | infra/terraform/modules/mcp-function-host/main.tf | Resource Manager API rather than Data Plane API; storage_account_name still works but is deprecated | 2026-07-11 | https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/storage_container |
| App setting WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES | Preview | infra/terraform/modules/mcp-function-host/main.tf (var.prm_scope) | Enables the backend protected resource metadata document; config format may change before GA | 2026-07-12 | https://learn.microsoft.com/azure/app-service/overview-authentication-authorization#how-it-works |
| Microsoft.Azure.Functions.Worker.Extensions.Mcp | 1.5.1 (stable/GA) | src/McpTools/McpTools.csproj | MCP tool triggers for the .NET isolated worker (ADR-002). Verified stable, not preview; requires Worker >= 2.1.0 and Worker.Sdk >= 2.0.2 | 2026-07-12 | https://learn.microsoft.com/azure/azure-functions/functions-bindings-mcp |
| Microsoft.Azure.Functions.Worker | 2.52.0 | src/McpTools/McpTools.csproj | Isolated worker runtime; latest stable, satisfies the extension floor >= 2.1.0 | 2026-07-12 | https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker |
| Microsoft.Azure.Functions.Worker.Sdk | 2.0.7 | src/McpTools/McpTools.csproj | Isolated worker build SDK; latest stable, satisfies the extension floor >= 2.0.2 | 2026-07-12 | https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Sdk |
| ModelContextProtocol | 1.4.1 | src/McpTestClient/McpTestClient.csproj | Official MCP C# SDK for the hand-written test client; latest stable (2.0.0 line is preview). API confirmed against the sample at the v1.4.1 tag (McpClient.CreateAsync, HttpClientTransport) | 2026-07-12 | https://www.nuget.org/packages/ModelContextProtocol/1.4.1 |

### Issue-1 AVM capability check (avm-res-web-site 0.22.0)

Required by the spec (Terraform and state: "AVM risk is retired at the top of
each issue") before building mcp-function-host against this pin.

**Result: both checks pass. No fallback to raw azurerm needed.**

- `function_app_uses_fc1` (Flex Consumption): confirmed as a top-level input
  on 0.22.0, with a documented `flex_consumption` example.
- `auth_settings_v2` (Entra built-in auth): confirmed as a top-level input
  mirroring the ARM auth API, including `unauthenticated_client_action`
  (accepts `Return401`) and an `identity_providers.azure_active_directory`
  block with `allowed_audiences` and `allowed_client_applications`.

Full detail and doc citations: infra/terraform/modules/mcp-function-host/README.md.

## History

- 2026-07-08: file seeded from blueprint research. No code pins exist yet.
- 2026-07-11: issue 5 (mcp-function-host module) lands. First code pins:
  terraform/azurerm/azapi versions, avm-res-web-site 0.22.0 (issue-1 AVM
  check passed, no fallback), azurerm_service_plan FC1, Flex Consumption
  sizing defaults, azurerm_storage_container's storage_account_id argument,
  and the preview WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES app setting.
- 2026-07-12: ticket 2 (McpTools server + McpTestClient skeleton) lands. First
  .NET package pins: Microsoft.Azure.Functions.Worker.Extensions.Mcp 1.5.1
  (issue-start verification confirmed it is stable/GA, resolving the earlier
  "-preview post-GA" signal in the feature-status table above), Worker 2.52.0,
  Worker.Sdk 2.0.7, and ModelContextProtocol 1.4.1 for the test client. Repo
  NuGet.config added pinning restore to nuget.org.
- 2026-07-12: governance-review corrections. The dotnet-isolated
  functionAppConfig.runtime.version pin was corrected from "10" to "10.0"
  after independent verification: the official Azure-Samples Flex Consumption
  bicep parameters pair dotnet-isolated with "10.0" and the Az.Functions
  runtimes list reports "10.0"; the earlier "bare major" reading was wrong
  (the bare forms in the allowed-value lists belong to the node/java stacks).
  Provider and resource doc links were pinned to versioned pages instead of
  /latest, and the max_instance_count and PRM rows were repointed at the
  pages that actually state their claims.