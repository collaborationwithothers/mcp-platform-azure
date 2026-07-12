# apim-gateway

Wraps [`Azure/avm-res-apimanagement-service/azurerm` 0.9.0](https://registry.terraform.io/modules/Azure/avm-res-apimanagement-service/azurerm/0.9.0)
to provision the API Management instance that fronts the Functions MCP
server, at the Basic v2 SKU with a system-assigned managed identity. This is
the S2 gateway module in the [v1 tracer bullet](../../../../docs/specs/v1-tracer-bullet.md).

No deployment happens in this ticket: the module is proven by `terraform fmt`,
`init -backend=false`, `validate`, `tflint`, and `checkov` only. The live
apply-call-destroy proof is the integration issue (issue 5 of the tracer
epic, per the spec's Delivery shape).

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

## Outputs

| Name | Description |
|---|---|
| `apim_id` | ARM resource ID of the API Management service. |
| `apim_name` | Name of the API Management service. |
| `gateway_url` | Gateway URL (`https://<name>.azure-api.net`). |
| `identity_principal_id` | Principal ID of the system-assigned managed identity. Unused in the tracer; present for the thick interface. |

## Out of scope (this ticket)

No `terraform apply`/`destroy`; no MCP server API, policies, products,
subscriptions, or scenario composition wiring (those are `apim-mcp-server`
and the integration issue); no private networking (v1.1) or observability
wiring (v1.2) beyond what the AVM module sets by default.
