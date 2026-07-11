# ADR-002: MCP server hosting selection

Status: Proposed
Date: 2026-07-08

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