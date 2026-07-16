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
| Microsoft.ApiManagement/service/apis (type=mcp) backend wiring | CONFIRMED against a portal-created reference server on the live stamp (2026-07-16): a separate Microsoft.ApiManagement/service/backends resource (url = backend BASE host, protocol=http), referenced from the api via properties.backendId = the backend's bare resource name; properties.mcpProperties.endpoints = a MAP keyed by endpoint name, value { uriTemplate } (streamable = one endpoint, keyed "mcp"); NO properties.transportType (the stamp drops it), NO properties.serviceUrl | infra/terraform/modules/apim-mcp-server/main.tf (azapi_resource.mcp_backend, azapi_resource.mcp_server) | serviceUrl is rejected for type=mcp (live PUT 400 "Either BackendId or MCP tools must be set, but not both for MCP API."); the published 2025-09-01-preview swagger (serviceUrl + endpoints ARRAY + transportType) is AHEAD of the deployed stamp, which requires backendId + endpoints MAP and silently drops transportType (deserializer 400 on the array: "Cannot deserialize the current JSON array ... into type Dictionary<String, McpEndpointContract>"). The effective forward path is backend.url + endpoints[].uriTemplate (gateway trace, set-backend-service). Diffed field-by-field against a hand-created portal MCP server on the same APIM pointed at the same backend | 2026-07-16 (portal-oracle diff on the live stamp) | https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api |
| APIM (Basic v2) -> Functions backend TLS floor | Backend Function App must allow TLS 1.2 (site_config.minimum_tls_version = "1.2"). avm-res-web-site defaults the site to 1.3; a 1.3-only backend rejects the APIM backend hop with a TLS "ProtocolVersion" alert that APIM surfaces as HTTP 500 | infra/terraform/modules/mcp-function-host/main.tf (module.function_app site_config) | Root cause of the ticket-5 call-stage 500, invisible in every ARM GET and only visible in the APIM gateway trace's backend section. Setting the live app to 1.2 turned the passthrough 500 into a clean backend 401. APIM Basic v2 negotiates TLS 1.2 on the backend hop | 2026-07-16 (gateway trace + live confirmation) | https://learn.microsoft.com/azure/api-management/api-management-howto-manage-protocols-ciphers |
| Microsoft.ApiManagement/service/apis (root PRM API), .../apis/operations, .../apis/policies | 2025-09-01-preview | infra/terraform/modules/apim-gateway/main.tf | Hand-rolled gateway-root protected resource metadata API mounted at path = "", its GET operation, and its return-response policy. Lives in apim-gateway (one root per gateway) rather than apim-mcp-server. No azurerm resource exists (confirmed 2026-07-12) | 2026-07-12 | https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api |
| Microsoft.ApiManagement/service (data source read) | 2024-05-01 | infra/terraform/modules/apim-mcp-server/main.tf (data "azapi_resource" "apim") | Read-only lookup of the parent service's gatewayUrl to derive mcp_server_url/prm_url. A stable (non-preview) version azapi 2.10.0 recognizes; gatewayUrl is stable across versions. Also the API Providers version azurerm 4.80.0's own azurerm_api_management resource uses | 2026-07-12 | https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/api_management |
| azapi_resource schema_validation_enabled | false, on every 2025-09-01-preview resource above | infra/terraform/modules/apim-mcp-server/main.tf and infra/terraform/modules/apim-gateway/main.tf | azapi 2.10.0 (the latest release; this repo's pin) does not yet recognize 2025-09-01-preview in its embedded resource schema for these types (confirmed locally via `terraform validate`: its newest recognized version for `Microsoft.ApiManagement/service/apis` and sibling types is 2025-03-01-preview). 2025-09-01-preview is the documented API version per Microsoft Learn; ARM acceptance is proven at the live gate, not asserted here. Re-check whether a newer azapi release adds it at the next pin review | 2026-07-12 | https://registry.terraform.io/providers/azure/azapi/2.10.0 |
| Microsoft.ApiCenter/services, .../workspaces, .../workspaces/environments, .../workspaces/apiSources | 2024-06-01-preview | infra/terraform/modules/api-center-registry/main.tf | API Center service, single "default" workspace, the APIM environment, and the APIM auto-sync source. Newest listed API version for services/workspaces/environments, and the only listed version for apiSources; a stable 2024-03-01 also exists for services/workspaces/environments but not for apiSources. 2024-06-01-preview is used uniformly across all four types (newest everywhere, and the sole option for apiSources). No azurerm resource (issue #26200 still open). Unlike the APIM 2025-09-01-preview types, azapi 2.10.0 DOES recognize these in its embedded schema, so `terraform validate` passes with schema validation ON (no schema_validation_enabled override needed). | 2026-07-12 | https://learn.microsoft.com/azure/templates/microsoft.apicenter/2024-06-01-preview/services |
| API Management Service Reader Role (built-in role id) | 71522526-b88f-4d52-b57f-d31fc3546d0d | infra/terraform/modules/api-center-registry/main.tf (azapi_resource.apim_reader) | Assigned to the API Center system-assigned identity on the APIM scope so auto-sync can import APIs (per synchronize-api-management-apis). Built-in role id confirmed against the Azure built-in roles reference. | 2026-07-12 | https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/integration#api-management-service-reader-role |
| API Center registry data-plane read-access mode | Platform-determined; NOT ARM/azapi-encodable in ANY published Microsoft.ApiCenter API version | infra/terraform/modules/api-center-registry (README.md, main.tf) | The read-access mode (authenticated vs anonymous) for the data-plane MCP registry endpoint has no ARM property in any published Microsoft.ApiCenter version: 2023-07-01-preview, 2024-03-01, 2024-03-15-preview, 2024-06-01-preview (newest as of 2026-07-12). `services` exposes only `restore` and `identity`; no child type models portal/data-API settings. Default posture is authenticated (anonymous requests 401); the module exposes Data Reader RBAC (data_reader_principal_ids), NOT an access-mode input, so the gate poll authenticates. Anonymous is a portal-only opt-in (Consumption > Portal settings > Access tab), not used by this deployment; see docs/runbooks/registry-anonymous-access.md and docs/security.md. Re-check trigger: any newer Microsoft.ApiCenter API version ships. | 2026-07-12 | https://learn.microsoft.com/azure/api-center/set-up-api-center-portal#configure-access-to-the-api-center-portal |
| Azure API Center Data Reader Role (built-in role id) | c7244dfb-f447-457d-b2ba-3999044d1706 | infra/terraform/modules/api-center-registry/main.tf (azapi_resource.data_reader, for_each) | Granted on the API Center INSTANCE to each principal in data_reader_principal_ids (e.g. the ticket-5 poll's OIDC principal) so it can read the data-plane registry authenticated. Grants Microsoft.ApiCenter/services/*/read. Built-in role id independently verified twice (2026-07-12) against the Azure built-in roles reference. | 2026-07-12 | https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/integration#azure-api-center-data-reader |
| Microsoft.Authorization/roleAssignments | 2022-04-01 | infra/terraform/modules/api-center-registry/main.tf (apim_reader, data_reader) | Stable roleAssignments ARM version azapi 2.10.0 recognizes. Used for both the APIM Service Reader grant (on the APIM scope) and the API Center Data Reader grants (on the API Center instance). Deterministic assignment names via uuidv5(scope|roleDef|principal). | 2026-07-12 | https://learn.microsoft.com/azure/templates/microsoft.authorization/2022-04-01/roleassignments |
| Microsoft.ApiCenter/services/workspaces "default" auto-creation | Azure auto-provisions the "default" workspace as a side effect of creating the parent services resource | infra/terraform/modules/api-center-registry/main.tf (data.azapi_resource.workspace) | Live gate: a `resource "azapi_resource"` declaring this workspace always failed azapi's pre-create existence check ("Resource already exists") because a GET on it succeeds immediately after the service is created. Not stated in the ARM template reference; observed live only. Fixed by switching to a `data` source; the module no longer manages the workspace's title/description (unverified whether the auto-created instance accepts a later PUT/PATCH) | 2026-07-13 (observed live; not documented) | https://learn.microsoft.com/azure/api-center/set-up-api-center-arm-template |
| Microsoft.ApiCenter/deletedServices (purge NOT supported live) | 2024-06-01-preview | infra/terraform/modules/api-center-registry (README.md, main.tf, variables.tf), infra/terraform/scenarios/s2-apim-mcp-gateway/main.tf | API Center has genuine soft-delete: deleting the service (even via `terraform destroy`, or by deleting its resource group) leaves its GLOBAL name (leftmost label of `<name>.data.<region>.azure-apicenter.ms`) reserved by a subscription-scoped tombstone. A fixed-name live-test re-run hit 400 "name already taken" against a prior run's tombstone. Although `DeletedServices_Delete` IS present in the 2024-06-01-preview spec (RG-scoped `DELETE .../resourceGroups/{rg}/providers/Microsoft.ApiCenter/deletedServices/{name}`, plain name segment, no `locations/` segment - verified 2026-07-14 against spec + .NET SDK), the deployed resource provider REJECTS it live with `400 UnsupportedResourceOperation` ("the resource type 'deletedServices' does not support this operation"). So there is no working programmatic purge, and `properties.restore = true` cannot reach a tombstone stranded in a prior run's deleted RG. Resolution is a naming one, NOT soft-delete handling: the module removed all purge/restore logic and requires a globally-unique `name`; the s2 composition derives `${registry_name}-${substr(sha1(resource_group_name),0,8)}` so each ephemeral run (own RG `rg-...-<github.run_id>`) gets a fresh name that never collides. Also supersedes an earlier `count`-gated purge that failed at plan with "Invalid count argument". Re-check trigger: any newer Microsoft.ApiCenter API version, in case purge becomes supported. | 2026-07-14 | https://learn.microsoft.com/rest/api/resource-manager/apicenter/deleted-services/delete |
| Microsoft.ApiCenter/services/workspaces/apiSources targetEnvironmentId format | 2024-06-01-preview | infra/terraform/modules/api-center-registry/main.tf (azapi_resource.apim_source) | The published REST reference for ApiSources_CreateOrUpdate types `properties.targetEnvironmentId` as `arm-id` and its sample uses a FULL ARM resource id (verified 2026-07-14 against learn.microsoft.com/rest/api/resource-manager/apicenter/api-sources/create-or-update, 2024-06-01-preview). The DEPLOYED preview RP disagrees: at the s2 live gate (2026-07-14) it rejected a full ARM id with `400 "The 'targetEnvironmentId' is in an incorrect format. The correct format is: '/workspaces/{0}/environments/{1}'"` and requires the workspace-relative path `/workspaces/{workspace}/environments/{environment}` instead. Module now sends `/workspaces/${local.workspace_name}/environments/${azapi_resource.environment.name}` (e.g. /workspaces/default/environments/apim). This is a preview doc/service mismatch; we follow the live service since it is what deploys. Re-check trigger: any newer Microsoft.ApiCenter API version, or a docs correction to the apiSources sample. | 2026-07-14 (observed live; contradicts docs) | https://learn.microsoft.com/rest/api/resource-manager/apicenter/api-sources/create-or-update?view=rest-resource-manager-apicenter-2024-06-01-preview |
| Microsoft.ApiManagement/service soft-delete + azurerm features.api_management.recover_soft_deleted | soft-delete API 2024-05-01 (current-ga); azurerm ~> 4.80 | infra/terraform/scenarios/s2-apim-mcp-gateway/versions.tf (recover_soft_deleted = false), main.tf (local.apim_name_unique) | VERIFIED (learn.microsoft.com/azure/api-management/soft-delete, 2026-07-14): APIM soft-delete applies to ALL tiers incl. Basic v2 / Standard v2, with a tier-agnostic 48h retention; a soft-deleted GLOBAL name (leftmost label of `<name>.azure-api.net`) is reserved until purge/auto-purge; purge (`az apim deletedservice purge` / `DELETE .../locations/{loc}/deletedservices/{name}`) is supported tier-agnostic incl. v2; same-subscription name reuse after purge is allowed, cross-subscription reuse is blocked for several days even after purge (DNS anti-takeover). OBSERVED at the s2 live gate 2026-07-14: a fixed `apim_name` re-run, whose prior tombstone's original resource group had been deleted out of band, hit `400 ServiceUndeleteNotPossible` ("Unable to undelete service") and the create hung >1h before timeout; azurerm's DEFAULT `recover_soft_deleted = true` had attempted the undelete. UNVERIFIABLE (not on Learn; the error code itself is undocumented): the resource-group-deleted precondition behind ServiceUndeleteNotPossible - do NOT encode the mechanism as fact. Resolution mirrors the API Center naming fix above: derive a unique-per-deployment name `${apim_name}-${substr(sha1(resource_group_name),0,8)}` so no ephemeral run collides with a tombstone, and set `recover_soft_deleted = false` so a create never attempts an undelete and never hangs. Tombstone accumulation is a side effect of the API Center destroy failure (apiSources/environments rows above): that failure aborts `terraform destroy` before it purges APIM, and the `az group delete` backstop soft-deletes APIM WITHOUT purging. Re-check trigger: Microsoft documents ServiceUndeleteNotPossible or the RG precondition, or a newer azurerm changes the recover default. | 2026-07-14 (facts verified; ServiceUndeleteNotPossible observed live, undocumented) | https://learn.microsoft.com/azure/api-management/soft-delete |
| Terraform CLI | 1.15.8 | .terraform-version, CI setup-terraform, compositions required_version >= 1.15.8 | Single toolchain across dev boxes and CI; tfswitch auto-selects from the file; drift caused validate gaps in ticket 3/4 reviews | 2026-07-12terraform releases page |
| MCP Inspector (@modelcontextprotocol/inspector) | 0.22.0 | docs/demos/README.md (manual interactive-discovery walkthrough) | Interactive MCP client for the manual discovery walkthrough (the gate does not automate interactive discovery; spec: Testing Decisions). 0.22.0 is the current latest release (published 2026-06-04), confirmed against the npm registry 2026-07-15. Pinned + dated per spec story 28 so a stale tool version stays visible. The "verified once against the deployed tracer" run is recorded in docs/demos/README.md's last-run log at the first live deploy (not yet run). Re-check trigger: a newer Inspector release, or the first live-gate walkthrough. | 2026-07-15 | https://www.npmjs.com/package/@modelcontextprotocol/inspector/v/0.22.0 |
| APIM validate-azure-ad-token failed-validation httpcode | 401 (attribute default) | infra/terraform/modules/apim-mcp-server/policies/mcp-server.xml | The gate's wrong-audience negative test asserts a 401. failed-validation-httpcode defaults to 401; the policy validates tenant-id (issuer), audiences, and client-application-ids. Verified 2026-07-15 via azure-docs-verifier. | 2026-07-15 | https://learn.microsoft.com/azure/api-management/validate-azure-ad-token-policy |
| APIM RFC 9728 PRM / 401 WWW-Authenticate challenge | Hand-rolled policy, NOT a first-party APIM feature | infra/terraform/modules/apim-mcp-server/policies/mcp-server.xml, infra/terraform/modules/apim-gateway/policies/prm-well-known.xml | Re-confirmed 2026-07-15: Microsoft Learn's APIM "secure MCP servers" page documents no built-in 401+WWW-Authenticate+PRM implementation for APIM; it links out to the external samples this repo follows (blackchoey/remote-mcp-apim-oauth-prm, Azure-Samples AI-Gateway). The RFC 9728 document fields the gate asserts (resource, authorization_servers, bearer_methods_supported, scopes_supported) are per the RFC. So the gate's discovery assertions test this repo's own policies, not a platform guarantee. | 2026-07-15 | https://datatracker.ietf.org/doc/html/rfc9728 |
| APIM type=mcp WWW-Authenticate resource_metadata rewrite (undocumented) | The deployed type=mcp runtime REWRITES the challenge's resource_metadata to a PATH-SCOPED `<gateway>/<server_path>/.well-known/oauth-protected-resource`, DOWNSTREAM of the policy pipeline. Matches NO spec | infra/terraform/modules/apim-mcp-server/policies/mcp-server.xml (emits gateway ROOT), tests/integration/discovery-assertions.ps1 (check [1] asserts the observed value) | PROVEN by an APIM gateway trace on the live stamp (2026-07-16; stamp apim-mcp-tracer-42fa1c27; listDebugCredentials/listTrace, api-version 2023-05-01-preview; trace f07bae7f): the apim-mcp-server policy's set-header + return-response emit the gateway-ROOT PrmUrl and the trace shows that ROOT value "sent to the caller in full", yet the client receives the PATH-SCOPED value on the wire. The rewrite is therefore internal to the type=mcp pipeline, with NO policy hook to override it (Exit 2 of the issue-9 trace session; see docs/runbooks/live-test-gate.md). The shape matches NEITHER the MCP auth spec (root example) NOR RFC 9728 s3.1 (insert-before-path); azure-docs-verifier confirmed Learn documents no native APIM MCP challenge/PRM (2026-07-16). Consequence: the path-scoped URL does not resolve (the orders MCP API 401s it); this repo still serves the gateway-ROOT PRM document (200), and the discovery assertion asserts the OBSERVED path-scoped value ON PURPOSE so the gate DETECTS a future platform change. Real clients unaffected: McpTestClient completed a full initialize/list/call session (client-credentials, not the discovery dance); interactive discovery is confirmed separately in docs/demos. Do NOT encode the rewrite as a documented platform capability. Re-check trigger: any new APIM release (the rewrite may change or disappear). | 2026-07-16 (gateway trace on live stamp; undocumented) | https://learn.microsoft.com/azure/api-management/api-management-howto-api-inspector |
| Entra client-credentials token scope (gate token acquisition) | `<audience>/.default` (server app); wrong-audience negative test via `https://graph.microsoft.com/.default` | scripts/gate/invoke-and-assert.ps1, src/McpTestClient/Program.cs (MCP_ACCESS_TOKEN) | The gate mints its bearer token non-interactively via client credentials on the dedicated test app registration; scope `<audience>/.default` yields a token whose aud is the server app and whose roles are the granted app-role (application permission) claims. A deliberately wrong-audience token is minted with the Graph `.default` scope. Verified 2026-07-15 via azure-docs-verifier. | 2026-07-15 | https://learn.microsoft.com/entra/identity-platform/v2-oauth2-client-creds-grant-flow |
| API Center data-plane registry token audience/resource | Resource/audience `https://azure-apicenter.net` (documented data-plane OAuth2 scope `Data.Read.All`) | scripts/gate/invoke-and-assert.ps1 (registry poll) | The authenticated registry poll targets the data-plane audience `https://azure-apicenter.net` (`az account get-access-token --resource https://azure-apicenter.net`), the OIDC principal holding Azure API Center Data Reader. The RESOURCE is what the gate passes to `--resource`; the specific scope suffix is not passed by that command. The documented data-plane scope is `Data.Read.All` (the self-host API Center portal config example: `scopes: ["https://azure-apicenter.net/Data.Read.All"]`) -- corrected 2026-07-15 from an earlier `user_impersonation` note that did not match current Learn. Servers-list path form: the register-discover-mcp-server page is internally inconsistent -- its stated format string includes `/workspaces/default/` while its own adjacent example omits it; there is no separate REST reference for the MCP servers-list operation to arbitrate (the data-plane REST reference at 2024-02-01-preview lists Apis/Deployments/Versions/Environments, not a Servers/MCP group). The module emits the `/workspaces/default/v0.1/servers` form; the gate tries it first, falls back to the stripped form, and records which one served the list. Resource verified 2026-07-15 via azure-docs-verifier; scope from the self-host portal config; the live path form is to be confirmed at the first live gate (not yet run) and recorded then. Re-check trigger: a docs correction, or a newer data-plane api-version. | 2026-07-15 | https://learn.microsoft.com/azure/api-center/register-discover-mcp-server#configure-mcp-registry-metadata |
| hashicorp/time provider | ~> 0.14 (lock pins 0.14.0) | infra/terraform/modules/api-center-registry/versions.tf, infra/terraform/scenarios/s2-apim-mcp-gateway/versions.tf + .terraform.lock.hcl | Used only for the destroy-time settle (time_sleep.apisource_cascade_settle) that fixes the API Center teardown race (row below). No cloud calls, no credentials. Pinned patch-flexible; the pre-1.0 provider's time_sleep interface has been stable for years. | 2026-07-15 | https://registry.terraform.io/providers/hashicorp/time/0.14.0 |
| API Center apiSource -> environment teardown cascade | Deleting the apiSource CASCADE-deletes the environment on its own (~11s); handled with a time_sleep destroy_duration = 60s settle between the two deletes | infra/terraform/modules/api-center-registry/main.tf (time_sleep.apisource_cascade_settle) | OBSERVED at the s2 live gate 2026-07-15 (instrumented diagnostic, now removed): verdict CASCADE_AUTO, the environment returned 404 ~11 s after the apiSource delete. Microsoft Learn documents the ownership model (synchronize-api-management-apis#delete-an-integration: deleting the apiSource removes the synced APIs and the associated environment/deployments) but NOT the async settle timing, so the 11s figure is measured, not documented. Without a settle, terraform's own environment DELETE races the cascade and returns 400 "Cannot delete linked resource ... unlink the API source", aborting `terraform destroy` and stranding APIM/API Center soft-delete tombstones (the unique-name workarounds in the rows above exist because of this). The 60s settle is a margin over the observed 11s, not a measured minimum. Re-check trigger: the RP documents the cascade timing, or a newer Microsoft.ApiCenter api-version changes the ownership model. | 2026-07-15 (cascade observed live; timing undocumented) | https://learn.microsoft.com/azure/api-center/synchronize-api-management-apis |

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
- 2026-07-15: issue 9 slice 2 (harness plus docs) lands. Fills the live gate's
  "call" stage: McpTestClient session/tool assertions, the raw-HTTP discovery
  assertions (scripts + tests/integration/discovery-assertions.ps1), and the
  bounded registry poll (scripts/gate/invoke-and-assert.ps1), wired into
  .github/workflows/ephemeral-env.yml. New rows above (verified 2026-07-15 via
  azure-docs-verifier / the npm registry): the MCP Inspector 0.22.0 pin
  (verified as the current release; the against-tracer walkthrough is recorded
  at the first live deploy in docs/demos/README.md); validate-azure-ad-token's
  401 default; the RFC 9728 PRM/401 challenge is a hand-rolled policy, not a
  first-party APIM feature; the client-credentials `.default` scope for the
  gate's token acquisition; and the API Center data-plane token audience
  `https://azure-apicenter.net` with the known `/workspaces/` path
  inconsistency the gate resolves empirically. The tracer-bullet reasoning was
  recorded in docs/tradeoffs.md.
- 2026-07-15: API Center teardown race fixed. The instrumented diagnostic in
  ephemeral-env.yml returned verdict CASCADE_AUTO (the apiSource delete
  cascade-removes the environment on its own, settle ~11s), so the fix is a
  time_sleep destroy_duration = 60s settle between the apiSource and environment
  deletes (api-center-registry module). This lets terraform's environment DELETE
  either no-op on the already-cascaded 404 or run after the apiSource link is
  gone, instead of racing the cascade and returning 400 "unlink the API source".
  New pins: hashicorp/time ~> 0.14 (module + s2 composition + s2 lock). The
  now-conclusive teardown diagnostic (and its dedicated re-login) were removed
  from ephemeral-env.yml; the next live run validates the settle standalone
  (destroys remain if: always() with the az-group-delete backstop, so nothing
  leaks if the settle is imperfect).