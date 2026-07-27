# ADR-002: MCP server hosting selection

Status: Accepted (v1 tag, 2026-07-22)
Date: 2026-07-08
Accepted: 2026-07-22

## Acceptance (v1 tag, 2026-07-22)

Accepted: v1 hosts the MCP server on the Azure Functions MCP extension, Flex
Consumption, .NET isolated worker, exactly as decided. Proven by the
mcp-function-host module (Flex Consumption + Entra built-in auth; PR #14), the
McpTools server implementing get_order_status (PR #15), the gate step that
deploys the function code before assertions (PR #40), and live invocation of the
deployed server through the gate (PR #37; green run 29892332176, 2026-07-22). The
extension is pinned at Microsoft.Azure.Functions.Worker.Extensions.Mcp 1.5.1 with
the 1.0.0-preview.4 SDK integration middleware (COMPATIBILITY.md), which resolves
the "extension version pinning and preview-churn exposure" that Consequences
below flagged. Cold-start and stateful-extension scale-out remain
characterised-in-passing, not load-tested; no latency figures are claimed.

## Context

Azure offers several ways to host an MCP server: the Azure Functions MCP
extension (triggers/bindings), self-hosted MCP SDK servers as Functions
custom handlers (preview, stateless only), Azure Container Apps (standalone
container), App Service, Logic Apps (preview, connector-backed tools), and
AKS. The v1 server is a set of synthetic .NET tools demonstrating
Entra-secured, OBO-capable tool execution.

## Decision

v1 uses the Azure Functions MCP extension on Flex Consumption with .NET
isolated worker. It is the GA path, supports stateful sessions, integrates
with built-in auth, and keeps repo focus on platform concerns rather than
protocol plumbing.

## Alternatives considered

- Self-hosted MCP SDK on Functions custom handlers: rejected for v1
  (preview, stateless only); revisit as a gated-phase variant.
- Container Apps standalone server: deferred; it is the tested pattern for
  Foundry private MCP and is planned for the private/Foundry phase, not v1.
- App Service, Logic Apps, AKS: to document with reasons when this ADR is
  expanded during S1.

## Consequences

To expand during S1: extension version pinning and preview-churn exposure
(see COMPATIBILITY.md), scale-out characteristics of the stateful extension,
cold start on Flex Consumption.

## References

To add during implementation.