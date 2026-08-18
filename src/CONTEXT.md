# Src Context

The application domain: the host-neutral MCP application behaviour, its currently
deployed Azure Functions host adapter, and the APIM MCP gateway behaviour
(scenarios S1 and S2), plus the MCP client used to test them. Glossary only.
ASCII punctuation.

## Language

**Tool**:
A single callable capability the MCP server exposes to clients. Has a typed
input and a typed result, including a typed not-found result. Three exist:
get_order_status, which takes an order id and reads the downstream Orders
API; get_service_info, which takes no input, calls nothing downstream, and
returns fixed strings; and get_access_guidance, which describes the
entitlements this server's tools require. Each tool is authorized on its own,
and the three exist to make that provable rather than asserted. The first two
require DIFFERENT app roles (Orders.Read and ServiceInfo.Read), so a caller
entitled to one is refused the other. The third requires NO role at all, by
deliberate design, which is what makes the gateway's unrestricted
classification an exercised branch rather than a rendered one. Requiring no
role is a classification, not an absence of one.
_Avoid_: function, action, endpoint, command

**MCP application core**:
The host-neutral module that owns the tool contracts, authorization rules, typed
results, normalized caller identity, downstream interface, and synthetic fixture.
It accepts identity and credentials supplied by a host adapter. It does not parse
host requests, acquire credentials, carry hosting attributes, or map results to a
host SDK. The module lives in `src/McpTools.Core`.
_Avoid_: Functions core, shared host

**Host adapter**:
The code that connects a hosting framework to the MCP application core. It parses
the host's request and identity, supplies the downstream implementation, and maps
core outcomes to the host SDK. `src/McpTools` is the Azure Functions adapter and
the still-deployed host. The future ASP.NET Core adapter is not present yet; work
on it begins in issue #146.
_Avoid_: application core, business logic

**MCP server**:
The deployed service formed by a host adapter and the MCP application core. It
exposes tools over streamable HTTP. The current v1 deployment uses the Azure
Functions adapter. It is a passthrough backend behind the gateway; clients never
reach it directly on the sanctioned path.
_Avoid_: tool server, backend service

**Synthetic data**:
Demo data explicitly labelled as fake in the tool description and never derived from
a real system. All demo output is synthetic.
_Avoid_: sample data, test data, mock data

**Built-in auth**:
Entra authentication enforced by the Azure Functions host (Easy Auth). In v1 it
performs the second audience check and, while the backend endpoint is public, is
the compensating control against a direct-to-backend bypass.
_Avoid_: Easy Auth, platform auth

**Second audience check**:
The server-side re-validation of the token audience, independent of the gateway's
validation. The server half of defense in depth.
_Avoid_: re-auth, double check

**Protected resource metadata**:
The document served at the gateway root well-known path that tells a client how to
authenticate to the MCP server. The gateway owns it, not the backend.
_Avoid_: PRM doc, auth metadata, discovery document

**Gateway challenge**:
The gateway-owned unauthenticated response: 401 with a WWW-Authenticate header
pointing at the protected resource metadata.
_Avoid_: auth error, 401 response

**OBO**:
The Entra on-behalf-of token exchange the server uses to call a downstream as the
user. The sanctioned alternative to token passthrough. Lands in the issue after the
tracer.
_Avoid_: delegation, impersonation, token exchange

**Token passthrough**:
The forbidden anti-pattern of reusing the inbound client token to call a downstream
service. Distinct from the gateway forwarding the Authorization header to the
audience-correct backend, which is legitimate.
_Avoid_: token forwarding, token relay

**Tenant**:
An organizational consumer of the platform, distinguished by an Entra app role and,
from S2 onward, an APIM product and subscription for metering. No tenant separation
exists in the v1 tracer.
_Avoid_: customer, org, client

**Product**:
An APIM grouping that binds an MCP server to subscriptions and carries the
per-tenant rate and quota policies. Introduced additively in S2; absent in the
tracer.
_Avoid_: plan, package

**Subscription**:
An APIM subscription that meters and attributes a tenant's calls to a product. Not
the Azure billing subscription.
_Avoid_: key, api key
