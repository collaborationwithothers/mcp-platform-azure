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
| APIM MCP server ARM surface | Preview API version | Microsoft.ApiManagement/service/apis, apiType=mcp, API version 2025-09-01-preview. Re-confirmed 2026-07-12 against https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api, which also gives a working `azapi_resource` Terraform example (mirrored in infra/terraform/modules/apim-mcp-server/main.tf). | 2026-07-12 |
| APIM llm-content-safety for MCP tool calls | GA (Build 2026) | | 2026-07-08 |
| API Center data plane MCP registry | GA | no azurerm resource (provider issue #26200, re-confirmed still open 2026-07-12); azapi with 2024-06-01-preview API version (newest listed for services/workspaces/environments, and the only listed version for apiSources; a stable 2024-03-01 also exists for services/workspaces/environments but not for apiSources). Registry read-access mode is platform-determined (authenticated by default, anonymous requests 401) with NO azapi property in any published version; the module uses Data Reader RBAC for authenticated read, not an access-mode input. Anonymous is a portal-only opt-in, not used here. See the api-center-registry rows below and its README. | 2026-07-12 |
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
| azurerm provider features.storage.data_plane_available | false | infra/terraform/scenarios/s1-entra-mcp-server/versions.tf | mcp-function-host's storage account sets shared_access_key_enabled = false (managed-identity-only); the provider's default post-create data-plane poll authenticates with the account key and fails with KeyBasedAuthenticationNotPermitted. This flag skips that poll. Introduced in provider v4.9.0, well below the ~> 4.80 pin. Only safe because the resource uses neither queue_properties nor static_website (the flag's documented exception) | 2026-07-13 | https://github.com/hashicorp/terraform-provider-azurerm/blob/main/website/docs/guides/features-block.html.markdown |
| App setting WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES | Preview | infra/terraform/modules/mcp-function-host/main.tf (var.prm_scope) | Enables the backend protected resource metadata document; config format may change before GA | 2026-07-12 | https://learn.microsoft.com/azure/app-service/overview-authentication-authorization#how-it-works |
| Microsoft.Azure.Functions.Worker.Extensions.Mcp | 1.5.1 (stable/GA) | src/McpTools/McpTools.csproj | MCP tool triggers for the .NET isolated worker (ADR-002). Verified stable, not preview; requires Worker >= 2.1.0 and Worker.Sdk >= 2.0.2 | 2026-07-12 | https://learn.microsoft.com/azure/azure-functions/functions-bindings-mcp |
| Microsoft.Azure.Functions.Worker | 2.52.0 | src/McpTools/McpTools.csproj | Isolated worker runtime; latest stable, satisfies the extension floor >= 2.1.0 | 2026-07-12 | https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker |
| Microsoft.Azure.Functions.Worker.Sdk | 2.0.7 | src/McpTools/McpTools.csproj | Isolated worker build SDK; latest stable, satisfies the extension floor >= 2.0.2 | 2026-07-12 | https://www.nuget.org/packages/Microsoft.Azure.Functions.Worker.Sdk |
| ModelContextProtocol | 1.4.1 | src/McpTestClient/McpTestClient.csproj | Official MCP C# SDK for the hand-written test client; latest stable (2.0.0 line is preview). API confirmed against the sample at the v1.4.1 tag (McpClient.CreateAsync, HttpClientTransport) | 2026-07-12 | https://www.nuget.org/packages/ModelContextProtocol/1.4.1 |
| avm-res-apimanagement-service | 0.9.0 (exact) | infra/terraform/modules/apim-gateway/main.tf | Issue-3 AVM capability check (below): expresses Basic v2 via the plain pass-through `sku_name` string, no fallback needed | 2026-07-12 | https://registry.terraform.io/modules/Azure/avm-res-apimanagement-service/azurerm/0.9.0 |
| azurerm_api_management sku_name | BasicV2_1 (format "<tier>_<capacity>") | infra/terraform/modules/apim-gateway/variables.tf (sku_name default) | Public-demo tracer profile; tier name is "BasicV2" (no underscore before "V2"), confirmed against the azurerm 4.80.0 resource docs | 2026-07-12 | https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/api_management |
| Microsoft.ApiManagement/service/apis (MCP passthrough), .../apis/policies, .../products/apis | 2025-09-01-preview | infra/terraform/modules/apim-mcp-server/main.tf | Passthrough MCP server, its server-scope policy, and product bindings. No azurerm resource exists for any of these (confirmed 2026-07-12) | 2026-07-12 | https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api |
| mcpProperties.endpoints shape | JSON object keyed by endpoint name (e.g. `{"message": {"uriTemplate": "..."}}`), NOT the array-of-{name,uriTemplate} shape Microsoft Learn and the ARM template reference both document | infra/terraform/modules/apim-mcp-server/main.tf | UNVERIFIED against docs; inferred from a live 400 whose ARM error explicitly named the deserialization target as Dictionary&lt;string, McpEndpointContract&gt;, which requires a JSON object. Docs are likely stale for this preview API version. Re-confirm the exact map-value shape (does it keep other fields besides uriTemplate?) at the next live-test run | 2026-07-13 (error observed; docs not corrected) | https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api |
| Microsoft.ApiManagement/service/apis (type=mcp) backend wiring | EXPERIMENTAL/UNVERIFIED: a separate Microsoft.ApiManagement/service/backends resource (url, protocol=http), referenced from the api via properties.backendId = the backend's bare resource name | infra/terraform/modules/apim-mcp-server/main.tf (azapi_resource.mcp_backend, azapi_resource.mcp_server) | serviceUrl (the documented field per manage-mcp-servers-rest-api, the ARM template reference, and the actual 2025-09-01-preview openapi.json pulled from Azure/azure-rest-api-specs) is silently not honoured for type=mcp: a live PUT with serviceUrl set and no backendId returned 400 "Either BackendId or MCP tools must be set, but not both for MCP API." `backendId` appears in NONE of those three sources for the apis resource (the only backendId hits in the real spec are unrelated path parameters on the backends CRUD endpoints). The Backend resource shape (url, protocol) is verified against that spec's BackendContract/BackendBaseParameters; whether backendId on the api takes a bare name vs a full ARM id is not. Re-verify both at the next live-test run | 2026-07-14 (error observed; undocumented in Learn, ARM template reference, and the pinned-version OpenAPI spec) | https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api |
| Microsoft.ApiManagement/service/apis (root PRM API), .../apis/operations, .../apis/policies | 2025-09-01-preview | infra/terraform/modules/apim-gateway/main.tf | Hand-rolled gateway-root protected resource metadata API mounted at path = "", its GET operation, and its return-response policy. Lives in apim-gateway (one root per gateway) rather than apim-mcp-server. No azurerm resource exists (confirmed 2026-07-12) | 2026-07-12 | https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api |
| Microsoft.ApiManagement/service (data source read) | 2024-05-01 | infra/terraform/modules/apim-mcp-server/main.tf (data "azapi_resource" "apim") | Read-only lookup of the parent service's gatewayUrl to derive mcp_server_url/prm_url. A stable (non-preview) version azapi 2.10.0 recognizes; gatewayUrl is stable across versions. Also the API Providers version azurerm 4.80.0's own azurerm_api_management resource uses | 2026-07-12 | https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/api_management |
| azapi_resource schema_validation_enabled | false, on every 2025-09-01-preview resource above | infra/terraform/modules/apim-mcp-server/main.tf and infra/terraform/modules/apim-gateway/main.tf | azapi 2.10.0 (the latest release; this repo's pin) does not yet recognize 2025-09-01-preview in its embedded resource schema for these types (confirmed locally via `terraform validate`: its newest recognized version for `Microsoft.ApiManagement/service/apis` and sibling types is 2025-03-01-preview). 2025-09-01-preview is the documented API version per Microsoft Learn; ARM acceptance is proven at the live gate, not asserted here. Re-check whether a newer azapi release adds it at the next pin review | 2026-07-12 | https://registry.terraform.io/providers/azure/azapi/2.10.0 |
| Microsoft.ApiCenter/services, .../workspaces, .../workspaces/environments, .../workspaces/apiSources | 2024-06-01-preview | infra/terraform/modules/api-center-registry/main.tf | API Center service, single "default" workspace, the APIM environment, and the APIM auto-sync source. Newest listed API version for services/workspaces/environments, and the only listed version for apiSources; a stable 2024-03-01 also exists for services/workspaces/environments but not for apiSources. 2024-06-01-preview is used uniformly across all four types (newest everywhere, and the sole option for apiSources). No azurerm resource (issue #26200 still open). Unlike the APIM 2025-09-01-preview types, azapi 2.10.0 DOES recognize these in its embedded schema, so `terraform validate` passes with schema validation ON (no schema_validation_enabled override needed). | 2026-07-12 | https://learn.microsoft.com/azure/templates/microsoft.apicenter/2024-06-01-preview/services |
| API Management Service Reader Role (built-in role id) | 71522526-b88f-4d52-b57f-d31fc3546d0d | infra/terraform/modules/api-center-registry/main.tf (azapi_resource.apim_reader) | Assigned to the API Center system-assigned identity on the APIM scope so auto-sync can import APIs (per synchronize-api-management-apis). Built-in role id confirmed against the Azure built-in roles reference. | 2026-07-12 | https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/integration#api-management-service-reader-role |
| API Center registry data-plane read-access mode | Platform-determined; NOT ARM/azapi-encodable in ANY published Microsoft.ApiCenter API version | infra/terraform/modules/api-center-registry (README.md, main.tf) | The read-access mode (authenticated vs anonymous) for the data-plane MCP registry endpoint has no ARM property in any published Microsoft.ApiCenter version: 2023-07-01-preview, 2024-03-01, 2024-03-15-preview, 2024-06-01-preview (newest as of 2026-07-12). `services` exposes only `restore` and `identity`; no child type models portal/data-API settings. Default posture is authenticated (anonymous requests 401); the module exposes Data Reader RBAC (data_reader_principal_ids), NOT an access-mode input, so the gate poll authenticates. Anonymous is a portal-only opt-in (Consumption > Portal settings > Access tab), not used by this deployment; see docs/runbooks/registry-anonymous-access.md and docs/security.md. Re-check trigger: any newer Microsoft.ApiCenter API version ships. | 2026-07-12 | https://learn.microsoft.com/azure/api-center/set-up-api-center-portal#configure-access-to-the-api-center-portal |
| Azure API Center Data Reader Role (built-in role id) | c7244dfb-f447-457d-b2ba-3999044d1706 | infra/terraform/modules/api-center-registry/main.tf (azapi_resource.data_reader, for_each) | Granted on the API Center INSTANCE to each principal in data_reader_principal_ids (e.g. the ticket-5 poll's OIDC principal) so it can read the data-plane registry authenticated. Grants Microsoft.ApiCenter/services/*/read. Built-in role id independently verified twice (2026-07-12) against the Azure built-in roles reference. | 2026-07-12 | https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/integration#azure-api-center-data-reader |
| Microsoft.Authorization/roleAssignments | 2022-04-01 | infra/terraform/modules/api-center-registry/main.tf (apim_reader, data_reader) | Stable roleAssignments ARM version azapi 2.10.0 recognizes. Used for both the APIM Service Reader grant (on the APIM scope) and the API Center Data Reader grants (on the API Center instance). Deterministic assignment names via uuidv5(scope|roleDef|principal). | 2026-07-12 | https://learn.microsoft.com/azure/templates/microsoft.authorization/2022-04-01/roleassignments |
| Microsoft.ApiCenter/services/workspaces "default" auto-creation | Azure auto-provisions the "default" workspace as a side effect of creating the parent services resource | infra/terraform/modules/api-center-registry/main.tf (data.azapi_resource.workspace) | Live gate: a `resource "azapi_resource"` declaring this workspace always failed azapi's pre-create existence check ("Resource already exists") because a GET on it succeeds immediately after the service is created. Not stated in the ARM template reference; observed live only. Fixed by switching to a `data` source; the module no longer manages the workspace's title/description (unverified whether the auto-created instance accepts a later PUT/PATCH) | 2026-07-13 (observed live; not documented) | https://learn.microsoft.com/azure/api-center/set-up-api-center-arm-template |
| Terraform CLI | 1.15.8 | .terraform-version, CI setup-terraform, compositions required_version >= 1.15.8 | Single toolchain across dev boxes and CI; tfswitch auto-selects from the file; drift caused validate gaps in ticket 3/4 reviews | 2026-07-12terraform releases page |

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

### Issue-3 AVM capability check (avm-res-apimanagement-service 0.9.0)

Required by the spec (Terraform and state: "AVM risk is retired at the top of
each issue") before building apim-gateway against this pin.

**Result: Basic v2 is expressible. No fallback to raw azurerm needed.**

- `sku_name` on the AVM module is a plain pass-through `string` (no enum
  validation in the module itself), forwarded directly to the underlying
  `azurerm_api_management` resource.
- `azurerm_api_management`'s `sku_name` accepts `"<tier>_<capacity>"` where
  tier includes `BasicV2`, confirmed against the azurerm 4.80.0 resource
  docs (the pinned provider version).
- Microsoft Learn confirms Basic v2 (a v2-tier gateway) supports MCP server
  management features.
- The module's `resource` output (the full underlying
  `azurerm_api_management` resource) is used for the system-assigned
  identity's `principal_id`, since the module has no dedicated
  `identity_principal_id`-style output for the top-level service identity.

Full detail and doc citations: infra/terraform/modules/apim-gateway/README.md.

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
- 2026-07-12: ticket 3 (apim-gateway and apim-mcp-server modules) lands.
  New pins: avm-res-apimanagement-service 0.9.0 (issue-3 AVM check passed,
  no fallback), the BasicV2_1 sku_name default, and
  Microsoft.ApiManagement/service/apis (MCP passthrough) plus its
  policies/operations/product-binding sibling types at 2025-09-01-preview.
  Discovered during local `terraform validate` (not from docs): azapi
  2.10.0's embedded resource schema does not yet recognize
  2025-09-01-preview for these types, so every such resource sets
  `schema_validation_enabled = false`. 2025-09-01-preview is the documented
  API version; ARM acceptance is proven at the live gate, not asserted here.
  The root protected-resource-metadata (PRM) document
  (/.well-known/oauth-protected-resource) is hand-rolled via a
  root-mounted API and policy, not a native APIM feature -- Microsoft Learn
  documents no built-in mechanism for this as of 2026-07-12.
- 2026-07-12: governance review of ticket 3 (PR #16). Structural change: the
  root PRM API/operation/policy moved from apim-mcp-server into apim-gateway
  (the root well-known path is one-per-gateway, so the singleton belongs in
  the gateway layer whose cardinality it shares; apim-mcp-server can be
  instantiated more than once against one gateway). apim-gateway gained a
  singular `prm` input and a `prm_url` output; apim-mcp-server dropped its
  `prm` input and the root API but keeps the 401 challenge and its `prm_url`
  output. Finding-1 wording corrected (above): "ARM accepts 2025-09-01-preview"
  reworded to "documented API version; ARM acceptance proven at the live gate."
- 2026-07-12: ticket 4 (api-center-registry module) lands. New pins:
  Microsoft.ApiCenter/services + workspaces + environments + apiSources at
  2024-06-01-preview (re-verified at issue start; the research-time note of
  2024-06-01-preview held), and the built-in "API Management Service Reader
  Role" id for the auto-sync identity's role assignment. Unlike the APIM
  2025-09-01-preview types, azapi 2.10.0 recognizes these ApiCenter types in
  its embedded schema, so `terraform validate` passes with schema validation
  ON. Issue-start finding recorded (not from training data): the data-plane
  registry read-access mode (anonymous vs Entra) is a portal toggle (Consumption
  > Portal settings > Access tab) with NO azapi/ARM property -- the `services`
  resource exposes only `restore` and `identity`, and no ApiCenter child type
  models portal settings in the ARM template reference. The module records the
  intended mode on an input/output for the ticket-5 poll to match; the toggle is
  applied out of band. Auto-sync from APIM is wired as the production-correct
  mechanism; no explicit server registration (the labelled fallback) is used.
- 2026-07-12: governance review of ticket 4 (PR #21). Doc-accuracy corrections
  after independent re-verification via azure-docs-verifier: (a) the "stable
  2024-03-01 exists for services only, none for the child types" claim was
  wrong -- 2024-03-01 also exists for workspaces and environments; only
  apiSources has no non-preview/older version. Reworded above. (b) the
  read-access toggle was mislocated as "Consumption > Data API settings"; the
  anonymous-vs-Entra toggle is actually under Consumption > Portal settings >
  Access tab (Data API settings only enables the MCP/marketplace endpoints and
  API visibility). Corrected above and in the module README. (c) added a row
  for the Azure API Center Data Reader built-in role id
  (c7244dfb-f447-457d-b2ba-3999044d1706) cited in the README for the entra
  posture. The registry_endpoint_url path form carries a known Microsoft-doc
  inconsistency (the doc's format string includes /workspaces/, its own example
  omits it); ticket 5's poll must confirm the live form empirically, noted in
  the module. The "single default workspace must be declared explicitly" point
  is a product-behaviour claim not confirmable from the ARM template reference;
  softened to a re-verify-at-live-gate note in the module.
- 2026-07-12: ticket 4 design change (PR #21). Registry read access is
  platform-determined, not a module input. Confirmed via azure-docs-verifier and
  the ARM change-log summary that NO Microsoft.ApiCenter API version
  (2023-07-01-preview, 2024-03-01, 2024-03-15-preview, 2024-06-01-preview, the
  newest) exposes a read-access-mode property; 2024-06-01-preview is the newest
  version in existence for the whole provider. Default posture is authenticated
  (anonymous requests 401). So the `registry_read_access` input and
  `registry_read_access_mode` output were removed; the module instead grants the
  Azure API Center Data Reader role on the instance to a generalized
  `data_reader_principal_ids` list (the gate poll's OIDC principal), via azapi
  for_each roleAssignments@2022-04-01. Anonymous read is documented as a
  portal-only, Copilot-only opt-in this deployment does not use
  (docs/runbooks/registry-anonymous-access.md, docs/security.md). Deploying
  principal needs roleAssignments/write on the APIM and API Center instance
  scopes at the gate (docs/runbooks/live-test-gate.md). Note on the "anonymous
  requests 401" default: Microsoft Learn documents Entra ID as recommended and
  anonymous as an explicit opt-in, but not the verbatim 401-on-no-config
  mechanic; that specific is confirmed at the live gate, not asserted from a doc.