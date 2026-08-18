# src: the S1 MCP server and its test client

This directory holds the .NET side of the v1 tracer bullet (scenario S1): the
host-neutral MCP application core, its currently deployed Azure Functions
adapter, the alongside ASP.NET Core adapter, the hand-written MCP test client,
and the in-process tests. Both adapters expose the same three core-backed tools.
The ASP.NET Core adapter is not deployed by issue #147. Spec:
`docs/specs/v1-tracer-bullet.md` (sections "Compute and the tool (S1)" and
"Testing Decisions"). Glossary: `src/CONTEXT.md`.

Everything here is built and tested by the `dotnet-build` CI job. That job
discovers the solution with `find src -type f -name '*.sln'`, so the solution
lives here at `src/McpPlatform.sln` and references the repo-root test project by
relative path.

## Projects

### McpTools.Core (`src/McpTools.Core`)

The host-neutral MCP application core that host adapters call. It contains no
Azure Functions or ASP.NET Core package reference. It owns the three tool
contracts, authorization rules, typed results, normalized caller identity,
downstream interface, and synthetic fixture.

- `Core/McpToolApplication.cs` - runs the tool rules and returns host-neutral
  values or errors.
- `Core/McpToolContracts.cs` - holds the frozen tool names, descriptions, and
  fixed response values.
- `Identity/` - normalizes caller claims and applies the per-tool role and scope
  checks.
- `Downstream/` - owns the Orders HTTP client and the token-acquisition
  interfaces. Each host supplies its own secret-free credential provider.
- `Fixtures/` and `Tools/` - hold the synthetic order fixture and typed tool
  results.

### McpTools (`src/McpTools`)

The Azure Functions .NET isolated-worker adapter (ADR-002) and the currently
deployed MCP host. Its path remains `src/McpTools` because the ephemeral
environment workflow publishes that project directly. It exposes the three MCP
tools through Azure Functions MCP extension triggers: `get_order_status`,
`get_service_info`, and `get_access_guidance`.

The `get_order_status` contract is frozen at v1. Its data source varies by caller
identity mode (issue 10, OBO thickening), but its two typed result shapes are
unchanged:
- known id  -> `{ orderId, status, updatedUtc }`
- unknown id -> `{ orderId, found: false, message }` (a typed result, never a
  thrown error)

- `Identity/` - parses the built-in auth principal and converts it to the core's
  normalized caller identity:
  - `ClientPrincipal.cs` - parses the Base64 JSON `X-MS-CLIENT-PRINCIPAL`
    header built-in auth injects on every request it validates.
  - `IdentityModeResolver.cs` - maps that principal into the core identity mode:
    - an `scp` claim -> **Delegated** (a user-context caller): sourced from the
      synthetic downstream Orders API via the Entra On-Behalf-Of exchange. The
      validated `tid` claim selects the OBO authority tenant.
    - an `azp`/`appid` application identity and no `scp` -> **App-context** (a
      client-credentials, app-only caller): requires `Orders.Read` in `roles`,
      then calls the downstream as the MCP server's own application identity.
    - missing / malformed / neither-claim -> a fail-closed rejection.
- `Tools/` - the three Functions triggers. Each trigger translates the host
  request into core inputs and maps the core outcome to the Functions MCP SDK
  result.
- `Downstream/` - the Functions credential provider for delegated OBO and
  app-only token acquisition. The shared downstream client never forwards the
  inbound token; each branch acquires a downstream-audience token
  (docs/decisions/ADR-012).
- `Hosting/BuiltInAuthGuard.cs` - the startup fail-closed check (below).
- `Program.cs` - isolated-worker host. Runs `BuiltInAuthGuard` before serving,
  then wires the core, host adapters, and credential acquisition through
  dependency injection.

**App-context is a trusted-subsystem path.** An app-only caller must carry the
`Orders.Read` application role at the MCP layer. The server then acquires a
downstream `/.default` token using its own managed-identity-backed confidential
client and calls the Orders API. The downstream sees and authorizes one server
identity for every app-only caller. The original caller's `azp`/`appid` and
`oid` are logged and forwarded as audit correlation only, never as downstream
authorization inputs. The live apply-call-destroy gate's client-credentials
happy path now exercises this complete production identity path. The delegated
OBO path remains independently validated manually; see
`docs/runbooks/obo-app-registrations.md`, "User-context token strategy."

**Fail-closed header trust.** The server does not re-validate the inbound
token's signature in code (built-in auth does). It instead asserts the trust chain
holds: `BuiltInAuthGuard` refuses to start in any non-`Development` environment
unless a built-in-auth signal is present, and `Run` rejects any request whose
`X-MS-CLIENT-PRINCIPAL` header is missing/malformed. See `docs/security.md`,
"Functions-host OBO and downstream evidence" > "Functions header trust chain,"
for why the per-request check is only sound in combination with the startup
check.

### McpTools.AspNetCore (`src/McpTools.AspNetCore`)

The ASP.NET Core adapter is the new host introduced by issue #146. It serves
`get_order_status`, `get_service_info`, and `get_access_guidance` at `/mcp` in
stateless mode. Each POST is independent, and the host registers no MCP GET or
DELETE session route. The adapter calls the same `McpToolApplication` as the
Functions adapter. The deployment topology and live workflow stay unchanged
until the later gateway-cutover issue. Issue #147 does change the deployed
Functions code path: delegated OBO now requires the validated `tid` claim and
uses that tenant for the authority instead of the configured server tenant.
The automated gate cannot mint a delegated user token. Before PR #157 merges,
Hari must run the manual delegated happy path in
`docs/runbooks/obo-app-registrations.md` against the deployed Functions host. If
the run succeeds, Hari records the OBO evidence on PR #157. That evidence proves
that built-in auth supplies a usable tenant claim.

The adapter validates the signature, issuer, audience, and lifetime of each
JSON Web Token (JWT) before MCP dispatch. Entry requires either existing
delegated server scope
(`Orders.Invoke` or `Catalog.Invoke`) or existing application server role
(`Orders.Invoke.All` or `Catalog.Invoke.All`). It maps raw and framework-mapped
scope, role, application id, object id, and tenant id claim aliases from the
validated `ClaimsPrincipal` into the core's normalized caller identity. The
shared core then applies the unchanged
per-tool rules: `Orders.Read` or `Orders.Read.AsUser` for
`get_order_status`, `ServiceInfo.Read` for `get_service_info`, and no per-tool
entitlement for `get_access_guidance`. Server entry never bypasses these checks.

For delegated `get_order_status`, the adapter reads the inbound bearer from the
validated HTTP request only after authorization admits the call. It uses the
validated `tid` claim as the OBO authority tenant and exchanges the inbound
server-audience token for an Orders-audience token. Only the exchanged token is
sent to Orders. The host reuses one
`AzureIdentityForKubernetesClientAssertion`, which reads the projected
service-account token from `AZURE_FEDERATED_TOKEN_FILE` and needs no client
secret. The Functions adapter keeps `ManagedIdentityClientAssertion` until its
later removal issue.

The private MCP resource is fixed at
`https://mcp.internal.consultwithcloud.com/mcp`. Its protected resource metadata
is fixed at the RFC 9728 path-inserted URI, which places the `/mcp` resource path
after the well-known metadata segment. `Authentication__Authority` supplies the
Entra issuer. `Authentication__Audience` supplies the unchanged server App ID
URI, which is Entra's identifier for the server resource, and the prefix for the
two advertised delegated scopes.

The ASP.NET Core host requires these environment variables. This table records
formats only; it contains no real tenant, application, or endpoint value. Issue
#150 must carry the keys into the GitOps workload, and issue #152 must supply
their environment-specific values before the pod starts.

| Environment variable | Required format |
| --- | --- |
| `Authentication__Authority` | Absolute tenant-specific Entra authority URI, such as `https://login.microsoftonline.com/<tenant-id>/v2.0` |
| `Authentication__Audience` | Exact MCP server App ID URI, such as `api://<server-app-client-id>` |
| `MicrosoftEntra__ServerAppClientId` | MCP server application client ID as a UUID; this is an identifier, not a secret |
| `MicrosoftEntra__TenantId` | MCP server home-tenant directory ID as a UUID; app-only token acquisition uses this tenant |
| `DownstreamOrdersApi__BaseUrl` | Absolute HTTPS origin for Orders, with no `/api/orders` path |
| `DownstreamOrdersApi__Scope` | Exact delegated Orders scope, such as `api://<orders-app-client-id>/user_impersonation` |
| `DownstreamOrdersApi__ApplicationScope` | Orders application scope in `api://<orders-app-client-id>/.default` form |

### McpTestClient (`src/McpTestClient`)

A hand-written .NET MCP client (the official ModelContextProtocol C# SDK) that
drives a real MCP session against the deployed gateway endpoint - the primary
behavioural seam in the spec's Testing Decisions.

It wires the session shape end to end: connect, initialize, tools/list, and
tools/call. The normal mode asserts both frozen result contracts. The
`MCP_EXPECT_FORBIDDEN_ROLE` and `MCP_EXPECT_FORBIDDEN_SCOPE` modes assert the
deterministic backend authorization error for a missing application role or
delegated scope. It reads the target endpoint and bearer token from
`MCP_SERVER_ENDPOINT` and `MCP_ACCESS_TOKEN`.

### McpTools.Tests (`tests/McpTools.Tests`)

The in-process xUnit suite has two test seams:

- Core tests call `McpToolApplication` and the core authorization and fixture
  types directly. They use no Functions transport.
- Adapter tests exercise the Functions triggers, built-in auth header parsing,
  identity translation, result mapping, downstream token paths, and startup
  guard. These tests reference Azure Functions SDK types, but they do not start
  a Functions host process.

Together they preserve the tool results, current Functions authorization and
OBO behaviour, and the rule that neither downstream identity mode forwards the
inbound token.

### McpTools.AspNetCore.Tests (`tests/McpTools.AspNetCore.Tests`)

This suite drives the complete ASP.NET Core middleware and MCP HTTP path in
process. It proves the private challenge and metadata, JWT rejection cases,
stateless method surface, the exact three-tool listing, server-entry entitlement
checks, application and delegated outcomes for every tool, and fail-closed
per-tool denial. Its parity check fails if discovery finds no ASP.NET Core tools
or if a discovered tool has no core entitlement rows.

## Build and test locally

```
dotnet build src/McpPlatform.sln --configuration Release
dotnet test  src/McpPlatform.sln --configuration Release --no-build
```

Restore is pinned to the public nuget.org feed by the repo-root `NuGet.config`.

## Pinned packages

Verified through 2026-08-18; recorded with doc links in `COMPATIBILITY.md`.

| Package | Version | Role |
|---|---|---|
| Microsoft.Azure.Functions.Worker.Extensions.Mcp | 1.5.1 | MCP tool triggers (GA) |
| Microsoft.Azure.Functions.Worker.Extensions.Mcp.Sdk | 1.0.0-preview.4 | MCP SDK result middleware for top-level tool errors |
| Microsoft.Azure.Functions.Worker | 2.52.0 | isolated worker runtime |
| Microsoft.Azure.Functions.Worker.Sdk | 2.0.7 | isolated worker build SDK |
| ModelContextProtocol | 0.4.0-preview.3 (transitive via Microsoft.Azure.Functions.Worker.Extensions.Mcp.Sdk) | typed MCP tool-error result compatible with the Functions server middleware |
| ModelContextProtocol | 1.4.1 | MCP client SDK (test client) |
| Microsoft.AspNetCore.Authentication.JwtBearer | 10.0.11 | JWT validation in the ASP.NET Core adapter |
| Microsoft.Identity.Client | 4.87.0 | OBO token acquisition in the ASP.NET Core adapter |
| Microsoft.Identity.Web.Certificateless | 4.14.2 | Kubernetes workload-identity client assertion for secret-free OBO |
| ModelContextProtocol | 2.2.0 | MCP protocol and tool types in the ASP.NET Core adapter |
| ModelContextProtocol.AspNetCore | 2.2.0 | stateless Streamable HTTP and MCP authentication challenge |
| Microsoft.AspNetCore.Mvc.Testing | 10.0.11 | in-process ASP.NET Core HTTP tests |
