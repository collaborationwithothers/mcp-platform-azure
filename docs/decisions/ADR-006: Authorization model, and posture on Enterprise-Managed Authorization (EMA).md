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