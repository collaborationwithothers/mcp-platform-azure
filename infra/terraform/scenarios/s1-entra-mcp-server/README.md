# s1-entra-mcp-server

Scenario composition for **S1**: the Entra-secured .NET Functions MCP server
standing on its own, with no gateway in front of it. Instantiates
[`mcp-function-host`](../../modules/mcp-function-host) with Entra inputs
wired from variables (app ids by reference, never committed). This is the S1
half of the [v1 tracer bullet](../../../../docs/specs/v1-tracer-bullet.md);
`s2-apim-mcp-gateway` reads this composition's `mcp_backend_base_url` output
via `terraform_remote_state` to front it with the APIM gateway.

## State

Remote state on an `azurerm` backend, OIDC-only (`use_oidc` and
`use_azuread_auth`, both required together; no storage access key, no client
secret). `backend.tf` is deliberately partial: `storage_account_name`,
`container_name`, and `key` are supplied via `-backend-config` by
`.github/workflows/ephemeral-env.yml` at real-init time, so no account name,
container, or state key is committed to this public repo. PR CI runs
`init -backend=false` only and never reaches the real backend.

State is isolated key-per-composition (this composition's own key, distinct
from `s2-apim-mcp-gateway`'s), per
[Terraform and state](../../../../docs/specs/v1-tracer-bullet.md#implementation-decisions).
Terraform workspaces are not used for isolation.

## No deployment happens in this ticket

This composition is proven by `terraform fmt`, `init -backend=false`,
`validate`, `tflint`, and `checkov` only, same as every module. The live
apply-call-destroy proof is `.github/workflows/ephemeral-env.yml`, gated to
the `live-test` environment and never run from PR CI.

## Inputs

| Name | Type | Description |
|---|---|---|
| `resource_group_name` | string | Out-of-band resource group this composition deploys into. |
| `location` | string | Azure region. |
| `tags` | map(string) | Tags applied to every resource, expected to include the ephemeral expiry tag. |
| `name_prefix` | string | Prefix used to derive resource names. Passed straight through to `mcp-function-host`. |
| `deployment_profile` | string | `"public-demo"` (default and only v1-scope value). Selects the Flex Consumption sizing profile. |
| `storage_account_name` | string | Name of the Flex Consumption deployment storage account. |
| `create_storage_account` | bool | Whether this composition has the module create the storage account. Default `false`. |
| `entra_auth` | object | `{ tenant_id, server_app_client_id, allowed_audiences, unauthenticated_action = "Return401" }`. References the out-of-band server resource app registration; see `docs/runbooks/entra-app-registrations.md`. |
| `prm_scope` | string | e.g. `api://<server-app-id>/user_impersonation`. |
| `app_settings` | map(string) | Additional app settings, merged in alongside the module's own. Empty by default. |
| `downstream_app` | object | Issue 10: `{ client_id, api_scope }` of the out-of-band downstream Orders API app registration. Wired into the MCP server's `DownstreamOrdersApi__*` app settings. |
| `downstream_entra_auth` | object | Issue 10: same shape as `entra_auth`, for the downstream Orders API's own `mcp-function-host` instantiation. `allowed_audiences` is scoped to only the downstream app. |
| `downstream_storage_account_name` | string | Issue 10: deployment storage account name for the downstream instantiation. |
| `downstream_create_storage_account` | bool | Issue 10: whether to create `downstream_storage_account_name`. Default `false`. |

## Outputs

| Name | Description |
|---|---|
| `function_app_id` | ARM resource ID of the Function App. |
| `function_app_name` | Name of the Function App. |
| `default_hostname` | Default hostname. The shadow-key negative test in the live gate runs against this host directly, as well as the gateway. |
| `mcp_backend_base_url` | Base URL the `s2-apim-mcp-gateway` composition reads via `terraform_remote_state`. |
| `identity_principal_id` | Principal ID of the Function App's managed identity. Issue 10: federated onto the server app registration as a client-assertion credential source (`docs/runbooks/obo-app-registrations.md`), so the OBO exchange needs no stored secret. |
| `downstream_function_app_name` | Issue 10: name of the downstream Orders API's Function App. The live gate deploys `src/DownstreamOrdersApi` here. |
| `downstream_base_url` | Issue 10: base URL of the downstream Orders API, read by `tests/integration/obo-passthrough-negative.ps1`. |

## Out of scope (this ticket)

No `terraform apply`/`destroy` outside the gated live-test environment; no
APIM, API Center, or gateway wiring (that is `s2-apim-mcp-gateway`); no
private networking. Issue 10 adds the downstream Orders API instance and its
referenced app registration inputs, and the OBO exchange building block
(`McpTools.Downstream`), but does NOT wire OBO into `GetOrderStatus.Run`'s
live call path -- see that method's doc comment and ADR-006, "OBO exchange:
the inbound-token gap," for the verified platform gap that blocks it.
