# s2-apim-mcp-gateway

Scenario composition for **S2**: the multi-tenant APIM MCP gateway, public-demo
profile. Instantiates
[`apim-gateway`](../../modules/apim-gateway) +
[`apim-mcp-server`](../../modules/apim-mcp-server) +
[`api-center-registry`](../../modules/api-center-registry), fronting the
backend `s1-entra-mcp-server` deploys, whose `mcp_backend_base_url` this
composition reads via `terraform_remote_state` (read-only, OIDC-authenticated,
same backend storage account as this composition's own state, a different
key). This is the S2 half of the
[v1 tracer bullet](../../../../docs/specs/v1-tracer-bullet.md).

## State

Remote state on an `azurerm` backend, OIDC-only (`use_oidc` and
`use_azuread_auth`, both required together; no storage access key, no client
secret). `backend.tf` is deliberately partial: `storage_account_name`,
`container_name`, and `key` are supplied via `-backend-config` by
`.github/workflows/ephemeral-env.yml` at real-init time, so no account name,
container, or state key is committed to this public repo. PR CI runs
`init -backend=false` only and never reaches the real backend.

State is isolated key-per-composition (this composition's own key, distinct
from `s1-entra-mcp-server`'s), per
[Terraform and state](../../../../docs/specs/v1-tracer-bullet.md#implementation-decisions).
Terraform workspaces are not used for isolation.

## Cross-composition wiring

`s1_remote_state` identifies `s1-entra-mcp-server`'s state (storage account,
container, key) so this composition's `data.terraform_remote_state.s1` can
read its `mcp_backend_base_url` output and pass it to `apim-mcp-server` as
`backend_service_url`. The live-test workflow supplies the same
storage-account/container values it used for `s1-entra-mcp-server`'s own
`-backend-config`, plus that composition's key.

## deployment_profile

`"public-demo"` (default and only v1-scope value) selects the `BasicV2_1`
APIM SKU via `apim-gateway`'s `sku_name` input, and the public endpoints
already exposed by the same modules (no private-networking wiring exists in
v1). A later profile (e.g. the v1.1 private-network variant) is an added map
entry, not a restructure.

## Global names and soft-delete

Both the API Management service and the API Center service have GLOBAL names
(the leftmost label of `<name>.azure-api.net` and
`<name>.data.<region>.azure-apicenter.ms` respectively) and both are
soft-deleted on delete, so their names stay reserved by a tombstone after
deletion. Reusing a fixed name across ephemeral runs collides with the prior
run's tombstone. This composition therefore does NOT use `apim_name` /
`registry_name` verbatim: it appends a short suffix derived from the resource
group name (`${name}-${substr(sha1(resource_group_name), 0, 8)}`,
`local.apim_name_unique` and `local.registry_name_unique`) so each ephemeral
run (own RG `rg-...-<github.run_id>`) gets a fresh global name and never
collides with a tombstone. A stable (non-ephemeral) resource group yields a
stable, deterministic name.

For APIM specifically, the azurerm provider default
`features.api_management.recover_soft_deleted = true` makes a create ATTEMPT to
undelete a same-named tombstone. When that tombstone's original resource group
was deleted out of band (the gate's `az group delete` backstop, which
soft-deletes APIM without purging it), the undelete fails and the create hangs
for over an hour before timing out (observed 2026-07-14: `400
ServiceUndeleteNotPossible`). `versions.tf` sets `recover_soft_deleted = false`
so a create never attempts an undelete; combined with the unique name, a create
always proceeds fresh. See COMPATIBILITY.md for the verified soft-delete facts
and what remains undocumented.

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
| `deployment_profile` | string | `"public-demo"` (default and only v1-scope value). |
| `s1_remote_state` | object | `{ storage_account_name, container_name, key }` identifying `s1-entra-mcp-server`'s state, for `terraform_remote_state`. |
| `apim_name` | string | BASE name of the API Management service; a per-deployment suffix is appended (see Global names and soft-delete). |
| `publisher_name` / `publisher_email` | string | API Management publisher identity. |
| `server_name` / `server_path` | string | MCP server resource name and path segment. |
| `entra_validation` | object | `{ tenant_id, audience, allowed_client_application_ids }`. References the out-of-band server resource app and test client app registrations; see `docs/runbooks/entra-app-registrations.md`. Also derives the gateway-root PRM document's `resource` and `authorization_server`. |
| `prm_scopes` | list(string) | Scopes surfaced in the PRM document's `scopes_supported`. |
| `registry_name` | string | BASE name of the API Center service; a per-deployment suffix is appended (see Global names and soft-delete). |
| `registry_environment` | object | Passed straight through to `api-center-registry`. |
| `registry_deployment` | object | Passed straight through to `api-center-registry`. Default matches the module's own default. |
| `data_reader_principal_ids` | list(string) | Principals granted Azure API Center Data Reader on the registry instance. The tracer passes the live-test OIDC principal that runs ticket 5's bounded poll. Empty by default. |

## Outputs

| Name | Description |
|---|---|
| `apim_id` | ARM resource ID of the API Management service. |
| `gateway_url` | Gateway URL of the API Management service. |
| `mcp_server_url` | Client-facing MCP endpoint. The McpTestClient assertions and the demo script target this URL. |
| `prm_url` | Gateway-root protected resource metadata URL. The no-token discovery assertion checks the challenge points here. |
| `registry_endpoint_url` | Data-plane MCP registry endpoint. The bounded registry poll asserts the tracer server appears here. |
| `api_center_name` | Resource name of the API Center service. |

## Out of scope (this ticket)

No `terraform apply`/`destroy` outside the gated live-test environment; no
products, subscriptions, quotas, 429 demo, or content safety; no OBO, no
downstream call, no second app registration; no private networking, no
observability workbook/alerts; no new runner group.
