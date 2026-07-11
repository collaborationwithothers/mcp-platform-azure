# ADR-003: Private networking tier for the private platform variant

Status: Proposed (implementation is v1.1, not v1)
Date: 2026-07-08

## Context

The private variant requires: inbound access to APIM only via private
endpoint, outbound from APIM to backends over the VNet, public network
access disabled end to end, private DNS. APIM tiers differ materially here
and in cost.

## Decision (provisional)

APIM Standard v2: inbound private endpoint plus outbound VNet integration
with public network access disabled gives end-to-end isolation without
Premium pricing. To be validated during v1.1 implementation.

## Alternatives considered

- Premium v2 (full VNet injection): rejected on cost for a reference
  implementation; document the injection-only requirements that would force
  it.
- Developer classic (VNet injection, cheap, no SLA): documented as budget
  experimentation option only; wrong signal for a reference architecture and
  slow provisioning.
- Known risk to verify at build time: azurerm provider gaps configuring the
  Standard v2 private endpoint surface were reported in 2025 (provider issue
  #30296); azapi fallback if still open.

## Consequences

To expand during v1.1.

## References

To add during implementation.