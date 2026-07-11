# ADR-001: Gateway-fronted MCP platform architecture

Status: Proposed
Date: 2026-07-08

## Context

MCP servers can be exposed directly to clients using built-in auth on the
compute host. Enterprises adopting MCP need per-tenant rate and quota
controls, uniform authentication, tool-call content inspection, audit, and
the ability to change backends without changing clients. Independent 2025
security scans found a large share of production MCP servers with critical
flaws and weak auth adoption, which argues for a mandatory policy chokepoint
rather than per-server discipline.

## Decision

All client traffic terminates at Azure API Management acting as the MCP
gateway. Backend MCP servers are never exposed directly to clients. Three
tool paths run through the one gateway: REST API exported as MCP, passthrough
to the Functions-hosted MCP server, and proxy to an external MCP server.

## Alternatives considered

- Direct exposure with Functions/App Service built-in auth only: rejected;
  no central rate limiting, tenancy, or content inspection. (Expand with
  detail when S2 lands.)
- Custom gateway (YARP / microsoft/mcp-gateway on AKS): rejected for v1;
  to expand.

## Consequences

To expand during S2 implementation: added hop, APIM MCP limitations (tools
only on REST export, per-server not per-tool policies, streaming and payload
logging constraints), cost of an always-on gateway tier.

## References

To add: Microsoft Learn links used during implementation.