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

- `Tools/GetOrderStatus.cs` - the tool. The `[McpToolTrigger]` method delegates
  immediately to a pure, host-independent `Resolve(string orderId)` method so
  the tool logic is unit-testable with no Functions host. Two typed result
  shapes:
  - known id  -> `{ orderId, status, updatedUtc }`
  - unknown id -> `{ orderId, found: false, message }` (a typed result, never a
    thrown error)
- `Fixtures/SyntheticOrders.cs` - the fixed in-memory fixture, ids CONTOSO-1001
  to CONTOSO-1005. The data is SYNTHETIC and the tool description says so.
- `Program.cs` - standard isolated-worker host. The attribute-based tool model
  needs no MCP-specific host-builder call.

The tool is self-contained in the tracer: it calls nothing downstream (no HTTP
client, no outbound call, no downstream TODO). Downstream access arrives only
with the OBO issue, which reimplements `Resolve` without changing the contract.

The tool contract is frozen at v1; only the implementation may change later.

### McpTestClient (`src/McpTestClient`)

A hand-written .NET MCP client (the official ModelContextProtocol C# SDK) that
drives a real MCP session against the deployed gateway endpoint - the primary
behavioural seam in the spec's Testing Decisions.

This is the ticket-2 SKELETON. It wires the session shape end to end -
connect -> initialize -> tools/list -> tools/call - and prints what it sees. The
behavioural assertions and the non-interactive client-credentials token
acquisition are deliberately left as no-op stubs; ticket 5 (the live
apply-call-destroy gate) fills them in. It reads the target endpoint from the
`MCP_SERVER_ENDPOINT` environment variable or the first CLI argument.

### McpTools.Tests (`tests/McpTools.Tests`)

The unit seam: in-process xUnit tests that call `GetOrderStatus.Resolve`
directly, with no Azure Functions host and no Azure dependency. They cover the
success path for all five ids, the typed not-found path, and that the tool
description marks the data synthetic.

## Build and test locally

```
dotnet build src/McpPlatform.sln --configuration Release
dotnet test  src/McpPlatform.sln --configuration Release --no-build
```

Restore is pinned to the public nuget.org feed by the repo-root `NuGet.config`.

## Pinned packages

Verified 2026-07-12; recorded with doc links in `COMPATIBILITY.md`.

| Package | Version | Role |
|---|---|---|
| Microsoft.Azure.Functions.Worker.Extensions.Mcp | 1.5.1 | MCP tool triggers (GA) |
| Microsoft.Azure.Functions.Worker | 2.52.0 | isolated worker runtime |
| Microsoft.Azure.Functions.Worker.Sdk | 2.0.7 | isolated worker build SDK |
| ModelContextProtocol | 1.4.1 | MCP client SDK (test client) |
