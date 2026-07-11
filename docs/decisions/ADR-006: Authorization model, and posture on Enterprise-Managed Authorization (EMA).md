# ADR-006: Authorization model, and posture on Enterprise-Managed Authorization (EMA)

Status: Proposed
Date: 2026-07-08

## Context

Two authorization worlds exist for MCP as of mid-2026:

1. Standard MCP authorization (OAuth 2.1): the server is an OAuth resource
   server; unauthenticated requests get 401 plus protected resource metadata
   at /.well-known/oauth-protected-resource; clients complete OAuth with
   PKCE against the authorization server. Entra ID supports this via
   Functions/App Service built-in auth, with the constraint that Entra does
   not support Dynamic Client Registration, so clients are pre-registered.
2. EMA (MCP extension, spec stable 2026-06-18): IdP-managed access using
   ID-JAG token exchange; admins authorize servers centrally, users get
   silent connection under conditional access. Okta is the first spec-level
   IdP; native Entra spec-level support is unverified at the time of this
   ADR.

EMA governs WHO may connect to WHICH server. It does not govern what an
agent does once connected; rate, quota, tool-call content, and audit remain
gateway responsibilities. The two mechanisms are complementary, not
competing.

## Decision

- v1 implements standard OAuth 2.1 authorization with Entra ID: 401 plus
  PRM on the server, validate-azure-ad-token at the gateway, audience
  validation at both layers, OBO (never token passthrough) for downstream
  calls.
- EMA is NOT implemented in v1. Adoption trigger: native Entra spec-level
  EMA support verified in Microsoft documentation, or acceptance of an Okta
  dev-tenant dependency for a deep-dive scenario.

## Alternatives considered

- Implement EMA now against Okta: rejected for v1; adds a non-Azure IdP
  dependency and preview churn to the critical path.
- Key-based auth for demo simplicity: rejected; contradicts the repo's
  purpose. (A loudly-labelled insecure-demo toggle may be added only if
  quickstart friction proves prohibitive.)

## Consequences

Quickstart requires client pre-registration (no DCR); documented in the
README. Re-check the EMA adoption trigger at each phase boundary and record
the check in COMPATIBILITY.md.

## References

- MCP EMA announcement: blog.modelcontextprotocol.io/posts/enterprise-managed-auth/
- To add: Microsoft Learn links during S1/S2 implementation.