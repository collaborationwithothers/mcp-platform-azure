# ADR-004: Observability design

Status: Proposed (implementation is v1.2, partial wiring in v1)
Date: 2026-07-08

## Context

The platform must answer: which tenant called which tool, how often, with
what outcome and latency, and alert on abuse or saturation. APIM MCP has a
documented constraint: with global diagnostic logging enabled, frontend
response payload byte logging must be 0 or MCP servers malfunction.

## Decision (provisional)

APIM diagnostics to Log Analytics with subscription (tenant) and operation
(tool) dimensions; App Insights on the Function app with correlation to APIM;
an Azure Monitor workbook and alert rules shipped as Terraform in
/infra/terraform/modules/observability. Dashboards show live synthetic demo
traffic only, labelled as such.

## Alternatives considered

To document during v1.2 (e.g. APIM built-in analytics only; third-party
LLM observability tooling).

## Consequences

To expand during v1.2. Payload logging constraint is enforced in Terraform,
not left to portal configuration.

## References

To add during implementation.