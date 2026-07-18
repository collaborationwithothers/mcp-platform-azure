# mcp-function-host

Wraps [`Azure/avm-res-web-site/azurerm` 0.22.0](https://registry.terraform.io/modules/Azure/avm-res-web-site/azurerm/0.22.0)
to provision the .NET isolated-worker Azure Functions host for the MCP server
on Flex Consumption, with Entra built-in auth (Easy Auth) enabled and the MCP
extension's key-based access path closed. This is the S1 compute module in
the [v1 tracer bullet](../../../../docs/specs/v1-tracer-bullet.md).

No deployment happens in this ticket: the module is proven by `terraform fmt`,
`init -backend=false`, `validate`, `tflint`, and `checkov` only. The live
apply-call-destroy proof is the integration issue (issue 5 of the tracer
epic, per the spec's Delivery shape).

## Issue-1 AVM capability check (2026-07-11)

The spec requires this issue to open by verifying avm-res-web-site 0.22.0
expresses Flex Consumption (`function_app_uses_fc1`) and Entra built-in auth
(`auth_settings_v2`) before building against it, with a pre-declared
raw-`azurerm` fallback if either is not expressible.

**Outcome: both are expressible on 0.22.0. No fallback needed.**

Verified directly against the module's published documentation (fetched via
the Terraform MCP registry tools, module id
`Azure/avm-res-web-site/azurerm/0.22.0`):

- `function_app_uses_fc1` (bool) is a top-level input, with a documented
  `flex_consumption` example using `fc1_runtime_name = "dotnet-isolated"`,
  `instance_memory_in_mb`, and `maximum_instance_count`.
- `auth_settings_v2` is a top-level input whose shape mirrors the ARM
  `siteConfig` auth API, including `require_authentication`,
  `unauthenticated_client_action` (accepts `Return401`, confirmed against
  the `UnauthenticatedClientActionV2` enum and the Functions MCP tutorial),
  `excluded_paths`, and an `identity_providers.azure_active_directory` block
  with `registration.client_id`, `registration.open_id_issuer`, and
  `validation.allowed_audiences` / `jwt_claim_checks.allowed_client_applications`.
  The module's own `basic_auth` example demonstrates this identity provider
  shape end to end. This module builds the `open_id_issuer` as
  `https://login.microsoftonline.com/<tenant>/v2.0` (no trailing slash) from
  `entra_auth.tenant_id`, matching the Entra v2.0 token issuer claim.
- `service_plan_resource_id` is required: avm-res-web-site does not create
  the App Service Plan. There is no AVM module wrap for a standalone plan in
  this ticket's scope, so `main.tf` provisions it with the AzureRM-tier
  fallback (`azurerm_service_plan`, `sku_name = "FC1"`, `os_type = "Linux"`),
  per the spec's general fallback policy (supplementing an AVM call with a
  raw azurerm resource is not an ADR moment; dropping AVM from a whole module
  would be).
- `WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES` (surfaced by `var.prm_scope`) is a
  **preview** App Service capability as of 2026-07-11
  ([Microsoft Learn](https://learn.microsoft.com/azure/app-service/overview-authentication-authorization#protected-resource-metadata-preview)).
  Its configuration shape may change before GA; re-verify at the next pin
  review (see COMPATIBILITY.md).

See COMPATIBILITY.md for the full pin table and doc links, including the
`azurerm_service_plan` FC1 SKU claim, Flex Consumption instance-size and
scale-limit ranges, and the `dotnet-isolated` runtime version format.

## mcp_extension key posture

Acceptance criterion: module settings close the mcp_extension key path (no
auth-excluded MCP path).

This module sets `auth_settings_v2.require_authentication = true`,
`unauthenticated_client_action = "Return401"`, and `excluded_paths = []`
(explicitly empty, not merely defaulted), so Easy Auth intercepts every
request to the Functions runtime -- there is no path carved out for the MCP
extension's key-protected route. It also sets
`AzureFunctionsJobHost__extensions__mcp__system__webhookAuthorizationLevel =
Anonymous`, per the [Functions MCP tutorial's built-in-auth setup](https://learn.microsoft.com/azure/azure-functions/functions-mcp-tutorial#alternative-manually-configure-built-in-authentication),
so the key check does not sit as a second, dormant gate behind Easy Auth.

This is documented as an inference from two Microsoft Learn sources, not one
that states the interaction outright: the App Service auth architecture page
states every incoming request passes through the auth module before the
application handles it, and the Functions MCP tutorial's "disable key-based
auth" step is required when enabling built-in auth. No single Microsoft
document states "Easy Auth intercepts the key check" in those words.

**The enforced truth is behavioural, not this configuration.** Ticket 5's
negative test (present the mcp_extension system key, no Entra token, assert
401 against both the gateway and the backend host directly) is what proves
the shadow path is closed, per the spec (Compute and the tool (S1)).

## Storage authentication

The Flex Consumption storage account authenticates via a dedicated
user-assigned managed identity, rather than an account key. Both the
deployment package path (`storage_uses_managed_identity = true`,
`storage_authentication_type = "UserAssignedIdentity"`,
`storage_user_assigned_identity_id`) and the runtime `AzureWebJobsStorage`
path (`AzureWebJobsStorage__credential=managedidentity` + `__clientId`) use
that same identity, which holds a `Storage Blob Data Owner` role assignment on
the account. The system-assigned identity is enabled but is no longer used for
storage. This matches the AVM avm-res-web-site Flex example, which uses a
user-assigned identity for deployment storage; the earlier system-assigned
configuration failed the live gate persistently with
`MSITokenUnavailableException ... 400` on the Kudu one-deploy path.
`Storage Blob Data Contributor` is the Learn-documented deployment-storage
minimum; `Storage Blob Data Owner` is a superset that also covers the runtime
host's `AzureWebJobsStorage` operations. This avoids a storage secret in app
settings or state, consistent with the platform's no-access-keys posture for
the Terraform backend. Since nothing in this module issues or needs an account key, the
storage account this module creates also sets
`shared_access_key_enabled = false` and `allow_nested_items_to_be_public =
false`, and configures blob soft-delete and a SAS expiration policy as
dormant safety nets (checkov CKV2_AZURE_40, CKV2_AZURE_47, CKV2_AZURE_38,
CKV2_AZURE_41).

**Caveat, not yet live-tested:** Microsoft's Flex Consumption migration guide
notes that using `azurerm` with managed-identity storage auth on Flex
Consumption may currently require an explicit
`AzureWebJobsStorage = ""` app setting as a workaround
([source](https://learn.microsoft.com/azure/azure-functions/migration/migrate-plan-consumption-to-flex#post-migration-tasks)),
tracked against an open `terraform-provider-azurerm` pull request at the time
of writing. This module does not add that workaround: its exact shape is
unverified, and adding an unverified workaround would be guessing. The live
apply-call-destroy gate (the tracer's integration issue) is where this
gets proven or, if it fails, where the workaround is added with the PR link
to the fix.

## checkov skips (repo-wide, .checkov.yaml)

checkov 3.3.8's CKV2_* graph checks are not suppressible with an inline
resource annotation (verified locally: an inline skip had no effect on
these checks). Everything skipped is documented, with its reason, in
`.checkov.yaml` at the repo root: CMK encryption and blob logging need
Key Vault/observability wiring that are v1.1/v1.2, not v1; a storage
private endpoint is the v1.1 private-network module's job; zone redundancy
and a minimum-instance floor are HA/DR posture the public-demo tracer does
not need; and the Terraform-module-source commit-hash check does not fit a
Terraform Registry source, where this repo's own convention is exact
version pinning instead (see COMPATIBILITY.md).

## Inputs

| Name | Type | Description |
|---|---|---|
| `name_prefix` | string | Prefix used to derive names for resources this module owns. |
| `location` | string | Azure region. |
| `resource_group_name` | string | Name of the (out-of-band) resource group. |
| `tags` | map(string) | Tags applied to every resource, expected to include the ephemeral expiry tag. |
| `runtime` | object | `{ stack = "dotnet-isolated", version = "10.0" }` by default. `version` is passed straight to `functionAppConfig.runtime.version`; dotnet-isolated uses the major.minor form (`8.0`, `9.0`, `10.0`). See COMPATIBILITY.md. |
| `flex_consumption` | object | `{ instance_memory_mb = 2048, maximum_instance_count = 40 }` by default. |
| `storage_account_name` | string | Name of the deployment storage account (existing, or to create). |
| `create_storage_account` | bool | Whether this module creates `storage_account_name`. Default `false` (expects an existing, out-of-band account). |
| `entra_auth` | object | `{ tenant_id, server_app_client_id, allowed_audiences, unauthenticated_action = "Return401" }`. |
| `prm_scope` | string | e.g. `api://<server-app-id>/user_impersonation`. Surfaced via `WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES`. |
| `app_settings` | map(string) | Additional app settings, merged in alongside the module's own. |

## Outputs

| Name | Description |
|---|---|
| `function_app_id` | ARM resource ID of the Function App. |
| `function_app_name` | Name of the Function App. |
| `default_hostname` | Default hostname (e.g. `<name>.azurewebsites.net`). |
| `mcp_backend_base_url` | Base URL the apim-mcp-server module points `serviceUrl` at. The exact MCP endpoint path is confirmed in ticket 3, not hard-coded here. |
| `identity_principal_id` | Principal ID of the Function App's system-assigned managed identity. Unused in the tracer; present for the OBO issue. |

## Out of scope (this ticket)

No `terraform apply`/`destroy`; no APIM, API Center, scenario composition, or
backend config; no app registration creation (referenced by id only); no
private networking, no observability wiring beyond what Flex Consumption
strictly requires (no Application Insights is wired -- `avm-res-web-site`
leaves it optional and this module does not set it).
