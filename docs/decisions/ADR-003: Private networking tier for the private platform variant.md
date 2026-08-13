# ADR-003: Private networking tier for the private platform variant

Status: Proposed for the FULL private platform (S4, still gated); PARTIALLY
proven for the narrower epic 108 child (b) slice as of 2026-08-13 (see
Amendment below)
Date: 2026-07-08
Amended: 2026-08-13 (epic 108 child (b), issue #110; see ADR-010)

## Amendment, 2026-08-13

This ADR originally scoped Standard v2 to the full private platform variant:
inbound private endpoint AND outbound VNet integration, public network
access disabled end to end (S4, gated, still out of scope). The AGENTS.md
GOVERNANCE scope carve-out added the same day narrows what actually enters
v1: a virtual network, an AKS internal ingress gateway, APIM Standard v2
OUTBOUND VNet integration only, and private DNS for the backend if a later
child needs it. It explicitly does NOT open S4: APIM's own gateway host
stays publicly reachable, and APIM gets no inbound private endpoint.

Issue #110 (ADR-010) implements that narrower slice: `apim-gateway`'s
`virtual_network_type` variable accepts `None` (public-demo) or `External`
(private-backend, outbound-only) -- never `Internal`, which is classic VNet
injection and is both out of scope here and, per live evidence from an open
upstream provider issue (azurerm#30296), rejected outright on Standard v2
regardless. The Decision below (Standard v2 over Premium v2 or Developer
classic) is UNCHANGED and now partially validated: outbound integration on
Standard v2 is real Terraform in this repo (not yet live-proven; see
ADR-010 Consequences), while the inbound-private-endpoint half of this
ADR's original scope remains exactly as Proposed as it was before this
amendment.

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