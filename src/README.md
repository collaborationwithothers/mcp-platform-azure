# src: the S1 MCP server and its test client

This directory holds the .NET side of the v1 tracer bullet (scenario S1): the
Functions-hosted MCP server, the hand-written MCP test client, and the
in-process unit tests. Spec: `docs/specs/v1-tracer-bullet.md` (sections
"Compute and the tool (S1)" and "Testing Decisions"). Glossary: `src/CONTEXT.md`.

Everything here is built and tested by the `dotnet-build` CI job. That job
discovers the solution with `find src -type f -name '*.sln'`, so the solution
lives here at `src/McpPlatform.sln` and references the repo-root test project by
relative path.

## Projects

### McpTools (`src/McpTools`)

The Azure Functions .NET isolated-worker MCP server (ADR-002). It exposes a
single synthetic tool, `get_order_status`, using the Azure Functions MCP
extension tool trigger.

The tool contract is frozen at v1; only its data source varies, and it varies
by caller identity mode (issue 10, OBO thickening). The two typed result shapes
are unchanged:
- known id  -> `{ orderId, status, updatedUtc }`
- unknown id -> `{ orderId, found: false, message }` (a typed result, never a
  thrown error)

- `Identity/` - the identity-mode decision, kept out of the tool so it is
  unit-testable in isolation:
  - `ClientPrincipal.cs` - parses the Base64 JSON `X-MS-CLIENT-PRINCIPAL`
    header Easy Auth injects on every request it validates.
  - `IdentityModeResolver.cs` - decides the mode from that header's claims:
    - an `scp` claim -> **Delegated** (a user-context caller): sourced from the
      synthetic downstream Orders API via the Entra On-Behalf-Of exchange.
    - an `azp`/`appid` application identity and no `scp` -> **App-context** (a
      client-credentials, app-only caller): requires `Orders.Read` in `roles`,
      then calls the downstream as the MCP server's own application identity.
    - missing / malformed / neither-claim -> a fail-closed rejection.
- `Tools/GetOrderStatus.cs` - the tool. `Run` resolves the mode, then branches
  to delegated OBO or the app-only trusted-subsystem downstream
  (`Downstream/`). The pure,
  host-independent pieces (`ServeFromFixture`, `TryExtractInboundAccessToken`)
  are unit-tested with no Functions host.
- `Downstream/` - delegated OBO and app-only token acquisition plus the
  downstream Orders API client. The server never forwards the inbound token;
  each branch acquires a downstream-audience token (docs/decisions/ADR-006).
- `Fixtures/SyntheticOrders.cs` - the fixed in-memory fixture, ids CONTOSO-1001
  to CONTOSO-1005. The data is SYNTHETIC and the tool description says so.
- `Hosting/BuiltInAuthGuard.cs` - the startup fail-closed check (below).
- `Program.cs` - isolated-worker host. Runs `BuiltInAuthGuard` before serving,
  and wires the OBO exchange via DI.

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
token's signature in code (Easy Auth does). It instead asserts the trust chain
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
tools/call. The normal mode asserts both frozen result contracts; the
`MCP_EXPECT_FORBIDDEN_ROLE` mode asserts the deterministic missing-role MCP
error. It reads the target endpoint and bearer token from
`MCP_SERVER_ENDPOINT` and `MCP_ACCESS_TOKEN`.

### McpTools.Tests (`tests/McpTools.Tests`)

The unit seam: in-process xUnit tests with no Azure Functions host and no Azure
dependency. They cover the identity-mode decision (`IdentityModeResolverTests`,
`ClientPrincipalTests`), the tool's mode branching (`GetOrderStatusRunTests`),
the pure fixture seam and frozen contract shapes (`GetOrderStatusTests`), both
downstream identity modes never forwarding the inbound token
(`DownstreamOrdersClientTests`), and the startup fail-closed auth guard
(`BuiltInAuthGuardTests`).

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
| ModelContextProtocol | 1.2.0 | typed MCP tool-error result for the Functions server |
| ModelContextProtocol | 1.4.1 | MCP client SDK (test client) |
