# src: the S1 MCP server and its test client

This directory holds the .NET side of the v1 tracer bullet (scenario S1): the
host-neutral MCP application core, its currently deployed Azure Functions
adapter, the hand-written MCP test client, and the in-process tests. The future
ASP.NET Core host is not present yet; work on it begins in issue #146. Spec:
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
- `Downstream/IDownstreamOrdersClient.cs` - separates the core from the host's
  credential acquisition and HTTP client.
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
      synthetic downstream Orders API via the Entra On-Behalf-Of exchange.
    - an `azp`/`appid` application identity and no `scp` -> **App-context** (a
      client-credentials, app-only caller): requires `Orders.Read` in `roles`,
      then calls the downstream as the MCP server's own application identity.
    - missing / malformed / neither-claim -> a fail-closed rejection.
- `Tools/` - the three Functions triggers. Each trigger translates the host
  request into core inputs and maps the core outcome to the Functions MCP SDK
  result.
- `Downstream/` - the Functions implementation of the core downstream interface,
  including delegated OBO and app-only token acquisition. The adapter never
  forwards the inbound token; each branch acquires a downstream-audience token
  (docs/decisions/ADR-006).
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
"OBO and downstream auth" > "Header trust chain," for why the per-request check
is only sound in combination with the startup check.

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

## Build and test locally

```
dotnet build src/McpPlatform.sln --configuration Release
dotnet test  src/McpPlatform.sln --configuration Release --no-build
```

Restore is pinned to the public nuget.org feed by the repo-root `NuGet.config`.

## Pinned packages

Verified through 2026-07-20; recorded with doc links in `COMPATIBILITY.md`.

| Package | Version | Role |
|---|---|---|
| Microsoft.Azure.Functions.Worker.Extensions.Mcp | 1.5.1 | MCP tool triggers (GA) |
| Microsoft.Azure.Functions.Worker.Extensions.Mcp.Sdk | 1.0.0-preview.4 | MCP SDK result middleware for top-level tool errors |
| Microsoft.Azure.Functions.Worker | 2.52.0 | isolated worker runtime |
| Microsoft.Azure.Functions.Worker.Sdk | 2.0.7 | isolated worker build SDK |
| ModelContextProtocol | 0.4.0-preview.3 (transitive via Microsoft.Azure.Functions.Worker.Extensions.Mcp.Sdk) | typed MCP tool-error result compatible with the Functions server middleware |
| ModelContextProtocol | 1.4.1 | MCP client SDK (test client) |
