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

### What the live interactive trace showed (issue 9): the evidence chronology

The root-placement decision above was made on the client-behaviour evidence
available at design time. Issue 9's live gate and a real interactive client (VS
Code 1.128.1) then exercised discovery end to end. The sequence matters and is
recorded AS a sequence, because each step changed the design and the final
boundary only became visible at the last one. Do not flatten this into a tidy
after-the-fact rationale; the order of evidence is the argument.

1. Designed for root. The decision above served the PRM only at the gateway root,
   `/.well-known/oauth-protected-resource`, on the understanding that current MCP
   clients resolve the well-known document against the root authority.

2. The platform emits a path-scoped challenge. An APIM gateway trace of the
   no-token request (stamp apim-mcp-tracer-42fa1c27, listDebugCredentials/
   listTrace, trace f07bae7f) proved the apim-mcp-server policy emits the
   gateway-ROOT `resource_metadata` and return-response sends that root value "to
   the caller in full" - yet the client receives a PATH-SCOPED value,
   `https://<gateway>/<server_path>/.well-known/oauth-protected-resource`. The
   deployed `type=mcp` runtime rewrites `resource_metadata` downstream of the
   policy pipeline, with no policy hook to override it. That shape matches neither
   the MCP spec (root) nor RFC 9728 s3.1 (insert-before-path); Learn documents no
   native APIM MCP challenge (azure-docs-verifier, 2026-07-16; COMPATIBILITY.md).

3. The client walks all three candidate forms. VS Code's MCP trace (2026-07-18)
   fetched, in order: the challenge's path-scoped-suffix URL (401, no document),
   the RFC 9728 s3.1 insert-before-path URL (404), and the bare root (200) - then
   reported "failed to fetch resource metadata from all attempted URLs" DESPITE
   the root 200. So the client got a document and rejected it.

4. Resource matching is enforced, on two axes:
   - Content. The root document's `resource` was the Entra App ID URI
     (`api://<server-app>`); RFC 9728 s3.3 requires `resource` to equal the MCP
     SERVER URL the client connects to. Fix: set `prm.resource` to the server URL.
     This does NOT change the token audience - `scopes_supported` still carries
     `api://<server-app>/user_impersonation`, and Entra derives the token `aud`
     from the scope's App ID URI, not from `resource` (corroborated by Microsoft's
     Easy Auth PRM feature, which sets `resource` to the bare site URL while
     `scopes_supported` carries the App-ID-URI scope; azure-docs-verifier
     2026-07-18).
   - Location. Even with `resource` fixed, the client still rejected the bare-root
     document, because for a path-bearing resource the metadata must be served at
     the insert-before-path location (the s3.1 URL that 404'd at step 3). Fix:
     serve the SAME document at `/.well-known/oauth-protected-resource<server-path>`
     as well (apim-gateway `prm_well_known_operation_pathed`).
   With both fixes, VS Code ACCEPTED the PRM, discovered Entra as the authorization
   server, and fetched Entra's OpenID configuration. Discovery works.

5. Entra's RFC 8707 enforcement locates the real boundary. At the token request
   the client sends Entra a `resource` indicator (= the server URL) alongside the
   `api://` scope, and Entra rejects it: `AADSTS9010010: The resource parameter
   provided in the request doesn't match with the requested scopes`. It cannot be
   reconciled on this hostname: `https://<host>.azure-api.net/...` cannot be
   registered as an Entra Application ID URI (only `api://`, `*.onmicrosoft.com`,
   or a verified custom domain qualify - azure-docs-verifier 2026-07-18). Microsoft's
   own Easy Auth MCP flow works on a bare `*.azurewebsites.net` host by MEDIATING
   the token exchange through an integrated auth layer; this design points the
   client DIRECTLY at Entra. The exact mechanism Easy Auth uses to avoid
   AADSTS9010010 is undocumented (UNVERIFIABLE).

### Decision and posture (issue 9)

- Keep the discovery fixes (`prm.resource` = the MCP server URL; the path-inserted
  well-known operation). They make the gateway RFC 9728-conformant and carry a
  spec client all the way through discovery to the token endpoint. The gate's
  discovery assertions check both the `resource` value and that the path-inserted
  location serves the document.
- The gateway-root document is retained (harmless; covers path-less resolution).
- Full interactive sign-in is NOT achievable on the ephemeral `azure-api.net`
  hostname pointing directly at Entra (step 5). It requires either an OAuth-
  mediation layer in APIM (the remote-mcp-apim-oauth-prm / AI-Gateway pattern this
  ADR already cites) or a custom verified domain (so the server URL is a
  registerable App ID URI). This is deferred to v1.1 as a genuine choice between
  the two, not a pre-decided one; the custom-domain option interacts with the v1.1
  private-network variant and belongs in the blueprint revision cycle. See issue
  #42 (gated).
- v1 demo scope: the McpTestClient session plus the discovery chain, which the VS
  Code trace demonstrates step by step. Interactive sign-in lands with the v1.1
  auth work (docs/demos).

This supersedes the interim "assert the observed path-scoped challenge and stop"
posture: the interactive confirmation that posture deferred has now run, discovery
was made genuinely conformant rather than merely asserted, and the real boundary
was located at Entra's token endpoint.

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