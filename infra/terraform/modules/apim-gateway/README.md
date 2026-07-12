# apim-gateway

Wraps [`Azure/avm-res-apimanagement-service/azurerm` 0.9.0](https://registry.terraform.io/modules/Azure/avm-res-apimanagement-service/azurerm/0.9.0)
to provision the API Management instance that fronts the Functions MCP
server, at the Basic v2 SKU with a system-assigned managed identity, and to
serve the single gateway-root protected resource metadata (PRM) document.
This is the S2 gateway module in the [v1 tracer bullet](../../../../docs/specs/v1-tracer-bullet.md).

No deployment happens in this ticket: the module is proven by `terraform fmt`,
`init -backend=false`, `validate`, `tflint`, and `checkov` only. The live
apply-call-destroy proof is the integration issue (issue 5 of the tracer
epic, per the spec's Delivery shape).

## Root PRM document lives here (the instantiate-twice test)

The RFC 9728 PRM document is served at the gateway root well-known path
`/.well-known/oauth-protected-resource`. That location is a property of the
gateway: an API Management service has exactly one root path
(`path = ""`), so exactly one root PRM document. Only the document's
*contents* describe a specific MCP server, and those arrive as the `prm`
input from the composition.

The singleton lives in this module rather than in `apim-mcp-server` because
of the instantiate-twice test: `apim-mcp-server` can be instantiated more
than once against one gateway (several MCP servers behind one APIM), but the
root PRM document cannot -- a second module trying to create a second API at
`path = ""` would collide. The singleton belongs in the layer whose
cardinality it shares (one per gateway), so a second MCP server added later
reuses this one document instead of fighting over the root path. The
multi-server, path-suffixed PRM form (metadata scoped per resource path) is
a documented ADR growth path, not this interface.

`apim-mcp-server` still owns the 401 plus `WWW-Authenticate` **challenge**
in its server-scope policy; this module owns the **document** the challenge
points at, exposed as the `prm_url` output.

Serving mechanics: as of 2026-07-12 Microsoft Learn documents no native APIM
feature for serving a document at the gateway root well-known path (the
"Secure access to MCP servers in API Management" page links out only to
community samples for PRM-style authorization). This module hand-rolls it as
an API mounted at `path = ""` with one
`GET /.well-known/oauth-protected-resource` operation whose policy returns a
static RFC 9728 JSON document via `<return-response>` -- no backend call --
following the `blackchoey/remote-mcp-apim-oauth-prm` reference architecture
named in the ticket. Built from ordinary, documented APIM policy primitives
(`return-response`, `set-header`, `set-body`); no claim that APIM serves PRM
natively. `azapi` 2.10.0's embedded schema does not yet recognize the
`2025-09-01-preview` API version for these types, so each such resource sets
`schema_validation_enabled = false`; see COMPATIBILITY.md.

## Issue-3 AVM capability check (2026-07-12)

The spec requires this issue to open by verifying
`avm-res-apimanagement-service` 0.9.0 can express the Basic v2 SKU, with a
pre-declared raw-`azurerm` fallback (a plain `azurerm_api_management`
resource) if it cannot.

**Outcome: Basic v2 is expressible. No fallback needed.**

Verified directly against the module's published documentation (fetched via
the Terraform MCP registry tools, module id
`Azure/avm-res-apimanagement-service/azurerm/0.9.0`) and the `azurerm`
provider resource docs:

- `sku_name` on the AVM module is a plain pass-through `string` (default
  `"Developer_1"`, no enum validation in the module itself), forwarded
  directly to the underlying `azurerm_api_management` resource.
- The `azurerm_api_management` resource's `sku_name` argument accepts
  `"<tier>_<capacity>"` where tier is one of `Consumption`, `Developer`,
  `Basic`, `BasicV2`, `Standard`, `StandardV2`, `Premium`, `PremiumV2`
  ([azurerm provider docs](https://registry.terraform.io/providers/hashicorp/azurerm/4.80.0/docs/resources/api_management)),
  confirmed against azurerm 4.80.0 (the pinned provider version). `BasicV2_1`
  is therefore a valid, expressible SKU value; this module defaults
  `sku_name` to `BasicV2_1`.
- Microsoft Learn confirms Basic v2 (a "v2 tier" gateway) supports MCP server
  management features: ["About MCP servers in Azure API Management"](https://learn.microsoft.com/azure/api-management/mcp-server-overview)
  and the [gateway feature-comparison table](https://learn.microsoft.com/azure/api-management/api-management-gateways-overview#feature-comparison-managed-versus-self-hosted-gateways)
  both list "Pass-through MCP server" as supported on Classic and v2 gateway
  tiers (not Consumption). Verified 2026-07-12.
- `managed_identities.system_assigned` is a top-level input on the AVM
  module; the underlying resource exposes the created identity via the
  module's `resource` output (the full underlying `azurerm_api_management`
  resource), accessed here as `module.apim.resource.identity[0].principal_id`.
  The AVM module has no dedicated `identity_principal_id`-style output of its
  own for the top-level service identity (it does expose an unrelated
  `workspace_identity` output for the APIM *workspaces* feature, which this
  module does not use).

See COMPATIBILITY.md for the full pin table and doc links.

## Inputs

| Name | Type | Description |
|---|---|---|
| `name` | string | Name of the API Management service. |
| `location` | string | Azure region. |
| `resource_group_name` | string | Name of the (out-of-band) resource group. |
| `tags` | map(string) | Tags applied to the service, expected to include the ephemeral expiry tag. |
| `sku_name` | string | `"<tier>_<capacity>"`. Default `"BasicV2_1"` (the tracer's public-demo profile). A later scenario composition can drive a different profile (e.g. a private-network tier in v1.1) without changing this module. |
| `publisher_name` | string | API Management publisher/company name. |
| `publisher_email` | string | API Management publisher email. |
| `tenant_id` | string | Entra tenant ID callers authenticate against. Not consumed by this module (Entra token validation is owned by `apim-mcp-server`'s server-scope policy); present for thick-interface completeness. |
| `prm` | object | `{ resource, authorization_server, scopes }` -- the contents of the single root PRM document. Singular values for one document (not a map): `resource` is the protected resource identifier, `authorization_server` is the OAuth authorization server (issuer) URL rendered into `authorization_servers[0]`, `scopes` becomes `scopes_supported`. Supplied by the composition from the MCP server's identity values. |

## Outputs

| Name | Description |
|---|---|
| `apim_id` | ARM resource ID of the API Management service. |
| `apim_name` | Name of the API Management service. |
| `gateway_url` | Gateway URL (`https://<name>.azure-api.net`). |
| `prm_url` | Gateway-root PRM URL (`https://<gateway>/.well-known/oauth-protected-resource`), per RFC 9728. Served at the gateway root, not under any API subpath. `apim-mcp-server`'s 401 challenge points callers here. |
| `identity_principal_id` | Principal ID of the system-assigned managed identity. Unused in the tracer; present for the thick interface. |

## Out of scope (this ticket)

No `terraform apply`/`destroy`; no MCP server API (that is `apim-mcp-server`),
no products, subscriptions, or scenario composition wiring (the integration
issue); no private networking (v1.1) or observability wiring (v1.2) beyond
what the AVM module sets by default. This module serves the PRM *document*
but does not create the MCP server or its challenge policy.
