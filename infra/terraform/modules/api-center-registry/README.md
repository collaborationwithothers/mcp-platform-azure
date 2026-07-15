# api-center-registry

Hand-authored `azapi` module that provisions Azure API Center as the discovery
registry of the [v1 tracer bullet](../../../../docs/specs/v1-tracer-bullet.md)
(scenario S3). It creates the API Center service, its single `default`
workspace, one environment, and an API Management **auto-sync** source so the
MCP server fronted by `apim-gateway`/`apim-mcp-server` appears in the inventory
automatically. It derives the data-plane registry endpoint URL that the
integration issue's bounded poll asserts against.

No deployment happens in this ticket: the module is proven by `terraform fmt`,
`init -backend=false`, `validate`, `tflint`, and `checkov` only. The live
apply-call-destroy proof (including that the synced server actually appears at
the registry endpoint) is the integration issue (issue 5 of the tracer epic).

## Verified facts (2026-07-12)

Verified via the `azure-docs-verifier` subagent and direct Microsoft Learn
fetches, not recalled from training data:

- API Center has **no native azurerm resource**; azapi is the only Terraform
  path. Provider feature request
  [hashicorp/terraform-provider-azurerm#26200](https://github.com/hashicorp/terraform-provider-azurerm/issues/26200)
  is still open.
- All resources are pinned to ARM API version **2024-06-01-preview**. This is
  the newest version in existence for the entire `Microsoft.ApiCenter` provider
  (the provider's full version set is `2023-07-01-preview`, `2024-03-01`,
  `2024-03-15-preview`, `2024-06-01-preview` per the change-log summary,
  re-confirmed 2026-07-12; there is no later preview). It is the newest for
  `services`/`workspaces`/`environments` and the only version for `apiSources`
  (which was introduced in this version). A stable `2024-03-01` exists for
  `services`, `workspaces`, and `environments` but not for `apiSources`; the
  module pins `2024-06-01-preview` uniformly.
  [Microsoft.ApiCenter change log](https://learn.microsoft.com/azure/templates/microsoft.apicenter/change-log/summary),
  [Microsoft.ApiCenter/services](https://learn.microsoft.com/azure/templates/microsoft.apicenter/2024-06-01-preview/services),
  [services/workspaces](https://learn.microsoft.com/azure/templates/microsoft.apicenter/2024-06-01-preview/services/workspaces),
  [services/workspaces/environments](https://learn.microsoft.com/azure/templates/microsoft.apicenter/2024-06-01-preview/services/workspaces/environments),
  [services/workspaces/apiSources](https://learn.microsoft.com/azure/templates/microsoft.apicenter/2024-06-01-preview/services/workspaces/apisources).
- API Center supports a single workspace named `default`, which the data-plane
  registry path (`/workspaces/default/...`) depends on. **Confirmed at the live
  gate (2026-07-13): Azure auto-provisions this workspace as a side effect of
  creating the `services` resource.** A `resource "azapi_resource"` declaring
  it explicitly always fails azapi's own pre-create existence check with
  "Resource already exists" (the ARM template reference does not document this
  create-time behaviour; it was only observed live). The module therefore reads
  it via a `data "azapi_resource"` and never manages its title/description;
  whether the auto-created instance's properties accept a later PUT/PATCH is
  unverified.
  [Set up API Center with an ARM template](https://learn.microsoft.com/azure/api-center/set-up-api-center-arm-template).
- **API Center has genuine soft-delete, and this module does NOT try to clear
  it - the caller must supply a unique name instead.** Deleting the service
  (directly, via `terraform destroy`, or by deleting its resource group) does
  not release its name; a later create with the same name 400s with "The name
  ... is already taken" (confirmed at the live gate, 2026-07-13/14). Because
  `var.name` is also the leftmost label of a GLOBAL data-plane DNS name
  (`https://<name>.data.<region>.azure-apicenter.ms`), that reservation is
  subscription-scoped and survives resource-group deletion. Two in-module fixes
  were tried and disproven live, so neither is used:
  - `properties.restore = true` on create only works when a tombstone exists;
    with none it 400s "the service does not exist or may have been permanently
    deleted," and it cannot reach a tombstone stranded in a prior run's already
    deleted resource group.
  - Purging the tombstone with `azapi_resource_action` (`method = "DELETE"`)
    against `.../resourceGroups/{rg}/providers/Microsoft.ApiCenter/deletedServices/{name}`
    is rejected live with `400 UnsupportedResourceOperation` ("the resource
    type 'deletedServices' does not support this operation"), even though
    `DeletedServices_Delete` is present in the `2024-06-01-preview` spec pulled
    from `Azure/azure-rest-api-specs`. (An earlier variant of this that gated
    the purge's `count` on a `data.azapi_resource_list` output separately
    failed at plan with "Invalid count argument," since a resource count cannot
    depend on data Terraform resolves only after apply.)

  The resolution is a naming one: the caller passes a name that is unique per
  deployment instance. The **s2 composition** derives it as
  `${var.registry_name}-${substr(sha1(var.resource_group_name), 0, 8)}`; since
  the ephemeral gate gives each run its own resource group
  (`rg-...-<github.run_id>`), every run gets a fresh global name and no
  tombstone ever collides, so no `restore`/purge is needed. A stable
  (non-ephemeral) resource group yields a stable, deterministic name.
  [Deleted Services - Delete](https://learn.microsoft.com/rest/api/resource-manager/apicenter/deleted-services/delete).
- The data-plane MCP registry endpoint has the form
  `https://<name>.data.<region>.azure-apicenter.ms/workspaces/default/v0.1/servers`.
  Known Microsoft-doc inconsistency (2026-07-12): the page's stated format
  string includes the `workspaces/` segment (matching the spec and this module),
  but the page's own worked example omits it
  (`.../default/v0.1/servers`). The module and spec use the `workspaces/` form;
  ticket 5's bounded poll must confirm the live form empirically before relying
  on it. Also re-verify the `<region>` slug (see below).
  [Register and discover MCP servers](https://learn.microsoft.com/azure/api-center/register-discover-mcp-server#configure-mcp-registry-metadata).
- APIM **auto-sync** keeps the inventory current (production-correct): the
  `apiSources` resource points at the APIM instance id and the servers sync in.
  [Synchronize APIs from an API Management instance](https://learn.microsoft.com/azure/api-center/synchronize-api-management-apis).
- Auto-sync requires the API Center managed identity to hold the **API
  Management Service Reader** role on the APIM instance (built-in role id
  `71522526-b88f-4d52-b57f-d31fc3546d0d`).
  [Synchronize APIs from an API Management instance](https://learn.microsoft.com/azure/api-center/synchronize-api-management-apis#enable-a-managed-identity-in-your-api-center),
  [Azure built-in roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#integration).
- **Teardown-ordering race, diagnosed and fixed (issue 9).** At the live gate,
  `terraform destroy` deletes the `apiSources` integration and then the
  `environments/apim` resource as two separate DELETE calls (dependency order).
  The environment DELETE used to 400 with "Cannot delete linked resource. To
  remove this resource please unlink the API source." Microsoft Learn confirms
  the ownership model: deleting the `apiSources` integration is the single action
  that removes the synced APIs AND the associated environment and deployments, so
  the environment is not independently deletable while the source is linked. The
  docs do NOT state whether that cascade is synchronous or eventually consistent.
  An instrumented diagnostic at the live gate (2026-07-15, since removed)
  measured it: verdict **CASCADE_AUTO** -- deleting the `apiSources` integration
  removes the environment on its own, and the environment returned 404 about 11 s
  later. So the failure is a settle-race, not a hard block. The fix is
  `time_sleep.apisource_cascade_settle` (in `main.tf`): `apim_source` depends on
  it and it depends on `environment`, so the destroy order becomes
  `apim_source -> (wait destroy_duration = 60s) -> environment`. By the time
  terraform deletes the environment, the cascade has already removed it (the
  DELETE no-ops on the 404) or the link is gone (a plain delete, no 400). The 60s
  value is a margin over the observed 11s settle, not a measured minimum; it is
  recorded in COMPATIBILITY.md as an observed-not-documented figure.
  [Synchronize APIs from an API Management instance - Delete an integration](https://learn.microsoft.com/azure/api-center/synchronize-api-management-apis#delete-an-integration).

## Auto-sync is the production target; explicit registration is a fallback only

This module wires **auto-sync from APIM** as the headline mechanism: MCP servers
managed in API Management populate the registry automatically, the way a
production inventory maintains itself. The module deliberately does **not**
create an MCP server entry explicitly.

Explicit `azapi` registration of a server (via
`Microsoft.ApiCenter/services/workspaces/apis`) is retained only as a labelled
**demo-determinism fallback**, to be added by the integration issue **if and
only if** the bounded poll proves the asynchronous sync too flaky inside a
short-lived deployment. If that fallback is ever used, it is the compromise, not
the target, and must be documented as such. It is out of scope here.

## Registry read access

**Read access is platform-determined, not a module input.** The data-plane MCP
registry endpoint's read-access mode (authenticated vs anonymous) is **not
controllable through the `Microsoft.ApiCenter` azapi/ARM surface in any published
API version** as of 2026-07-12. This was checked across the provider's entire
version set (`2023-07-01-preview`, `2024-03-01`, `2024-03-15-preview`,
`2024-06-01-preview`, the newest in existence): `Microsoft.ApiCenter/services`
exposes only `restore` and `identity`, and no ApiCenter child type models
portal/data-API settings. A newer preview does not front the toggle either.

**The default behaviour is authenticated: anonymous requests 401.** Callers
inside the Entra trust boundary read the registry with a token whose principal
holds the **Azure API Center Data Reader** role
(`c7244dfb-f447-457d-b2ba-3999044d1706`), scoped to the instance. This module
grants that role to the principals in `data_reader_principal_ids` (the tracer
passes the OIDC principal that runs ticket 5's bounded poll), so the poll
authenticates rather than relying on any access-mode toggle. (Microsoft Learn
documents Entra ID as the recommended access method and anonymous as an explicit
opt-in; the precise unauthenticated-response code is confirmed at the live gate,
not asserted from a Learn page.)

**Anonymous read is a portal-only opt-in this deployment does not use.** The
"Allow anonymous access" toggle exists only in the Azure portal (Consumption >
Portal settings > Access tab); there is no IaC surface for it. Its cost is
public enumerability of registered server and tool metadata. This deployment
keeps the authenticated default. The one known consumer that needs anonymous is
GitHub Copilot's registry integration; the optional, Copilot-only enablement
steps live in `docs/runbooks/registry-anonymous-access.md` and are not executed
here. Registry security posture is in `docs/security.md`.
[Set up the API Center portal](https://learn.microsoft.com/azure/api-center/set-up-api-center-portal#configure-access-to-the-api-center-portal),
[Discover APIs with the Azure API Center MCP server](https://learn.microsoft.com/azure/api-center/discover-catalog-mcp-server).

## Inputs

| Name | Type | Description |
|---|---|---|
| `name` | string | API Center service name (3-90 chars, letters/digits/hyphens). Also the leftmost registry hostname label. |
| `location` | string | Azure region. Normalized (lowercase, spaces removed) for the registry hostname region segment. |
| `resource_group_name` | string | Resource group for the service; assumed in the same subscription as `apim_source_id`. |
| `tags` | map(string) | Tags on the service (tracked resource). Default `{}`. |
| `apim_source_id` | string | Full ARM id of the APIM instance to auto-sync from. |
| `environment` | object | `{ title, kind = "development", server_type = "Azure API Management", management_portal_uri = [] }`. The environment the remote MCP server is associated with. |
| `deployment` | object | `{ import_specification = "always", target_lifecycle_stage = "production" }`. Auto-sync metadata for the synced servers. |
| `data_reader_principal_ids` | list(string) | Object ids granted **Azure API Center Data Reader** on the instance for authenticated data-plane read (e.g. the poll's OIDC principal). Default `[]` grants nothing. See Registry read access. |
| `assign_apim_reader_role` | bool | Whether to assign the service identity the API Management Service Reader role on `apim_source_id`. Default `true`. |

## Outputs

| Name | Description |
|---|---|
| `api_center_name` | Resource name of the API Center service. |
| `api_center_id` | ARM resource ID of the service. |
| `registry_endpoint_url` | Data-plane registry endpoint, `.../workspaces/default/v0.1/servers`. |
| `workspace_name` | Always `"default"`. |
| `environment_id` | ARM id of the environment the synced server is associated with. |
| `api_source_id` | ARM id of the APIM auto-sync source. |
| `identity_principal_id` | Principal id of the service's system-assigned identity. |

## Live-gate prerequisites (integration issue, not this ticket)

- Both role assignments this module creates need the deploying principal to hold
  `Microsoft.Authorization/roleAssignments/write` (for example **User Access
  Administrator** or **Owner**) at the target scope: the APIM instance (for
  `assign_apim_reader_role`) and this API Center instance (for
  `data_reader_principal_ids`). Provision that on the OIDC/bootstrap principal
  before the gate rather than discovering it there; see
  `docs/runbooks/live-test-gate.md`. Set `assign_apim_reader_role = false` (or
  pass `data_reader_principal_ids = []`) if the composition grants those roles
  out of band, and wire `identity_principal_id` to the APIM assignment instead.
- Read access stays at the authenticated default; nothing to apply out of band
  for the poll beyond the Data Reader grant above. Anonymous access is not used
  (portal-only opt-in, `docs/runbooks/registry-anonymous-access.md`).
- Re-verify the derived `registry_endpoint_url` region slug for any region
  whose data-plane hostname is not simply its lowercased name.

## Out of scope (this ticket)

No `terraform apply`/`destroy`; no bounded-poll assertion script (that is the
integration issue); no explicit `azapi` server registration as the primary
mechanism (auto-sync is primary; explicit registration is a labelled fallback
only); no API Center portal publishing flow; no Foundry tool-catalog wiring;
no scenario composition wiring.
