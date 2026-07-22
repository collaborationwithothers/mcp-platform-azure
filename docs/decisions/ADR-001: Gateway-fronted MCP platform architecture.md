# ADR-001: Gateway-fronted MCP platform architecture

Status: Accepted (v1 tag, 2026-07-22; passthrough path only, see Acceptance)
Date: 2026-07-08
Accepted: 2026-07-22

## Acceptance (v1 tag, 2026-07-22)

Accepted on the evidence of the v1 build and its live gate, scoped to what v1
actually exercised. The gateway-fronted principle -- all client traffic
terminates at APIM and the Functions MCP backend is never exposed directly to
clients -- is proven by the S2 gateway modules (apim-gateway, apim-mcp-server;
PR #16), the S1/S2 tracer compositions and gated live-test harness (PR #22), the
call stage that drives client -> APIM -> Easy Auth -> Functions MCP server (PR
#37) after deploying real function code (PR #40), and the green live gate (run
29892332176, 2026-07-22).

Scope of acceptance: only ONE of the three tool paths in the Decision was built
and proven in v1 -- passthrough to the Functions-hosted MCP server. The
REST-API-exported-as-MCP path and the external-MCP-server proxy path are NOT
built in v1 (S6 and later) and are NOT proven; this ADR's acceptance does not
extend to them. The "expand during S2" placeholders in Consequences below were
partially filled by the S2 build; the APIM MCP limitations they anticipate are
recorded in ADR-006 (PRM placement) and COMPATIBILITY.md.

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