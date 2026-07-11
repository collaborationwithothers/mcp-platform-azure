# ADR-005: Cost control and multi-tenant limits

Status: Proposed
Date: 2026-07-08

## Context

Two cost surfaces: the platform's own Azure spend (APIM tier dominates), and
per-tenant consumption control (rate limits, quotas, token metrics) that the
platform enforces on its users. A public reference repo also carries the
operational constraint that nothing should be left running.

## Decision (provisional)

- Ephemeral by default: every scenario is apply, demo, destroy.
- A deployment_profile variable selects "public-demo" (APIM Basic v2) or
  "private" (Standard v2, v1.1) compositions from the same modules.
- Multi-tenancy via APIM products and subscriptions with rate-limit and
  quota policies per tenant; token metrics demonstrated against a mock
  backend to avoid model spend.
- All cost figures in docs are labelled estimates with basis and date; no
  unlabelled numbers.

## Alternatives considered

- Per-tenant APIM instances: rejected for v1; document the threshold at
  which isolation requirements force it.
- Always-on shared demo environment: rejected; cost and drift.

## Consequences

To expand during S2/v1.2.

## References

To add during implementation.