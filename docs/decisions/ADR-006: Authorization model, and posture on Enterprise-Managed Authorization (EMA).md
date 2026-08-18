# ADR-006: Authorization model, and posture on Enterprise-Managed Authorization (EMA)

Status: Superseded by ADR-012 on 2026-08-18. Kept as the historical record of
the v1 authorization investigation and its dated evidence.
Date: 2026-07-08
Accepted: 2026-07-22

## Acceptance (v1 tag, 2026-07-22)

The v1 authorization decision is accepted: standard OAuth 2.1 with Entra ID, 401
plus RFC 9728 PRM on the server, validate-azure-ad-token and audience checks at
gateway and server, OBO (never token passthrough) for delegated downstream calls,
and a trusted-subsystem path for app-only callers. EMA stays unimplemented (its
adoption trigger below is unchanged).

The proof is NOT uniform across the branches, and this note keeps that split
explicit rather than collapsing it into "proven":

- Discovery (401 + PRM, RFC 9728 conformance). Proven live end to end: the
  issue-9 live gate asserts the PRM `resource` value and the path-inserted
  well-known location, and a real VS Code 1.128.1 MCP client walked the discovery
  chain to the Entra token endpoint (2026-07-18 trace; see "What the live
  interactive trace showed"). Interactive SIGN-IN is a known, documented gap
  (the RFC 8707 vs RFC 9728 hostname boundary, AADSTS9010010), deferred to v1.1
  as issue #42 -- discovery works, sign-in on `azure-api.net` does not, and that
  is recorded honestly, not as "auth proven".

- App-only branch (trusted subsystem, issue 45 / PR #50). LIVE-GATE-PROVEN. The
  client-credentials path is a full E2E in the automated gate: token -> APIM ->
  Easy Auth -> branch selection -> Orders.Read app-role check -> server-identity
  downstream call -> response, plus the negative assertion for a caller without
  the app role, plus the downstream assignment-required issuance gate for the
  role-less case (issue 53). Green on run 29892332176 (2026-07-22).

- Delegated OBO branch. Happy path is PROVEN BY UNIT TESTS PLUS A MANUAL RUNBOOK,
  NOT BY CI. The automated live gate covers only the negative test
  (audience-mismatch rejection, PR #44); it cannot mint a genuine delegated
  user token non-interactively, so the positive OBO round-trip is validated by a
  human against the live-test environment (docs/runbooks/obo-app-registrations.md;
  docs/demos/obo-happy-path.md, run 2026-07-22) and by unit tests, not by the
  gate. The 2026-07-22 matched-pair A/B additionally established the downstream
  assignment-required gate on the delegated path for non-admins (Global Admins
  bypass it -- see the issue-53 section). This distinction is load-bearing: do
  not restate the delegated happy path as gate-proven.

Still open, and NOT part of this acceptance: native Entra spec-level EMA
(unimplemented, trigger below); the Entra Agent ID -> second-OBO-hop chain
(documented-compatible but unmeasured here, see the 2026-07-19 freshness note);
interactive sign-in on the ephemeral hostname (issue #42).

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

## Reference diagrams (identity flows and request outcomes)

These diagrams depict v1.0.0 as deployed. They illustrate the decision above and
the sections that follow; they do not add or change any decision. Proof status
differs by branch and is stated in the Acceptance note above, not restated in the
captions as if uniform.

### App-only branch (trusted subsystem)

![App-only identity flow: a service-principal or agent caller obtains a
client-credentials token (audience = MCP server, app role Orders.Read), calls
get_order_status through API Management and Easy Auth; the server checks the
Orders.Read role, then acquires its own downstream token and calls the Orders API
as the server identity. No downstream call if the role is absent.](../diagrams/identity-app-only.drawio.svg)

The caller has no user context, so the server calls the downstream as ITSELF
(AcquireTokenForClient, `/.default`), not on the caller's behalf. Authorization is
a fail-closed `Orders.Read` app-role check at the MCP layer: absent role gives a
deterministic tool-level 403 and no downstream call. The downstream trusts the
server identity, not the original agent. This branch is live-gate-proven
(Acceptance, app-only branch).

### Delegated branch (on-behalf-of)

![Delegated OBO identity flow: a user-context caller's token (scp present) is
presented by the server as an OBO assertion to Entra, which returns a
downstream-audience token; the server calls the Orders API with that token. The
caller's original token is never forwarded downstream.](../diagrams/identity-obo.drawio.svg)

The server exchanges the caller's inbound user token for a NEW downstream-audience
token via OBO; the caller's original token is never forwarded to the downstream
(no token passthrough, which is what closes the confused-deputy gap described
below). The OBO happy path is proven by unit tests plus a manual runbook, NOT by
the automated live gate; the gate covers only the audience-mismatch negative test
(Acceptance, delegated branch).

### Request outcomes: HTTP status vs MCP errors

![MCP request outcomes, as drawn: a success returns HTTP 200 with a tool result;
failures appear on the three surfaces this diagram depicts - a transport HTTP 401
(missing/invalid token), an HTTP 200 JSON-RPC protocol error (unknown tool/bad
params), and an HTTP 200 tool result with isError=true (e.g. missing
Orders.Read). It does not depict the gateway-issued surface described below,
which docs/mcp-request-flow.md enumerates; the takeaway box says so and names
its three instances. HTTP 200 here is this deployment's inferred-and-observed
wire shape, not an MCP mandate.](../diagrams/mcp-request-outcomes.drawio.svg)

**Scope of the diagram above.** It depicts the three tiers this section
describes, as deployed at tag v1.0.0, and its claim that only tier 1 changes the
HTTP status is true *within those three tiers*. It is not a complete enumeration
of failure surfaces, and must not be read as one: issues 17, 18 and 88 each added
a rejection issued by API Management itself, inside the server-scope policy's
`<inbound>`, before the request reaches the MCP runtime. Two of those three
change the HTTP status. `docs/mcp-request-flow.md` enumerates all three and is
the canonical list; the diagram it embeds,
`docs/diagrams/per-tool-deny-path.drawio.svg`, draws the issue-18 and issue-88
instances but deliberately starts after the issue-17 403 has passed, so it is
not a complete picture of that surface either. The takeaway box inside the
diagram above says the same, so the qualifier travels with the picture rather
than living only in this paragraph.

The three tiers below are organised by which layer produced the failure. A
caller sees them plus a fourth producer, the gateway itself:

- **Tiers 1 to 3** (this section) are the transport, the MCP runtime, and the
  tool. Within these three, only tier 1 changes the HTTP status.
- **The gateway-issued surface** is a fourth producer and is NOT enumerated
  here, because its instances arrived with later issues and each has its own
  wire shape: HTTP 403 `insufficient_scope` (per-server entitlement, issue 17),
  HTTP 200 with a JSON-RPC `-32001` error (per-tool authorization, issue 18),
  and HTTP 400 with a JSON-RPC `-32600` error (request-validity id guard,
  issue 88). Two of those three change the HTTP status, so "only tier 1 changes
  the status" holds only within tiers 1 to 3, never across the whole system.
  `docs/mcp-request-flow.md` is the canonical enumeration of all four
  producers; it is deliberately not duplicated here.

A client must inspect the HTTP status, the JSON-RPC `error` object, and
the tool result's `isError` flag independently; "forbidden" can arrive on
several of these surfaces with different wire shapes.

1. Transport (real HTTP 401). API Management (`validate-azure-ad-token`) and the
   Function App's Easy Auth V2 reject a missing, invalid, or wrong-audience token
   before the MCP runtime runs. A request with no `Authorization` header gets an
   immediate 401 from the gateway policy carrying the RFC 9728 PRM challenge
   (`WWW-Authenticate: Bearer resource_metadata="..."`); an invalid or
   wrong-audience token fails validation with a 401 and the gateway `on-error`
   adds the same challenge. This is the only one of tiers 1 to 3 that changes
   the HTTP status; the gateway-issued surface noted above also does, on two of
   its three instances.
   (infra/terraform/modules/apim-mcp-server/policies/mcp-server.xml.)

2. JSON-RPC protocol error (HTTP 200 in this deployment). The request
   authenticated and reached the MCP runtime but was not a valid call. The
   runtime returns a JSON-RPC `error` object. **INFERRED plus OBSERVED:** HTTP
   200 is this deployment's wire shape, not a status mandated by the MCP
   specification. `docs/mcp-request-flow.md` owns the current conditions and
   evidence.

3. Tool execution error (HTTP 200 + `isError` in this deployment). The tool ran
   and returned a result that marks failure. **INFERRED plus OBSERVED:** the HTTP
   status is this deployment's wire shape, not a specification mandate.
   `docs/mcp-request-flow.md` owns the current tool, principal, and exception
   outcomes.

The 403 in tier 3 is an MCP tool error, not an HTTP 403 - which is why the diagram
draws the transport reject and the tool-level `isError` as different colours: they
both read as "forbidden" to a human but are different wire outcomes a client must
handle differently.

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

   Update, issue 17 (2026-08-04): the distinction between path-SUFFIXED and
   path-INSERTED (RFC 9728 s3.1, insert-before-path) is load-bearing here and
   this item's "blocked" verdict applies only to the fully path-suffixed
   router, if it ever differs from the inserted form. The per-server
   path-INSERTED form that the issue-9 work already made spec clients accept
   (VS Code fetched the s3.1 insert-before-path location) is NOT blocked and is
   now ADOPTED for the multi-server case, on RFC 9728's own multi-resource
   grounds - see "Multi-server composition (issue 17)" below. Do not read this
   item as still saying the pathed PRM form is unavailable; the inserted form
   works today and carries the second server.
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

Resolved by issue 17: the re-test was satisfied by INHERITANCE, not a fresh
interactive run. Issue 9's VS Code discovery trace (2026-07-18) already
established that a spec client fetches and accepts the RFC 9728 s3.1
path-inserted location; issue 17's live gate (2026-08-06) then confirmed, at the
raw-HTTP layer, that each server's path-inserted location serves that server's
document (200, resource match). On that basis the second server was added on the
path-INSERTED form rather than hostname-per-server, and the prediction above ("a
second server needs hostname-per-server") is superseded. What was NOT done is a
fresh interactive-client (VS Code / MCP Inspector) discovery run against the
two-server gateway: an actual client following the no-token challenge end to end
is the interactive-discovery work owned by issue #42 (see the no-token-challenge
note in "Multi-server composition (issue 17)" below). See that section for the
full decision.

## Multi-server composition (issue 17)

Added 2026-08-04 recording the multi-server decision from ticket 17 (live-gate
findings appended 2026-08-06): how a second MCP server behind the one gateway
discovers, authenticates, and is isolated. This section refines the PRM
placement and the trusted-subsystem identity mechanics above for the two-server
case; it does not change the v1 Decision. It also resolves the
"Growth paths"/"Trigger" prediction above (the re-test was satisfied by
inheritance from issue 9 plus the issue-17 raw-HTTP gate, landing on
path-inserted, not hostname-per-server; a fresh interactive re-test is #42).

Live-gate honesty note (no-token challenge resolution, NOT closed by #17). The
deployed type=mcp runtime rewrites the no-token 401 challenge to the path-scoped
form `<gateway>/<server_path>/.well-known/oauth-protected-resource` (issue 9;
COMPATIBILITY.md). That URL does NOT itself serve a PRM document -- it routes
into the MCP server API, which has no well-known operation. Working discovery
therefore rests on a spec client using the RFC 9728 s3.1 path-inserted location
(which IS served, GET-200 asserted per server at the gate), NOT on the client
literally following the rewritten no-token challenge. Issue 17 generalises this
issue-9 gap to a second server and PROVES the s3.1 served location for both; it
does not close the literal-no-token-challenge resolution, which needs an
interactive-client trace and belongs to #42. The gate records the no-token
challenge URL's response each run (discovery-assertions.ps1 check 8) so the gap
is visible and any future closure is caught. The on-error path, by contrast, is
fully closed: its emitted value equals the served path-inserted location and is
not rewritten (GET-200 asserted).

### Per-server path-inserted PRM (RFC 9728 s3.1), served at the gateway root

Each server behind the gateway gets its OWN RFC 9728 s3.1 path-inserted PRM
document. The documents are served by an operation-scoped policy on a single
well-known API instantiated once at the gateway root: one API, one operation
per server path, each operation returning the document for its server with
`resource` set to that server's URL and `scopes_supported` carrying only that
server's scope.

This is RFC 9728's OWN multi-resource construction, not a workaround. Path
components exist in the standard precisely so that one host can carry multiple
protected resources, each serving its metadata at a location deterministically
derived from its own resource URL (insert-before-path,
`/.well-known/oauth-protected-resource<server-path>`). The issue-9 work already
proved a spec client (VS Code) fetches and accepts the s3.1 inserted location;
issue 17 generalises the count-guarded single-server pathed operation of v1
(`prm_well_known_operation_pathed`) into a per-server collection of the same
operation shape. Nothing about the client contract changes between one server
and two; only the number of pathed operations does.

### The retained root document is the s3.3 fail-closed guard

The gateway-root PRM document is kept, and it describes the PRIMARY server. This
is deliberately more than the "harmless, covers path-less resolution" role the
issue-9 section gave it. Under RFC 9728 s3.3 resource matching, a client that
falls back to the root document while it is actually targeting a DIFFERENT
server reads a `resource` value (the primary server's URL) that does not equal
the server URL it connected to, sees a resource mismatch, and MUST discard the
document rather than use it.

That asymmetry is a safety property, stated with its mechanism: misrouted
discovery fails CLOSED. A client that lands on the wrong document is rejected by
its own spec-mandated matching check, instead of silently binding to the wrong
resource's advertised authorization server and scope. The root document is a
guard, not a limitation - it turns an off-path discovery into a hard stop.

### Identity: shared registration, per-server scope and role, OR-checked

The two servers share one app registration and therefore one audience (one App
ID URI). Under that single App ID URI, each server has its OWN delegated scope
and its OWN application role. Each server's PRM advertises only that server's
scope in `scopes_supported`, so discovery already narrows a client to the
correct per-server scope before any token is minted.

Authorization is then enforced per server by a policy check that runs AFTER
Entra token validation, expressed as a policy expression with OR semantics
across two claims: the request is admitted if the server's scope appears in the
`scp` claim OR the server's app role appears in the `roles` claim. The OR is
required by the claim shapes: a delegated token carries `scp` and no `roles`, an
app-only token carries `roles` and no `scp`, so a single server must accept
either. It cannot be expressed with `validate-azure-ad-token`'s `required-claims`
block, because that block ANDs its `claim` entries - every listed claim must be
present for validation to succeed, and its `match` attribute selects all/any of
the values WITHIN one named claim, not across two different claim names
(verified against the Microsoft Learn `validate-azure-ad-token` policy reference,
azure-docs-verifier 2026-08-04). So the per-server check is a policy expression
evaluating `scp` OR `roles`, sitting after the standard Entra token validation,
not a second `required-claims` entry.

### Known non-conformance: shared audience (MCP spec audience-binding MUST)

Stated plainly because it is net-new to this ADR and easy to bury: the shared
audience is a KNOWN NON-CONFORMANCE with the MCP authorization spec's
audience-binding MUST (each protected resource should have its own audience so a
token minted for one server is not valid at another). It is not a gap introduced
by issue 17; it is INHERITED from the Entra resource-indicator deadlock this ADR
already documents - Entra ignores the RFC 8707 `resource` parameter and rejects
the pairing on this hostname (`AADSTS9010010`, see "What the live interactive
trace showed", step 5). The second server did not create the deviation; it made
the existing single-audience deviation newly VISIBLE by giving it a second
resource to be wrong about.

This is a documented deviation with an owner, not an omission: audience-per-server
is deferred to issue #42 (the same custom-domain / OAuth-mediation choice that
already owns the sign-in boundary). It must never be phrased as "isolation out of
scope" - isolation is implemented, at scope granularity; it is the audience
BINDING that is deferred, and the deferral has a ticket.

### Isolation is per-grant, not per-token

The precise, non-overclaiming statement of what this design isolates:
cross-server isolation is enforced at scope granularity within a shared
audience, per grant; audience-per-server is deferred to issue #42.

"Per grant" is the honest qualifier. Because the audience is shared, a client
that has been granted BOTH servers' scopes (or both roles) receives ONE token
whose `aud` is the shared App ID URI and whose `scp`/`roles` carry both servers'
claims, and that single token is valid at both servers. Isolation therefore
holds between clients that were granted different scopes; it does NOT hold at the
token level for a client granted both. Do not read this section as claiming
token-level isolation - a client with both grants is, by construction, admitted
at both servers with one token. The per-server `scp`/`roles` OR check gates on
what was GRANTED, and audience-per-server (issue #42) is what would additionally
gate at the token level.

### Rejected alternative: hostname-per-server

Hostname-per-server (growth-path item 2 above) was rejected for issue 17. Giving
the second server its own gateway hostname would make each server's URL a
candidate registerable App ID URI (a verified custom domain), which is exactly
one half of the deferred issue #42 choice between an OAuth-mediation layer and a
custom verified domain. Adopting it here would pre-decide #42's custom-domain
option as a side effect of a multi-server-composition ticket, and would leave
ADR-006 and the eventual #42 decision reading as one decision made twice, in two
places, possibly inconsistently. Keeping the second server on the shared
hostname with path-inserted PRM keeps the audience-binding question wholly inside
issue #42, where it is owned, rather than resolving it implicitly here.

## OBO exchange: confused deputy, audience validation, and the inbound-token gap (issue 10)

Added 2026-07-18 recording the reasoning from the OBO thickening ticket
(ticket 6, issue 10). This section refines the "OBO (never token
passthrough)" line in the Decision above; it does not change the decision.

### OBO vs token passthrough: the confused-deputy mechanic

Token passthrough (the server forwarding the client's own inbound token,
unchanged, to a downstream API) is forbidden because it creates a confused
deputy: the downstream cannot tell "the server acting on behalf of THIS
specific user, with THIS specific consent" from "the server reusing
whatever token it happened to receive." The inbound token's audience is the
MCP server app, not the downstream; if the downstream trusted it anyway
(no audience check, or a shared audience across services), any caller
holding a valid server-audience token could reach the downstream, without
the downstream ever being party to a consent decision about that caller.

OBO closes this by minting a NEW token: the server presents the inbound
token as a `user_assertion` to Entra's token endpoint, along with its own
credential (docs/runbooks/obo-app-registrations.md, step 3) and a scope on
the downstream (step 2's consent grant), and receives back a token whose
audience is the downstream app, issued only because Entra checked (a) the
inbound token is valid, (b) the server has been granted delegated
permission to call the downstream on this user's behalf, and (c) the
federated credential correctly identifies the server as the confidential
client it claims to be. The downstream never sees the client's original
token at all.

That delegated grant in (b) does not have to come from admin consent
specifically: Microsoft's OBO consent model documents three valid ways it
can exist -- admin consent, per-user combined consent (via
`knownClientApplications` + the `.default` scope), or the downstream
preauthorizing the middle-tier app -- and OBO succeeds as long as SOME
valid grant is present, not an admin-consent event in particular. This repo
does not depend on which: it creates the grant DIRECTLY and idempotently
via `azuread_service_principal_delegated_permission_grant` (all users,
`user_object_id` omitted), which is functionally an admin-consent grant, so
no separate consent step or user prompt is needed at all.

**Audience validation at two layers**, both enforced by Easy Auth
(`auth_settings_v2`), not application code: the server's Function App
validates the inbound token's audience is the server app
(`entra_auth.allowed_audiences`, unchanged since the tracer); the downstream
Orders API's Function App independently validates the OBO-exchanged token's
audience is the downstream app (`downstream_entra_auth.allowed_audiences`,
scoped to ONLY that app). These are two separate Easy Auth configurations on
two separate Function App instances (infra/terraform/scenarios/
s1-entra-mcp-server reuses `mcp-function-host` for both), not one shared
audience list -- which is what makes token passthrough a MEASURED failure
mode rather than an assumed one: a server-audience token presented directly
to the downstream is rejected by the platform's own audience check, before
any of this repo's code runs (the negative test,
tests/integration/obo-passthrough-negative.ps1).

### Testing strategy: the user-context token problem (spec: Testing Decisions knock-on)

The ticket's own "Verified facts" flagged this at issue start: the live
gate's existing non-interactive caller acquires a client-credentials token,
which is app-only (no user), so it cannot drive a real OBO exchange (OBO's
`user_assertion` parameter needs a delegated, user-context token).
azure-docs-verifier confirmed on 2026-07-18 that no GA, non-interactive,
CLAUDE.md-compliant mechanism exists to acquire one in unattended CI:

- ROPC (resource-owner password) is still technically supported but
  Microsoft Learn documents it as discouraged, incompatible with MFA and
  Conditional Access, and it would require storing a real user's password
  as a CI credential -- itself the kind of secret CLAUDE.md forbids.
- Device code flow requires a human to complete an interactive sign-in on a
  second device; it is not headless-automatable by design.
- Every fully non-interactive, GA mechanism (client credentials, managed
  identity, workload identity federation) produces an app-only token, never
  a delegated one.

**Decision and posture:** the OBO happy path (a real delegated token
successfully round-tripping through the downstream) is validated MANUALLY
in the live-test environment -- a human acquires a genuine user token (e.g.
interactive sign-in via VS Code, or `az login` plus `az account
get-access-token` against the server app's scope) and exercises
get_order_status, with the result recorded in docs/demos. This mirrors the
precedent issue 9 already set for interactive discovery (see "What the live
interactive trace showed" above: full interactive validation deferred to a
human-run trace, not force-fitted into the automated gate). The AUTOMATED
live gate covers only the negative test (audience-mismatch rejection),
which needs no user context at all -- the existing client-credentials token
is sufficient to prove passthrough is closed.

### OBO exchange: the inbound-token gap and its correction

Ticket 10 was designed on the assumption that `GetOrderStatus.Run` (an
Azure Functions MCP extension `McpToolTrigger`-bound function) could read
the caller's inbound bearer token and use it as OBO's `user_assertion`.
The sequence below matters and is recorded AS a sequence, per this ADR's
own established convention (see "What the live interactive trace showed,
issue 9" above): the order of evidence is the argument, and a wrong
intermediate step is not flattened out of the record just because a later
step corrected it.

1. **First verification pass concluded REFUTED, three independent ways.**
   azure-docs-verifier's first 2026-07-18 pass checked `ToolInvocationContext`
   (the type `[McpToolTrigger]`-bound functions receive) against the
   extension's own GitHub source and Microsoft Learn, and reported: the
   type's documented surface exposes only `Name`, `Arguments`, `SessionId`,
   `Transport`; a single Azure Functions method may declare exactly one
   trigger attribute, so `McpToolTrigger` cannot be paired with `HttpTrigger`
   to reach `HttpRequestData`; and the isolated-worker ASP.NET Core
   integration hosting model does not expose its middleware pipeline to
   non-HttpTrigger bindings. This shipped in an earlier revision of this
   PR: `GetOrderStatus.Run` served the in-memory fixture unchanged, with the
   gap documented here, in security.md, and in COMPATIBILITY.md.

2. **The REFUTED conclusion was wrong -- a reviewer caught it.** The
   `Transport` property that step 1 noted but did not further inspect
   is not a dead end: `Microsoft.Azure.Functions.Worker.Extensions.Mcp`
   ships a separate static class, `ToolInvocationContextExtensions`
   (a sibling file to `ToolInvocationContext.cs`, not nested inside it --
   the reason step 1's browse missed it), with
   `TryGetHttpTransport(ToolInvocationContext, out HttpTransport)`, and
   `HttpTransport` (a `Transport` subtype) exposes a `Headers` dictionary.
   This was confirmed directly by reflecting the installed 1.5.1 assembly
   (not a doc page, not training data -- the literal DLL in the NuGet
   cache), then independently re-verified against Microsoft Learn and the
   official `Azure-Samples/remote-mcp-functions-dotnet` sample
   (`HelloToolWithAuth.cs`), which does exactly this for exactly an OBO
   downstream call: reads `X-MS-TOKEN-AAD-ACCESS-TOKEN` first, falls back
   to the raw `Authorization` header, and exchanges it via
   `OnBehalfOfCredential`.

3. **Two caveats the correction carries, both recorded rather than
   asserted as platform guarantees.** First, whether the client's original
   `Authorization` header reaches the app unmodified through Easy Auth is
   sample-derived behaviour (the official sample's fallback path implies
   it), not a stated Microsoft Learn platform contract -- `X-MS-TOKEN-AAD-
   ACCESS-TOKEN` is the documented mechanism, and it requires the token
   store explicitly enabled (COMPATIBILITY.md). Second, `TryGetHttpTransport`
   returns `bool` because the transport can be something other than HTTP:
   the extension exposes two transports (Streamable HTTP at
   `/runtime/webhooks/mcp`, and the deprecated SSE at
   `/runtime/webhooks/mcp/sse`, which relies on an Azure Queue Storage-backed
   session backplane), and there is no host.json setting to pin the
   transport -- it is purely a function of which endpoint URL the client
   connects to, per session. The extension's own type model represents SSE
   invocations as `HttpTransport` too (tagged `Type =
   HttpTransportType.ServerSentEvents`, not a separate non-HTTP class), so
   the specific failure mode "SSE routes through a queue and `Transport`
   becomes non-HTTP" is not supported by the source -- but header
   availability for SSE specifically was not confirmed at runtime either.
   This repo's tracer targets Streamable HTTP only (matching
   apim-mcp-server's `mcpProperties.transportType = streamable` on the
   gateway side); `GetOrderStatus.Run` throws if no token-bearing header is
   found, so an SSE-routed request that lacked headers would fail loudly,
   not silently.

**Decision and posture (issue 10, corrected):** `GetOrderStatus.Run` DOES
call the OBO exchange in its live path. The caller's inbound token is
extracted via `TryGetHttpTransport` -> `HttpTransport.Headers`
(token-store header first, `Authorization` fallback), exchanged via
`McpTools.Downstream.DownstreamOrdersClient` /
`ManagedIdentityOboTokenAcquirer` (the certificateless federated-credential
confidential client), and the downstream's typed response is mapped onto
get_order_status's frozen contract. The federated identity credential and
the OBO consent grant are Terraform-managed
(`infra/terraform/scenarios/s1-entra-mcp-server/main.tf`, the `azuread`
provider), re-created every ephemeral run rather than a one-time manual
step, because the Function App's system-assigned identity's principal id
differs every apply.

This does NOT resolve the separate "Testing strategy" problem above: CI
still cannot acquire a genuine delegated user token, so the OBO HAPPY PATH
still cannot be exercised by the automated live gate -- that is a different
constraint (no non-interactive delegated-token mechanism exists in Entra)
from the one this section corrects (whether the header is reachable at
all). The automated gate continues to cover only the negative test.

### Trigger

Re-verify header availability for the SSE transport specifically (step 3's
open caveat) if a future issue needs SSE support, or if Microsoft Learn or
the Functions MCP extension's samples publish guidance either way. Re-verify
the `Authorization`-header-passthrough behaviour (also step 3) against
Microsoft Learn if a documented statement appears, since it is currently
sample-derived, not a stated platform contract.

## Identity-mode branching and fail-closed header trust (issue 10, amended)

Added 2026-07-18 (same day, amending the correction above). The "inbound-token
gap" section concluded `GetOrderStatus.Run` calls the OBO exchange in its live
path. That is now refined: `Run` calls OBO **only for delegated callers**, and
the decision is recorded here AS the next step in the chronology, not flattened
into the prior section.

### Why branch at all

The live gate's non-interactive caller holds a **client-credentials** token,
which is app-only (a `roles` app-role claim, no `scp` scope claim, no user).
That token cannot drive an OBO exchange -- OBO's `user_assertion` needs a
delegated, user-context token. An always-OBO `Run` would therefore FAIL the
gate's own happy path the first time it ran live (it never had, per the PR).
So the tool must distinguish the two caller shapes:

- **Delegated (`scp` present):** a real user context -> source from the
  downstream via OBO (the sanctioned path above).
- **App-context (`roles` present, no `scp`):** an app-only caller with no user
  to act for -> serve from the in-memory fixture, a **documented interim**
  until the workload-identity hardening issue. This is honestly a weaker
  posture (see the backstop asymmetry below), chosen because the alternative
  (an app-only token forced through a user-context flow) does not exist.

The mode decision lives in one testable component
(`McpTools.Identity.IdentityModeResolver`), decided from the Easy-Auth-injected
`X-MS-CLIENT-PRINCIPAL` claims, not inline in the tool.

### The header trust chain, and why the code does not validate signatures

The server deliberately does **not** perform full in-code JWT signature
validation. It relies on a layered chain and asserts (rather than re-checks)
the upstream parts: APIM validates the token at the gateway; Easy Auth
validates it again on the Function App and, when enabled, **strips
client-supplied `X-MS-*` headers before injecting its own** decoded
`X-MS-CLIENT-PRINCIPAL`; the code then does claims-based authorization on that
trusted header. Two fail-closed checks make this sound:

- **Startup (`BuiltInAuthGuard`):** in any non-`Development` environment, refuse
  to start unless a built-in-auth signal is present (`WEBSITE_AUTH_ENABLED`, or
  the documented v2 `WEBSITE_AUTH_V2_CONFIG_JSON`). Without this, a host with
  Easy Auth accidentally off would trust a header a caller could forge.
- **Per-request:** reject any request whose `X-MS-CLIENT-PRINCIPAL` is missing
  or malformed. This is **only sound in combination with the startup check** --
  the header is trustworthy only because enabled Easy Auth strips forged
  copies, which the startup check guarantees.

**Backstop asymmetry, stated plainly.** The delegated branch has an
Entra-exchange backstop: a forged/invalid assertion is rejected at the OBO
token endpoint, so a bad delegated request fails at the exchange. The
app-context branch has **no** such backstop -- it serves the fixture on the
strength of the `roles` claim alone, resting entirely on the trust chain. That
asymmetry is a further reason the app-context/fixture path is an interim.

Note on the delegated-token strings: the exact `scp`/`roles` claim-type strings
inside `X-MS-CLIENT-PRINCIPAL` are UNVERIFIABLE on Microsoft Learn (Easy Auth
applies a claims mapping), so the resolver matches both the short and the
schema-URI forms and the actual form is confirmed by a live trace, not asserted
(COMPATIBILITY.md; docs/security.md).

## Workload identity hardening: app roles and trusted subsystem (issue 45)

Added 2026-07-19. This supersedes the app-context fixture interim above. The
delegated branch remains unchanged.

An app-only token has no user assertion and cannot drive OBO. The replacement
is a trusted-subsystem path:

1. The MCP server app registration exposes the application-only role
   `Orders.Read`. The tool checks the Easy-Auth-injected `roles` claim and
   returns a deterministic 403 tool error when the required role is absent.
   Built-in auth authenticates tokens but does not validate app roles for
   application code, so this check belongs at the MCP layer.
2. After authorization, the MCP server acquires a downstream app-only token by
   calling MSAL.NET `AcquireTokenForClient` for the downstream resource's
   `/.default` scope. It reuses the existing confidential client credential:
   the Function App's managed identity federated to the server app registration.
3. The downstream app registration also exposes `Orders.Read`, assigned only
   to the MCP server service principal by Terraform. The downstream Function
   App's built-in-auth `allowedApplications` policy independently allowlists the
   MCP server app client id. The downstream therefore trusts the server identity,
   not the original agent.
4. The original caller's `azp`/`appid` and `oid` are written to structured logs
   and propagated as `X-Mcp-Caller-Azp` / `X-Mcp-Caller-Oid`. They are
   audit-grade correlation, not authorization-grade identity.

Trade-off: downstream sees one identity for every app-only agent. Per-agent
policy exists only at the MCP layer, so compromise or misauthorization there
has a wider blast radius than delegated OBO. The app-only branch also has no
inbound Entra-exchange backstop. This is why the fail-closed chain is explicit:
APIM and built-in auth validate the inbound token, tool code requires
`Orders.Read`, and downstream built-in auth accepts only the MCP server app.

Multi-tenancy remains a seam, not an implementation in v1. APIM product and
subscription membership is not bound to Entra application-role assignment by
this decision. A future tenant-aware design must align those two control planes
explicitly; it must not infer tenancy from the audit-only caller headers.

### Entra Agent ID freshness note, checked 2026-07-19

The broad question "does Entra Agent ID support delegated OBO" is now answered:
Microsoft Learn documents that agent identity blueprints support standard OAuth
2.0 OBO and that the resulting resource token carries user context (`idtyp =
user`, `scp`, user `oid`) plus the agent identity in `azp`/`appid`. See
[Agent OAuth flows: On behalf of flow](https://learn.microsoft.com/entra/agent-id/agent-on-behalf-of-oauth-flow)
and [Token claims reference for agents](https://learn.microsoft.com/entra/agent-id/agent-token-claims).

The narrower chain relevant here remains unverified: Microsoft Learn does not
explicitly show an Agent ID resource token received by this MCP server being
used as the assertion for a second OBO exchange to the Orders API. Standard OBO
accepts a user-context access token whose audience is the middle-tier API, so
the documented token shape is compatible in principle, but that second hop has
not been measured in this repository. If it is verified later, it fits the
existing delegated branch without changing the `get_order_status` contract.

### Downstream assignment-required issuance gate (issue 53)

Added 2026-07-21. This hardens the issue-45 trusted-subsystem path above; it
does not change its decision. Follow-up from the C2 sign-off during governance
review of PR #50: the sign-off accepted the v1 trusted-subsystem posture on the
explicit condition recorded here.

**The gap this closes.** As shipped in issue 45, the downstream `Orders.Read`
app-role assignment (`azuread_app_role_assignment`, main.tf) was only a *grant*.
The downstream enterprise application did not require assignment, so removing the
grant would NOT have failed the app-only call closed: Entra would still mint an
app-only downstream token for the MCP server, and the downstream's request-time
`allowedApplications` check would still admit it on client-id alone. The grant
was, in isolation, cosmetic. The whole point of a trusted-subsystem role is that
losing the role loses the access; that only holds if issuance itself is gated.

**The gate.** Setting "Assignment required?" = Yes (`appRoleAssignmentRequired`)
on the downstream Orders API turns the bare grant into an enforced issuance-time
gate: Entra refuses to issue the app-only downstream token to any service
principal that does not hold an app-role assignment on the downstream. Verified
against Microsoft Learn (azure-docs-verifier 2026-07-21): the client-credentials
flow doc states enabling assignment requirements "will block ... applications
without assigned roles from being able to get a token," and the Graph
`servicePrincipal.appRoleAssignmentRequired` property gates whether "apps can get
tokens." With the gate on, removing the MCP server's assignment now fails the
app-only call closed at token issuance, before any downstream code runs.

**Object placement, and why the portal toggle is the low-churn path.**
`appRoleAssignmentRequired` is a property of the downstream *service principal*
(the Enterprise Application object: Enterprise applications > Properties >
"Assignment required?"), NOT of the app registration (verifier 2026-07-21;
confirmed on the Graph `servicePrincipal` type, distinct from the `application`
type). In this repo the downstream service principal is a Terraform *data*
source (`data.azuread_service_principal.downstream`, main.tf), created out of
band with the app registration (docs/runbooks/obo-app-registrations.md). Managing
the toggle in Terraform would mean converting that data source into a managed
`azuread_service_principal` resource, taking ownership of an out-of-band object
the composition otherwise only reads. The gate is set once and does not rotate
per run, so the churn of that ownership change buys nothing here; the portal
toggle, documented in the runbook, is the chosen low-churn path for v1.

**Complement to `allowed_applications`, not a replacement (two enforcement
points).** These are two distinct checks at two distinct moments (verifier
2026-07-21, VERIFIED):

- `appRoleAssignmentRequired` is enforced by Entra at *token issuance time*,
  before the token exists. It answers "may this principal get a downstream token
  at all."
- The downstream Function App's built-in-auth `allowedApplications` / `azp`
  check is enforced by the *resource*, at *request time*, on a token that has
  already been issued. It answers "is the caller on this API's allow-list."

They are defense in depth: the issuance gate keeps a role-less principal from
ever holding a downstream token; the request-time allow-list keeps a
wrong-but-role-holding principal from being admitted. Neither subsumes the other,
and this issue keeps both.

**This does NOT touch the server-side role-less negative test.** That test
targets the *server* app registration, where assignment must stay NOT required so
a valid server-audience token *without* `Orders.Read` can still be issued and
reach the MCP layer to receive the deterministic 403 (the MCP-layer authorization
arm; docs/runbooks/entra-app-registrations.md section 3). This gate is on the
*downstream* app only. App-only positive and role-less negative arms are
unaffected by design.

**Delegated (OBO) consequence.** Assignment-required applies to every principal
requesting a token for the gated resource, including the signed-in user on the
delegated/OBO path -- not only app-only callers. The general delegated rule is
documented: a user not assigned to an assignment-required app (directly or via a
group) is refused with `AADSTS50105` ("The signed in user isn't assigned to a
role for the ... app"; verifier 2026-07-21, VERIFIED for interactive sign-in).
Honest limit: Microsoft Learn does NOT explicitly state that this check is
evaluated at the OBO *token-B exchange* step specifically (the OBO flow article
documents only Conditional Access / `AADSTS50079` for that step); whether the
downstream's assignment requirement fires at the OBO hop, versus only at the
user's original sign-in to the client app, is unconfirmed by Learn (verifier
2026-07-21, PARTIAL). So the mitigation is applied AND the enforcement point is
confirmed live rather than asserted: the delegated test user (or a group) is
assigned to the downstream app, and the manual delegated happy path is re-run
after the toggle (docs/demos/obo-happy-path.md "Run 2026-07-22"; ties to PR #50
finding B2). Live-confirmed 2026-07-22 (run 29892332176) by a matched pair on the
SAME non-admin user, differing only by the downstream app assignment: unassigned
-> the delegated call FAILS, assigned -> it succeeds. The failure's captured
server exception pins the enforcement point exactly -- AADSTS50105 ("block users
unless they are specifically granted assigned access") thrown at MSAL's
`OnBehalfOfRequest.ExecuteAsync`, i.e. AT the OBO token exchange, not at the user's
original sign-in. Consent is tenant-wide and identical for both arms, and `Run`
has no delegated->app-only fallback and does not catch the OBO exchange, so the
assignment is the isolated cause. This closes the Learn-PARTIAL in practice: Learn
does not document the OBO step being gated, but it is now measured, for non-admin
principals (Global Administrators bypass the gate -- see the threat-model note
below). This does not touch the app-only gate above, which remains the
load-bearing, doc-VERIFIED claim. Group-based assignment is a valid way to
satisfy the requirement but needs Entra ID P1/P2 and does not follow nested
groups (verifier 2026-07-21); direct user assignment is used for the single demo
user.

**Threat-model note: Global Administrator bypass.** Global Administrators bypass
`appRoleAssignmentRequired` entirely (verifier 2026-07-21). The trusted-subsystem
principals here (the MCP server's managed identity, the delegated demo user) are
not Global Administrators, so the gate binds them; but a future design must not
assume the gate constrains a GA-held or GA-impersonating identity. This is not
hypothetical: on 2026-07-22 an unassigned Global Administrator's delegated call
succeeded through OBO (the documented bypass) while the same-tenant non-admin
user's did not. Operationally it means any manual negative test of this gate MUST
use a non-admin sandbox user, or the bypass masks the result
(docs/demos/obo-happy-path.md "Run 2026-07-22";
docs/runbooks/obo-app-registrations.md).

**Rejected alternative: leave assignment-required off (grant stays cosmetic).**
Rejected. It is the pre-issue-53 state, and it is exactly what the C2 sign-off
declined to accept as the standing v1 posture: a downstream role that can be
revoked without changing what the app-only path can reach is not an authorization
control, only a label. Enabling the gate is what lets this repo claim the
downstream access is role-gated rather than allow-list-gated alone.

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
