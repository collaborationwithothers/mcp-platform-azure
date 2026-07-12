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
- All resources are pinned to ARM API version **2024-06-01-preview** (the
  newest listed for these types; a stable `2024-03-01` exists for `services`
  only, and is older/less complete):
  [Microsoft.ApiCenter/services](https://learn.microsoft.com/azure/templates/microsoft.apicenter/2024-06-01-preview/services),
  [services/workspaces](https://learn.microsoft.com/azure/templates/microsoft.apicenter/2024-06-01-preview/services/workspaces),
  [services/workspaces/environments](https://learn.microsoft.com/azure/templates/microsoft.apicenter/2024-06-01-preview/services/workspaces/environments),
  [services/workspaces/apiSources](https://learn.microsoft.com/azure/templates/microsoft.apicenter/2024-06-01-preview/services/workspaces/apisources).
- The `default` workspace must be declared explicitly; API Center supports a
  single workspace and does not auto-create it, and the data-plane registry
  path (`/workspaces/default/...`) depends on it.
  [Set up API Center with an ARM template](https://learn.microsoft.com/azure/api-center/set-up-api-center-arm-template).
- The data-plane MCP registry endpoint has the exact form
  `https://<name>.data.<region>.azure-apicenter.ms/workspaces/default/v0.1/servers`.
  [Register and discover MCP servers](https://learn.microsoft.com/azure/api-center/register-discover-mcp-server#configure-mcp-registry-metadata).
- APIM **auto-sync** keeps the inventory current (production-correct): the
  `apiSources` resource points at the APIM instance id and the servers sync in.
  [Synchronize APIs from an API Management instance](https://learn.microsoft.com/azure/api-center/synchronize-api-management-apis).
- Auto-sync requires the API Center managed identity to hold the **API
  Management Service Reader** role on the APIM instance (built-in role id
  `71522526-b88f-4d52-b57f-d31fc3546d0d`).
  [Synchronize APIs from an API Management instance](https://learn.microsoft.com/azure/api-center/synchronize-api-management-apis#enable-a-managed-identity-in-your-api-center),
  [Azure built-in roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#integration).

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

The data-plane registry endpoint returns 401/404 unless the caller is allowed
to read it. API Center governs this through the **portal access method**
("Allow anonymous access" vs Microsoft Entra ID authentication), configured in
the Azure portal under **Consumption > Data API settings**. The access method
you choose determines how callers authenticate to the MCP registry endpoint.
[Discover APIs with the Azure API Center MCP server](https://learn.microsoft.com/azure/api-center/discover-catalog-mcp-server),
[Set up the API Center portal](https://learn.microsoft.com/azure/api-center/set-up-api-center-portal).

**This mode is not settable through the azapi resource surface as of
2026-07-12.** The `Microsoft.ApiCenter/services` resource exposes only `restore`
and `identity`; there is no ARM property (nothing analogous to Storage's
`allowBlobPublicAccess`) for anonymous vs Entra data-plane read access, and no
`Microsoft.ApiCenter` child resource type models portal/data-API settings in
the ARM template reference. The toggle is therefore applied **out of band**
(portal, or a settings API not surfaced in the ARM template reference).

The module's `registry_read_access = { mode }` input records the **intended**
mode and drives the `registry_read_access_mode` output so the integration
issue's bounded poll authenticates (or not) to match. It does not itself
provision the toggle. This limitation is recorded in COMPATIBILITY.md.

The tracer's chosen mode is **`anonymous`**: it lets the bounded poll assert the
synced server inside a short-lived deployment without acquiring a data-plane
token.

**Security implication (public endpoint).** With anonymous read, the registry
inventory (MCP server names, endpoint URLs, transport types) is readable by
anyone on the public internet with no authentication. That is acceptable only
because this is the synthetic, public-demo tracer whose data is labelled
synthetic and whose backend is itself a demo. A real deployment should use
`entra` read access (callers present a Microsoft Entra token whose principal
holds the **Azure API Center Data Reader** role,
`c7244dfb-f447-457d-b2ba-3999044d1706`) so the inventory is not publicly
enumerable, and the poll would acquire such a token. This mirrors the honest
public-demo posture the spec requires for the gateway (security.md): in the
public-demo profile, discovery surfaces are reachable without a secret.

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
| `registry_read_access` | object | `{ mode }`, `"anonymous"` or `"entra"`. Records the intended read-access mode (applied out of band; see above) and drives the output. |
| `workspace_title` | string | Display title of the single `default` workspace. Default `"Default workspace"`. |
| `assign_apim_reader_role` | bool | Whether to assign the service identity the API Management Service Reader role on `apim_source_id`. Default `true`. |

## Outputs

| Name | Description |
|---|---|
| `api_center_name` | Resource name of the API Center service. |
| `api_center_id` | ARM resource ID of the service. |
| `registry_endpoint_url` | Data-plane registry endpoint, `.../workspaces/default/v0.1/servers`. |
| `registry_read_access_mode` | The read-access mode the poll must match (echoed from the input). |
| `workspace_name` | Always `"default"`. |
| `environment_id` | ARM id of the environment the synced server is associated with. |
| `api_source_id` | ARM id of the APIM auto-sync source. |
| `identity_principal_id` | Principal id of the service's system-assigned identity. |

## Live-gate prerequisites (integration issue, not this ticket)

- Assigning the API Management Service Reader role (`assign_apim_reader_role =
  true`, the default) requires the deploying principal to hold
  role-assignment-write (for example **User Access Administrator**) on the APIM
  scope. Set the flag to `false` if the composition grants that role out of
  band, and wire `identity_principal_id` to that assignment instead.
- The `anonymous` registry read mode must be applied out of band (portal Data
  API settings) before the poll runs, as described above.
- Re-verify the derived `registry_endpoint_url` region slug for any region
  whose data-plane hostname is not simply its lowercased name.

## Out of scope (this ticket)

No `terraform apply`/`destroy`; no bounded-poll assertion script (that is the
integration issue); no explicit `azapi` server registration as the primary
mechanism (auto-sync is primary; explicit registration is a labelled fallback
only); no API Center portal publishing flow; no Foundry tool-catalog wiring;
no scenario composition wiring.
