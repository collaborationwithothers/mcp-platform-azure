# ADR-012: Authorization for the two MCP hosts

Status: Accepted (issue #147; issue #154 targets the ASP.NET Core host on a
private alongside route pending live evidence)
Date: 2026-08-18
Supersedes: ADR-006

## Summary

The Azure Functions and ASP.NET Core hosts expose the same three MCP tools and
apply the same authorization rules. They differ only at the host boundary.
Functions trusts claims supplied by built-in auth, while ASP.NET Core validates
the JSON Web Token (JWT) in the application and reads its validated principal.

Both hosts pass one normalized caller identity into the MCP application core.
The core, not either host adapter, decides whether that caller may run a tool.
This keeps the migration from changing any public tool name, entitlement, or
typed result.

This ADR replaces ADR-006 as the current authorization decision. ADR-006 remains
the historical record of the v1 investigation and its dated live evidence.
ADR-009 remains the current decision for gateway-enforced per-tool
authorization.

## Context

Issue #146 added an authenticated ASP.NET Core tracer with one tool. Issue #147
brings that host to parity with the still-deployed Functions host. The issue
#154 target deploys it through the private Istio route without changing API
Management routing. Running two host implementations at once creates a drift risk: each
host could interpret the same token differently, expose a different tool set,
or acquire downstream tokens through a different security rule.

The host boundary cannot be identical. Functions built-in auth validates the
token and supplies `X-MS-CLIENT-PRINCIPAL`. ASP.NET Core JWT bearer middleware
validates the token and supplies a `ClaimsPrincipal`, which is the framework's
validated caller identity. Claim-name mapping can present `roles` and `scp`
under either their raw names or Microsoft schema-URI aliases.

The delegated `get_order_status` path also needs the original inbound access
token. On-behalf-of (OBO) is the Entra exchange that turns that server-audience
token into a new Orders-audience token. The inbound token is an input to the
exchange, not a credential the Orders API may accept directly.

## Decision

### One tool surface and one set of rules

Both hosts expose exactly these tools from the same MCP application core:

| Tool | Application | Delegated |
| --- | --- | --- |
| `get_order_status` | Needs `Orders.Read` | Needs `Orders.Read.AsUser` |
| `get_service_info` | Needs `ServiceInfo.Read` | Needs `ServiceInfo.Read` |
| `get_access_guidance` | No per-tool entitlement | No per-tool entitlement |

`get_access_guidance` is unrestricted only at the per-tool layer. Every caller
must still enter the server with one existing server entitlement.

Server entry accepts the unchanged union:

- Delegated scopes: `Orders.Invoke` or `Catalog.Invoke`.
- Application roles: `Orders.Invoke.All` or `Catalog.Invoke.All`.

Entry is not a grant to every tool. The core performs the table's independent
per-tool check and denies by default when the required claim is absent. A caller
can therefore enter with one server entitlement and still be refused a tool.

### Each host proves the caller before the core sees it

The Functions adapter keeps its existing trust chain. Built-in auth validates
the token, strips client-supplied `X-MS-*` headers, and injects
`X-MS-CLIENT-PRINCIPAL`. The adapter parses that header and passes normalized
claims to the core. It does not validate the JWT again in application code.

The ASP.NET Core adapter does not read `X-MS-CLIENT-PRINCIPAL`. JWT bearer
middleware validates the token's signature, issuer, audience, and lifetime
before MCP dispatch. The adapter reads only the resulting `ClaimsPrincipal`.
It accepts both raw and mapped aliases for the role and scope claim types, then
does the same for the application id, object id, and tenant id claim types. It
passes that normalized identity shape to the core.

Neither adapter owns a second copy of the tool rules. Tests discover the
ASP.NET Core MCP attributes, reject an empty discovered surface, and compare the
three tool names with the core entitlement table.

### OBO uses two audience-specific tokens

For a delegated `get_order_status` call, refer to the inbound server-audience
token as token A. The ASP.NET Core host reads token A only after token validation
and after the shared delegated-scope check has accepted `Orders.Read.AsUser`.
The core applies that same check before any downstream call from either host.
The OBO exchange uses token A as its user assertion and asks Entra for an
Orders-audience token, token B. Only token B reaches the Orders API.

![Target delegated OBO path: a VNet client reaches the MCP server through the
private Istio gateway. The server exchanges the delegated MCP token for an
Orders-audience token before calling the Orders Function.](../diagrams/identity-obo-aks.drawio.svg)

*Issue #154 target topology. The private route and delegated call remain
pending live evidence. API Management stays on the Functions route until issue
#117.*

The OBO authority uses the `tid` tenant id from the validated caller. It does
not use `/common`. This preserves the caller's tenant for guest and home-tenant
users without parsing an unvalidated token.

The two hosts use different secret-free client assertions:

- Functions keeps `ManagedIdentityClientAssertion` until issue #117 removes
  that host.
- ASP.NET Core uses one reused
  `AzureIdentityForKubernetesClientAssertion` instance. It reads the projected
  service-account token from `AZURE_FEDERATED_TOKEN_FILE` and caches its signed
  assertion until refresh is needed.

The ASP.NET Core assertion provider is a singleton because constructing it for
each call would discard that cache. Neither host stores a client secret.

Application callers do not use OBO. The server acquires an Orders-audience
application token for its own identity. The original caller identifiers remain
audit correlation only.

![Target app-only path: a VNet client reaches the MCP server through the
private Istio gateway. The server acquires its own Orders-audience token before
calling the Orders Function.](../diagrams/identity-app-only-aks.drawio.svg)

*Issue #154 target topology. The private route and app-only downstream call
remain pending live evidence. API Management stays on the Functions route until
issue #117.*

## Alternatives considered

- **Give each host its own authorization rules.** Rejected because the
  migration could silently change a role, scope, tool name, or result. One core
  makes those contracts shared and testable.
- **Parse the inbound JWT again inside a tool.** Rejected because it creates a
  second, weaker identity path outside JWT bearer validation. The ASP.NET Core
  adapter reads claims only from the validated `ClaimsPrincipal`.
- **Forward token A to Orders.** Rejected because token A names the MCP server
  as its audience. OBO exists to produce token B for Orders.
- **Use `/common` for OBO.** Rejected because the validated token already names
  the tenant that issued it. Using `tid` keeps guest calls in that tenant and
  avoids a second tenant-selection rule.
- **Create the Kubernetes assertion provider per request.** Rejected because it
  loses the provider's assertion cache and repeats work for every tool call.
- **Remove the Functions path now.** Rejected because deployment and gateway
  cutover belong to later children of the migration. Issue #147 proves parity
  while both adapters remain in the repository.

## Consequences

- The ASP.NET Core host has the same three-tool surface and typed results as
  Functions. After issue #154 records live evidence, it runs only on the
  private route. API Management stays on Functions until issue #117.
- A framework claim-mapping change does not change authorization because the
  adapter accepts the raw and mapped aliases before normalization.
- Per-tool denial remains fail-closed behind the unchanged server-entry union.
- The delegated path keeps token A inside the host and sends only token B to
  Orders.
- Two client-assertion implementations remain temporarily. Their difference is
  isolated behind the host's token-acquisition adapter until Functions is
  removed.
- Enterprise-Managed Authorization (EMA) remains unimplemented. Adopting it
  requires a separate decision and current provider evidence; this host-parity
  change does not imply support.

## References

Verified on 2026-08-18:

- [Workload identity federation for MSAL.NET](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/web-apps-apis/workload-identity-federation)
- [`AzureIdentityForKubernetesClientAssertion`](https://learn.microsoft.com/dotnet/api/microsoft.identity.web.azureidentityforkubernetesclientassertion)
- [MSAL.NET OBO guidance](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/web-apps-apis/on-behalf-of-flow)
- [Entra OBO protocol flow](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-on-behalf-of-flow)
- [ASP.NET Core inbound claim mapping](https://learn.microsoft.com/dotnet/api/microsoft.aspnetcore.authentication.jwtbearer.jwtbeareroptions.mapinboundclaims)
