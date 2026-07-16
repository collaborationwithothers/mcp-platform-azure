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

## PRM discovery and placement

Added 2026-07-12 recording the reasoning from the S2 gateway modules
(ticket 3, PR #16). This section refines the "401 plus PRM" mechanic in the
Decision above; it does not change the decision.

### The mechanic

Under standard MCP authorization, an unauthenticated request to the MCP
endpoint returns 401 with a `WWW-Authenticate: Bearer resource_metadata="..."`
header. The `resource_metadata` value points the client at the protected
resource metadata (PRM) document, an RFC 9728 document served at the
well-known path `/.well-known/oauth-protected-resource`. The client reads
that document to discover the authorization server and complete OAuth.

In this platform the two halves sit in different layers. The MCP server's
gateway policy (apim-mcp-server) owns the 401 and the `WWW-Authenticate`
challenge; the challenge points at a single PRM document served by the
gateway (apim-gateway) at the gateway root.

### Decision: serve the PRM at the gateway root

The PRM document is served at the gateway root,
`https://<gateway>/.well-known/oauth-protected-resource`, not under any
per-server API subpath.

Driver: current MCP clients resolve the well-known document against the root
authority (host) and do not look under path suffixes. Serving the document
anywhere but the gateway root would leave it undiscovered by those clients.
This is the client behaviour the v1 spec targets (user story 5: the client
resolves the PRM against the root host as current clients require).

Placement: the document is owned by the gateway module, not the server
module, because the gateway root is a one-per-gateway location, so there is
exactly one root PRM document per gateway. apim-mcp-server can be
instantiated more than once against a single gateway (several MCP servers
behind one APIM), so it cannot own a per-gateway singleton without
colliding on the root path when instantiated twice. The singleton belongs
to the layer whose cardinality it shares. The general principle is recorded
in docs/tradeoffs.md; only the document's contents (resource identifier,
authorization server URL, scopes) describe a specific server, and those
flow into the gateway as inputs.

### Observed platform deviation (issue 9, 2026-07-16)

The decision above stands, but the deployed APIM `type=mcp` runtime does not let
the policy own the challenge URL. Recorded here from the issue-9 live trace so the
gap is not rediscovered.

An APIM gateway trace of the no-token request (stamp apim-mcp-tracer-42fa1c27,
listDebugCredentials/listTrace, trace f07bae7f) proves the apim-mcp-server policy
emits the gateway-ROOT `resource_metadata` and return-response sends that root
value "to the caller in full" - yet the client receives a PATH-SCOPED value,
`https://<gateway>/<server_path>/.well-known/oauth-protected-resource`. So the
type=mcp runtime rewrites `resource_metadata` downstream of the policy pipeline,
with no policy hook to override it. That path-appended shape matches neither the
MCP authorization spec (root) nor RFC 9728 section 3.1 (insert-before-path), and
Microsoft Learn documents no native APIM MCP challenge at all (azure-docs-verifier,
2026-07-16; COMPATIBILITY.md). The rewritten path-scoped location does not serve a
document (the per-server MCP API swallows it and returns 401); the gateway-root PRM
document decided above is still served and valid.

Posture taken (issue 9 Exit 2): do not adopt the non-spec path-scoped shape into
the design or serve a document there. The root PRM document continues to be served;
the discovery assertion asserts the OBSERVED rewritten value explicitly as a
platform observation, so the gate flags it if a future APIM release changes the
behaviour. The McpTestClient session and tool contracts pass regardless (they use
client credentials, not the discovery dance), so the rewrite does not break the
tokened auth flow; interactive client discovery (which does follow the challenge)
is to be confirmed against the running stamp and recorded in docs/demos. This
weakens the "clients resolve at root" driver only for clients that follow the
challenge URL literally: for them, neither the root document nor the (non-serving)
path-scoped URL is what a strict RFC 9728 construction would build. Revisit the
placement decision if that interactive confirmation fails.

### Growth paths

The single-root-document form serves exactly one MCP server's metadata per
gateway. Two documented ways to carry more than one server on one gateway,
neither built in v1:

1. Path-suffixed PRM router: adopt the RFC 9728 path-suffixed form, where
   metadata is scoped per resource path rather than one gateway-wide
   document. The root API becomes one operation per server path instead of a
   single operation. Trade-off: lets one gateway carry distinct PRM
   documents for multiple servers, but depends on MCP clients resolving
   path-suffixed well-known locations, which current clients do not do (the
   driver above). Blocked on client support.
2. Hostname-per-server: give each MCP server its own gateway hostname, so
   each server presents its own root authority and therefore its own root
   PRM document under the single-root form. Trade-off: preserves per-server
   root documents without needing client support for path suffixes, at the
   cost of a hostname (and its certificate) plus the associated
   configuration per server.

### Trigger

Re-test MCP client well-known resolution before v1.1, or before adding any
second MCP server to a single gateway, whichever comes first. The re-test
decides whether either growth path is needed yet: if clients still resolve
only against the root authority, a second server needs hostname-per-server
(or stays on its own gateway); if clients have gained path-suffix support,
the path-suffixed router becomes available.

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