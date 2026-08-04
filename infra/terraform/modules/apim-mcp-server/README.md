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
  `properties.type = "mcp"` and `mcpProperties.transportType = "streamable"`
  with a single `{ name = "message", uriTemplate = "/mcp" }` endpoint is the
  correct passthrough MCP server shape; azurerm has no native resource for
  it.
  [Manage MCP servers programmatically in API Management](https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api)
  gives a working Terraform `azapi_resource` example, mirrored in `main.tf`.
  One deliberate deviation from that example: it sets
  `subscriptionRequired: true` and binds a product by default; this module
  sets `subscriptionRequired = false` and binds no product
  (`product_ids = []`) by default, per the spec (Gateway and authorization
  (S2): "There are no products or subscriptions" in the tracer).
- **Two live-gate corrections to the above (2026-07-13/14), both stronger
  evidence than the Learn page since they come from the live service itself:**
  - `mcpProperties.endpoints` must be a JSON object keyed by endpoint name
    (`{"message": {"uriTemplate": "/mcp"}}`), not the array of
    `{name, uriTemplate}` objects the Learn page and ARM template reference
    both show. A live PUT with the array shape returned 400 naming the
    deserialization target as `Dictionary<string, McpEndpointContract>`.
  - `serviceUrl` (the field the Learn page's passthrough example wires the
    backend through) is silently not honoured for `type = "mcp"`. A live PUT
    with `serviceUrl` set and no `backendId` returned 400: "Either BackendId
    or MCP tools must be set, but not both for MCP API." **EXPERIMENTAL,
    unverified**: this module now creates a
    `Microsoft.ApiManagement/service/backends` resource (verified shape:
    `url`, `protocol = "http"`) and wires `properties.backendId` to its bare
    resource name. `backendId` does not appear anywhere in Microsoft Learn,
    the ARM template reference, or the actual `2025-09-01-preview`
    `openapi.json` pulled from `Azure/azure-rest-api-specs` for
    `Microsoft.ApiManagement/service/apis` (its only appearances anywhere in
    that spec are unrelated path parameters on the `backends` CRUD
    endpoints). Whether `backendId` takes a bare name (assumed here, by
    analogy with other same-service child-entity references in this API
    family) or a full ARM resource ID is unconfirmed. Re-verify both facts at
    the next live-test run.
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

## The 401 challenge, per-server entitlement, and where the PRM lives

The spec's acceptance criteria require APIM to own the 401 plus
`WWW-Authenticate` challenge for unauthenticated MCP calls, pointing callers
at this server's protected resource metadata (PRM) document.

This module owns the **challenge**: `azapi_resource.mcp_server_policy` (the
MCP server's own server-scope policy) handles the two 401 paths -- a
`return-response` for a missing `Authorization` header, and an `on-error`
`WWW-Authenticate` header for a token that `validate-azure-ad-token` rejects.
Both point at this server's **own** RFC 9728 s3.1 path-inserted PRM location
(`local.prm_server_url` = the gateway-root well-known URL with this server's
resource path inserted after it; issue 17), so a client connecting to this
server is led to this server's metadata and never another server's. The
deployed `type=mcp` runtime rewrites `resource_metadata` to a path-scoped form
on the wire downstream of this policy (issue-9 trace), so the gate asserts the
client-visible challenge; emitting the correct per-server value here is the
fail-safe for paths the rewrite may not cover (the on-error 401 is
unestablished; live-gate checklist, COMPATIBILITY.md).

This module also owns the **per-server entitlement check** (issue 17). After
`validate-azure-ad-token` succeeds, the policy requires this server's delegated
scope in the `scp` claim OR its app role in the `roles` claim, and fails closed
with a `403 insufficient_scope` (RFC 6750) otherwise. OR, not AND, because a
delegated (user) token carries `scp` and no `roles`, an app-only token the
reverse, and `validate-azure-ad-token`'s `required-claims` ANDs its entries so
cannot express the OR (Microsoft Learn, verified 2026-08-04; COMPATIBILITY.md).
The required scope and role are the per-server `required_scope` / `required_role`
inputs. This is what makes a caller granted only server 1's entitlement
accepted at server 1 and rejected at server 2.

The **PRM documents** are served by the `apim-gateway` module, not this one.
The well-known locations are a property of the gateway host, so the gateway
serves one root document (the s3.3 fail-closed guard) plus one path-inserted
document per server; this module is what gets instantiated once per server.
`apim-gateway`'s README documents the per-server collection and the
`blackchoey/remote-mcp-apim-oauth-prm` reference pattern the document serving
follows.

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
| `required_scope` | string | Per-server delegated scope value (issue 17): the value as it appears in the token `scp` claim (the short scope name, not the full App ID URI). Checked with OR semantics against `required_role` after token validation. Supplied by the composition; the value is out-of-band (tfvars), never committed. |
| `required_role` | string | Per-server app role value (issue 17): the value as it appears in the token `roles` claim. Checked with OR semantics against `required_scope`. Supplied by the composition; out-of-band (tfvars), never committed. |
| `product_ids` | list(string) | Existing product names to bind to. Default `[]` (empty in the tracer); appending here is additive, not a restructure. |

The PRM document contents (resource identifier, authorization server URL,
scopes) are not inputs to this module; they are inputs to `apim-gateway`,
which serves the per-server documents. The composition supplies them there
from each server's identity values. This module contributes only the
per-server entitlement (`required_scope` / `required_role`) that its own policy
enforces, and derives its own path-inserted PRM URL for the challenge.

## Outputs

| Name | Description |
|---|---|
| `mcp_server_api_id` | ARM resource ID of the MCP server API. |
| `mcp_server_url` | Client-facing MCP endpoint, `https://<gateway>/<server_path>/mcp`. |
| `prm_url` | Gateway-root protected resource metadata URL, `https://<gateway>/.well-known/oauth-protected-resource`. |

## Out of scope (this ticket)

No `terraform apply`/`destroy`; no products, subscriptions, rate-limit or
quota policies, or content safety (S2 thickening); no REST-export MCP server
or tool child resources (passthrough only); no scenario composition wiring
or backend config (the integration issue).
