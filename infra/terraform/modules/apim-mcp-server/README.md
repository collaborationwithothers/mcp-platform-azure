# apim-mcp-server

Hand-authored `azapi` module that creates a passthrough ("existing MCP
server") MCP server in API Management, fronting `mcp-function-host`. This is
the other half of the S2 gateway module in the
[v1 tracer bullet](../../../../docs/specs/v1-tracer-bullet.md), alongside
`apim-gateway`.

No deployment happens in this ticket: the module is proven by `terraform fmt`,
`init -backend=false`, `validate`, `tflint`, and `checkov` only. The live
apply-call-destroy proof is the integration issue (issue 5 of the tracer
epic, per the spec's Delivery shape).

## Verified facts (2026-07-12)

Verified via the azure-docs-verifier subagent against current Microsoft
Learn, not recalled from training data:

- `Microsoft.ApiManagement/service/apis@2025-09-01-preview` with
  `properties.type = "mcp"`, `serviceUrl`, and `mcpProperties.transportType
  = "streamable"` with a single `{ name = "message", uriTemplate = "/mcp" }`
  endpoint is the correct passthrough MCP server shape; azurerm has no
  native resource for it.
  [Manage MCP servers programmatically in API Management](https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api)
  gives a working Terraform `azapi_resource` example, mirrored in `main.tf`.
  One deliberate deviation from that example: it sets
  `subscriptionRequired: true` and binds a product by default; this module
  sets `subscriptionRequired = false` and binds no product
  (`product_ids = []`) by default, per the spec (Gateway and authorization
  (S2): "There are no products or subscriptions" in the tracer).
- APIM Basic v2 (a v2-tier gateway) supports MCP servers.
  [About MCP servers in Azure API Management](https://learn.microsoft.com/azure/api-management/mcp-server-overview),
  [gateway feature comparison](https://learn.microsoft.com/azure/api-management/api-management-gateways-overview#feature-comparison-managed-versus-self-hosted-gateways).
- `validate-azure-ad-token` supports `<audiences><audience>` directly (no
  `required-claims` workaround needed to check the server app's App ID
  URI), alongside `<client-application-ids>`.
  [Validate Microsoft Entra token](https://learn.microsoft.com/azure/api-management/validate-azure-ad-token-policy).
- Never read `context.Response.Body` in MCP-scoped policies; it forces
  response buffering and breaks the streaming behaviour MCP requires.
  [Expose and govern an existing MCP server](https://learn.microsoft.com/azure/api-management/expose-existing-mcp-server#configure-policies-for-the-mcp-server).
  This module's policies never reference it.

## The 401 challenge, and where the PRM document lives

The spec's acceptance criteria require APIM to own the 401 plus
`WWW-Authenticate` challenge for unauthenticated MCP calls, pointing callers
at the protected resource metadata (PRM) document served at the gateway root
well-known path (`/.well-known/oauth-protected-resource`).

This module owns the **challenge**: `azapi_resource.mcp_server_policy` (the
MCP server's own server-scope policy) handles the two 401 paths -- a
`return-response` for a missing `Authorization` header, and an `on-error`
`WWW-Authenticate` header for a token that `validate-azure-ad-token` rejects.
Both point at `prm_url` (this module derives that URL from the gateway
hostname it reads via the `azapi_resource.apim` data source).

The **PRM document itself** is served by the `apim-gateway` module, not this
one. The root well-known location is a property of the gateway (one root
path per API Management service, so one root document), whereas this module
can be instantiated more than once against a single gateway. The singleton
therefore belongs in the gateway, whose cardinality it shares; a second MCP
server added to the same gateway reuses the gateway's single PRM document.
`apim-gateway`'s README documents the instantiate-twice rationale and the
`blackchoey/remote-mcp-apim-oauth-prm` reference pattern the document
serving follows.

**As of 2026-07-12, Microsoft Learn documents no native APIM feature for
serving PRM at the gateway root** (the "Secure access to MCP servers in API
Management" page covers subscription keys, `validate-azure-ad-token`, header
forwarding, and credential-manager outbound tokens, and for PRM-style
inbound authorization links out only to community samples). App Service's
*built-in MCP* feature does natively publish PRM at the same well-known
path, but that is an App Service capability, not an APIM one, and is not
what this platform deploys.

## Inputs

| Name | Type | Description |
|---|---|---|
| `apim_id` | string | ARM resource ID of the parent API Management service. |
| `server_name` | string | Resource name of the MCP server API. |
| `server_path` | string | Path segment the server is exposed under. |
| `backend_service_url` | string | Base URL of the external MCP backend (mcp-function-host's `mcp_backend_base_url`). |
| `transport` | object | `{ type = "streamable", endpoints = [{ name = "message", uri_template = "/mcp" }] }` by default. `sse` requires exactly two endpoints (`sse`, `message`). |
| `subscription_required` | bool | Default `false` (no products/subscriptions in the tracer). |
| `entra_validation` | object | `{ tenant_id, audience, allowed_client_application_ids }`. `audience` is the server app's App ID URI. |
| `product_ids` | list(string) | Existing product names to bind to. Default `[]` (empty in the tracer); appending here is additive, not a restructure. |

The PRM document contents (resource identifier, authorization server URL,
scopes) are not inputs to this module; they are inputs to `apim-gateway`,
which serves the single root document. The composition supplies them there
from this server's identity values.

## Outputs

| Name | Description |
|---|---|
| `mcp_server_api_id` | ARM resource ID of the MCP server API. |
| `mcp_server_url` | Client-facing MCP endpoint, `https://<gateway>/<server_path>/mcp`. |
| `prm_url` | Gateway-root protected resource metadata URL, `https://<gateway>/.well-known/oauth-protected-resource`. |

## Out of scope (this ticket)

No `terraform apply`/`destroy`; no products, subscriptions, rate-limit or
quota policies, or content safety (S2 thickening); no REST-backed MCP server
or tool child resources (passthrough only); no scenario composition wiring
or backend config (the integration issue).
