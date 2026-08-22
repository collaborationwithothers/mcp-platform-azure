# src: the S1 MCP server and its test client

This directory holds the .NET side of the v1 tracer bullet (scenario S1): the
host-neutral MCP application core, its Azure Functions and ASP.NET Core host
adapters, the hand-written MCP test client, and the in-process tests. Both
adapters are deployed and expose the same three core-backed tools. The Functions
adapter remains the API Management backend. The ASP.NET Core adapter runs on the
private Istio route until issue #117 cuts the gateway over. Spec:
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
Functions adapter. It is deployed on the private Istio route beside Functions.
API Management remains routed to Functions until issue #117. The
[issue #154 closeout](https://github.com/collaborationwithothers/mcp-platform-azure/issues/154#issuecomment-5368837859)
records delegated and app-only calls through the private host. Issue #147 also
changed the deployed Functions code path: delegated OBO requires the validated
`tid` claim and uses that tenant for the authority instead of the configured
server tenant.

The adapter validates the signature, issuer, audience, and lifetime of each
JSON Web Token (JWT) before MCP dispatch. It sets the validation clock skew to
zero, so an expired token receives HTTP 401 instead of the token library's
default five-minute grace period. Entry requires either existing
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
v2 authorization server advertised in that metadata. The server resource app
currently issues v1 access tokens, so JWT validation reads the tenant-specific
v1 OpenID metadata and exact v1 issuer derived from `MicrosoftEntra__TenantId`.
`Authentication__Audience` supplies the unchanged server App ID URI, which is
Entra's identifier for the server resource, and the prefix for the two advertised
delegated scopes.

The ASP.NET Core host requires these environment variables. This table records
formats only; it contains no real tenant, application, or endpoint value. The
GitOps workload carries the keys, and the deployment workflow supplies their
environment-specific values before the pod starts.

| Environment variable | Required format |
| --- | --- |
| `Authentication__Authority` | Absolute tenant-specific Entra v2 authorization-server URI advertised by PRM, such as `https://login.microsoftonline.com/<tenant-id>/v2.0` |
| `Authentication__Audience` | Exact MCP server App ID URI, such as `api://<server-app-client-id>` |
| `MicrosoftEntra__ServerAppClientId` | MCP server application client ID as a UUID; this is an identifier, not a secret |
| `MicrosoftEntra__TenantId` | MCP server home-tenant directory ID as a UUID; token validation derives the v1 metadata and issuer from it, and app-only token acquisition uses it |
| `DownstreamOrdersApi__BaseUrl` | Absolute HTTPS origin for Orders, with no `/api/orders` path |
| `DownstreamOrdersApi__Scope` | Exact delegated Orders scope, such as `api://<orders-app-client-id>/user_impersonation` |
| `DownstreamOrdersApi__ApplicationScope` | Orders application scope in `api://<orders-app-client-id>/.default` form |

The container listens for HTTP on port 8080 because Istio terminates TLS before
the request reaches the deployed pod. The runtime selects the built-in non-root
`app` user. Its
`/healthz` endpoint is anonymous so Kubernetes can probe it, but the response is
only the plain health status. The `/mcp` endpoint keeps its existing token and
entitlement checks.

The app processes `X-Forwarded-Proto` before authentication so a trusted proxy
can preserve the caller's HTTPS scheme on the HTTP hop to the container. This
is the ASP.NET Core pattern for a TLS-terminating proxy. The framework's trusted
proxy and network defaults stay in force outside Development. See
[proxy and load balancer configuration](https://learn.microsoft.com/aspnet/core/host-and-deploy/proxy-load-balancer?view=aspnetcore-10.0).

Envoy is Istio's proxy process that runs beside the app. This placement is
called a sidecar.

REDIRECT is Istio's interception mode that rewrites the inbound connection
address and loses the original source network address. This design relies on
Envoy opening the app-facing connection from a loopback address, which ASP.NET
Core trusts by default. The production contract therefore requires an AKS Istio
sidecar using REDIRECT. The MCP namespace carries the active managed Istio
revision. The deployed pod contains `istio-proxy`, and its interception mode is
REDIRECT. The issue #154 live record observed that private ingress leaves the
app seeing a loopback peer and the HTTPS scheme. See the
[issue #154 closeout](https://github.com/collaborationwithothers/mcp-platform-azure/issues/154#issuecomment-5368837859).
The current proxy trust does not support a sidecarless path.
It also does not support TPROXY interception, which preserves the original
source address. See
[AKS sidecar injection](https://learn.microsoft.com/azure/aks/istio-deploy-addon#enable-sidecar-injection)
and [Istio inbound interception modes](https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/#InboundInterceptionMode).

The final image contains the ASP.NET Core runtime and published application
output. The .NET SDK, source, test projects, and other repository content stay
in the build stage or outside the narrow Docker build context. CI proves those
boundaries before it starts the image and exercises private metadata discovery
and an authenticated `get_service_info` call.

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
`MCP_TEST_PROFILE=service-info` selects the no-downstream tool path used by the
local container check. The default remains the deployed order-status path.

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

## Build and test the container locally

Docker builds from the repository root because the ASP.NET Core project
references the application core. The repo-root `.dockerignore` admits only
those two projects and `NuGet.config`.

1. If the operator is anywhere inside the checkout, the operator enters the
   repository root:

   ```bash
   cd "$(git rev-parse --show-toplevel)"
   ```

2. The operator builds the image:

   ```bash
   docker build \
     --file src/McpTools.AspNetCore/Dockerfile \
     --tag mcp-tools-aspnetcore:local \
     .
   ```

3. The operator runs the container check:

   ```bash
   bash scripts/ci/test-mcp-container.sh mcp-tools-aspnetcore:local
   ```

The check generates a short-lived signing key in a temporary directory. It
starts a local OpenID Connect test issuer, then removes the key, token, test
container, and temporary files on exit. The application accepts that HTTP
issuer only when `ASPNETCORE_ENVIRONMENT=Development` and
`Authentication__RequireHttpsMetadata=false`. Production startup rejects that
combination. The check also sets `ReverseProxy__TrustAnyForwarder=true` because
the Docker host is its temporary proxy. Production startup rejects that setting.

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
