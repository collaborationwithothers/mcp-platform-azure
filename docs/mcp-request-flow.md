# MCP request flow: session lifecycle and header propagation

How a request travels through the v1.0.0 platform, from the MCP client's
`initialize` handshake to a `tools/call` result, and which HTTP headers each hop
adds, strips, or reads. Two audiences: the session lifecycle is the protocol
depth; the header table is the operator's debugging reference.

Scope and honesty. This page describes the Streamable HTTP transport at tag
v1.0.0. Where Microsoft Learn does not document a behaviour, that is stated as a
gap, not filled by inference. The session-state maintenance mechanism for
Streamable HTTP is one such gap (see below).

The deployed request path and the diagram below still use the Functions host.
Issue #147 also implements an alongside ASP.NET Core host with the same three
tools, but does not deploy it or change gateway routing. The host comparison
below describes its application boundary without presenting it as live proof.

## Session lifecycle

![MCP session lifecycle: an MCP client performs initialize (protocol and
capability negotiation), notifications/initialized, tools/list, and tools/call
against the Functions-hosted MCP server through API Management passthrough over
Streamable HTTP; server-side session-state maintenance is marked as an
undocumented boundary.](diagrams/mcp-session-lifecycle.drawio.svg)

The repo's own client (`src/McpTestClient/Program.cs`, using the official
ModelContextProtocol C# SDK) drives a real, multi-request session:

1. Connect and `initialize`. `McpClient.CreateAsync` opens the Streamable HTTP
   transport and performs the `initialize` handshake as one operation:
   protocol-version and capability negotiation. The client asserts a negotiated
   protocol version and live server capabilities as proof the session is up.
2. `notifications/initialized`. The client signals readiness.
3. `tools/list`. The client discovers `get_order_status`, `get_service_info`,
   and `get_access_guidance`.
4. `tools/call`. The client invokes the tool (known and unknown order ids) and
   reads the `CallToolResult` (`structuredContent`, or a JSON text block).
5. Transport close on dispose.

All requests transit API Management as MCP passthrough; API Management validates
the token (`validate-azure-ad-token`) and forwards the request unchanged.

### How the server maintains session state: an undocumented boundary

Microsoft Learn does NOT document how the Azure Functions MCP extension maintains
Streamable HTTP session state (checked 2026-08-04). What is and is not known:

- Documented: the deprecated SSE transport relies on an Azure Queue Storage
  backplane provided by the default host storage account (`AzureWebJobsStorage`).
- Documented for resource/prompt, source-observed for tool: a `SessionId` is
  exposed on the invocation context the extension hands to your code. Microsoft
  Learn documents it for the resource and prompt triggers (a "Sessions" section);
  the tool trigger page has no equivalent, but `ToolInvocationContext.SessionId`
  is confirmed in the extension's GitHub source. This repo uses the tool trigger
  (`get_order_status`), so the case that applies here is the source-observed one.
- NOT documented: any equivalent backplane or store for the STREAMABLE HTTP
  transport. Learn is silent, not merely thin. The only adjacent signal is the
  `encryptClientState` host.json setting (default `true`), which is suggestive of
  a client-carried state design rather than a server-side store - but the
  mechanism behind it is not explained, so it is not asserted here as fact.

v1.0.0 does not depend on this: its sessions are single-shot per run (connect,
initialize, list, call, close), so no long-lived or scaled-out session behaviour
is exercised. The mechanism only becomes load-bearing in a later phase that
persists sessions (for example a self-hosted server on Container Apps or a
scaled-out host), where session maintenance would be explicit and configured.

## Header propagation (operator reference)

Which HTTP headers cross each hop, who sets them, who reads them, and whether the
behaviour is verified against Microsoft Learn / repo source, or is generic MCP
spec behaviour the platform does not itself document.

| Header | Hop / direction | Set by | Read / validated by | Status |
| --- | --- | --- | --- | --- |
| `Authorization: Bearer <token>` | client -> APIM -> Function | MCP client (server-audience token) | APIM `validate-azure-ad-token`, then built-in auth on the Function; forwarded to the backend by the APIM policy; the delegated order tool reads it via `HttpTransport.Headers` for OBO only after authorization | VERIFIED for the deployed path (repo policy + source; prior documentation-verification passes) |
| `Authorization: Bearer <token>` | client -> ASP.NET Core host | MCP client (server-audience token) | JWT bearer middleware validates it before MCP dispatch; delegated `get_order_status` reads the validated request bearer as the OBO assertion | VERIFIED from repo source and tests; not deployed by issue #147 |
| `WWW-Authenticate: Bearer resource_metadata="..."` | Function/APIM -> client (on 401) | APIM MCP-server policy (no-token) and `on-error` (invalid token) | MCP client, to discover the PRM document (RFC 9728) | VERIFIED (`infra/terraform/modules/apim-mcp-server/policies/mcp-server.xml`; historical discovery evidence in ADR-006) |
| `X-MS-CLIENT-PRINCIPAL` | injected at the Function | Built-in auth V2 (strips any client-supplied copy, injects its own base64-encoded claims JSON) | the Functions adapter decodes and normalizes it; the ASP.NET Core adapter never reads it | VERIFIED (ADR-006 historical Functions trust chain; docs/security.md; `src/McpTools/Identity/ClientPrincipal.cs`) |
| `X-MS-TOKEN-AAD-ACCESS-TOKEN` | injected at the Function only when the token store is enabled | Easy Auth token store | the tool, as the preferred inbound-token source; falls back to `Authorization` | ABSENT in this deployment (token store not enabled; validation-only provider). The tool uses the `Authorization` fallback. See the note below. |
| `X-Mcp-Caller-Azp`, `X-Mcp-Caller-Oid` | MCP host -> downstream Orders API | `get_order_status` downstream adapter | downstream, as audit-grade correlation only (NOT authorization) | VERIFIED (repo source; ADR-012) |
| `x-functions-key` / `?code=` | client -> Function webhook | caller (or APIM in front) | the Functions host, gating the `mcp_extension` system key (401 if absent, unless `system.webhookAuthorizationLevel` is `Anonymous`) | VERIFIED (Functions MCP Learn docs) |
| `Mcp-Session-Id` | client <-> Function (per MCP spec) | MCP SDK / server (spec) | MCP SDK / server (spec) | SPEC-GENERIC: the wire header is MCP-spec / SDK behaviour; NOT documented as the Functions extension's own contract (azure-docs-verifier 2026-08-04). The server-side `SessionId` on the invocation context is source-observed for the tool trigger (Learn documents it for resource/prompt triggers only). |
| `Mcp-Protocol-Version` | client <-> Function (per MCP spec) | MCP SDK / server (spec) | MCP SDK / server (spec) | SPEC-GENERIC: not documented as the Functions extension's contract |
| `Accept: application/json, text/event-stream` | client -> Function | MCP SDK (Streamable HTTP) | the transport | SPEC-GENERIC: generic Streamable HTTP wire format; not a Functions-extension-documented requirement |
| `Content-Type: application/json` | both directions | sender | receiver | Standard HTTP; not MCP-specific |

Note on the spec-generic rows: the ModelContextProtocol SDK emits these headers
and the server honours them, so they DO flow on the wire - but Microsoft Learn's
Functions MCP extension docs do not enumerate them as a required/optional
contract, so they are labelled spec-generic rather than asserted as a platform
guarantee. API Management is not documented to alter `Mcp-Session-Id` in the
passthrough path, so no gateway session-id handling is claimed.

Note on `X-MS-TOKEN-AAD-ACCESS-TOKEN`. This deployment does not receive it, and
two independent gates each explain that (azure-docs-verifier 2026-08-04):

1. The token store is not enabled. `auth_settings_v2` in the `mcp-function-host`
   module sets no token store, and the ARM `tokenStoreEnabled` property defaults
   to `false` for the infrastructure-as-code path this repo uses. (The "on by
   default once auth is enabled" wording in the conceptual docs describes the
   portal path, not the ARM/azapi path.) Token-store headers require the token
   store, so with it off none are injected.
2. Even with the store on, Microsoft Learn ties the AAD *access* token
   specifically to a confidential-client / client-secret configuration (with a
   secret, the hybrid flow yields an access token; without one, the implicit flow
   yields only an ID token). This repo's Easy Auth provider is validation-only -
   its registration is `client_id` + issuer with no client secret - so it is not
   acquiring provider tokens to store in the first place.

A clarification, because it is easy to conflate: the repo's certificateless
federated credential is used by the OBO exchange in application code
(`ManagedIdentityOboTokenAcquirer`, MSAL) - a different auth surface from the Easy
Auth provider registration, and it does not bear on this header. Learn does not
document whether the header would appear for an Easy-Auth provider configured via
a federated credential; that case is not exercised here. The tool's working path
is the `Authorization` fallback: the bearer API Management forwards, read via
`HttpTransport.Headers`.

The alongside ASP.NET Core path has no token-store-header fallback and no
Functions transport object. JWT bearer middleware first validates the request.
The adapter then reads that same request's bearer only for an admitted delegated
`get_order_status` call. It uses the validated `tid` claim for the OBO authority,
reuses one `AzureIdentityForKubernetesClientAssertion`, and sends only the
exchanged Orders-audience token downstream. The Functions host keeps
`ManagedIdentityClientAssertion` while both hosts coexist.

## Debugging map

Each line names its evidence. **VERIFIED** means primary source or repository
source. **OBSERVED** means a captured live run. **INFERRED** marks this repo's
reading where the protocol does not prescribe the result. In particular, every
HTTP 200 below is this deployment's selected and observed wire shape, not an MCP
requirement.

- **VERIFIED.** No `Authorization` header -> HTTP 401 + `WWW-Authenticate` PRM
  challenge at the gateway (transport tier).
- **VERIFIED.** Invalid / wrong-audience token -> HTTP 401 from
  `validate-azure-ad-token` or built-in auth (transport tier); the gateway
  `on-error` adds the same challenge.
- **VERIFIED; INFERRED plus OBSERVED for HTTP 200 on Functions.** Missing or malformed
  `X-MS-CLIENT-PRINCIPAL` makes the tool throw. The caller receives HTTP 200
  with `CallToolResult.isError = true` and `An error occurred invoking
  '<tool>'.`; the detailed reason is in server logs only. Separately,
  `BuiltInAuthGuard` stops the host when built-in auth is off.
- **VERIFIED; INFERRED plus OBSERVED for HTTP 200.** A call that passed the
  gateway map but names no registered tool or has bad parameters -> HTTP 200
  with a JSON-RPC `error` object (MCP runtime tier). A name absent from the
  gateway map does not reach this tier; the gateway default-denies it below.
- **VERIFIED; INFERRED plus OBSERVED for HTTP 200.** An app-context caller that
  reaches a role-gated tool without its required role receives a
  `CallToolResult` with `isError = true` and a readable 403 message. The roles
  are `Orders.Read` for `get_order_status` and `ServiceInfo.Read` for
  `get_service_info`. This is the backend result, not the usual gateway result
  when the map enforces the same role.
- **VERIFIED from ASP.NET Core source and tests; not live.** The alongside host
  exposes exactly the same three tools. The unchanged core refuses a tool when
  its role or delegated scope is absent, even after the caller passed the
  server-entry union.
- **VERIFIED from tool source and unit tests.** A delegated caller that reaches
  the Function directly without `Orders.Read.AsUser` receives the tool-level
  error `403 Forbidden: get_order_status requires the delegated scope
  'Orders.Read.AsUser'.` The check happens before the tool reads the inbound
  bearer or starts OBO. The response's HTTP 200 envelope is not yet observed for
  this new path. Through APIM, the gateway rejects the same token first with its
  JSON-RPC `-32001` error, so that path cannot prove the backend check.
- **VERIFIED; INFERRED plus OBSERVED for HTTP 200.** An ordinary tool exception
  has the same envelope as an explicit tool error: a `result` with
  `isError = true`. The pinned SDK discards the ordinary exception message and
  returns `An error occurred invoking '<tool>'.`; the 2026-07-22 OBO run
  observed that exact message. See COMPATIBILITY.md, "MCP tool method: thrown
  exception wire shape".
- **VERIFIED.** A valid token that lacks this server's delegated scope and app
  role -> HTTP 403 + `WWW-Authenticate: Bearer error="insufficient_scope"` at
  the gateway, with no backend call (gateway tier, HTTP-shaped; issue 17).
- **VERIFIED; INFERRED plus OBSERVED for HTTP 200.** A valid token that is
  entitled to the server but fails the tool map -> HTTP 200 with a JSON-RPC
  `error` object, code `-32001`, request `id` echoed, and no backend call
  (gateway tier, JSON-RPC-shaped; issue 18).
- **VERIFIED.** A `tools/call` whose `id` is missing, `null`, or not a
  string/integer -> HTTP 400 with a JSON-RPC `error` object, code `-32600`, and
  no `id` key, with no backend call (gateway tier; issue 88). This fires ahead
  of the per-tool authorization check and emits no audit event.
- **OBSERVED.** A `tools/call` (or any method) whose body is not valid JSON ->
  HTTP 500, APIM's generic policy-expression failure, with no JSON-RPC envelope.
  The unconditional request-body parse causes it before the checks above. A
  spec-conformant response is a separate change.

**VERIFIED from the current policy, map reference, and tool source:** map
presence is not itself the boundary between the two HTTP 200 shapes. The three
states are:

| Map state for this call | Who denies | Wire shape |
| --- | --- | --- |
| No entry | Gateway default-deny | JSON-RPC `error`, code `-32001` |
| Entry rejects the caller, including the documented `ServiceInfo.Read` entry | Gateway | JSON-RPC `error`, code `-32001` |
| Entry admits the call, or a caller bypasses the gateway | Tool | `result` with `isError: true` if the tool's independent role or delegated-scope check refuses it |

The HTTP 200 entries in this table are **INFERRED plus OBSERVED**, as above.
The table prevents a false live assertion: adding a role-gated map entry does
not itself make a caller missing that role reach the backend.

The three response tiers (transport 401 vs JSON-RPC error vs tool `isError`) are
diagrammed and explained in the historical ADR-006, "Reference diagrams" and
"Request outcomes".
Read those three as the tiers produced by the transport, the MCP runtime, and the
tool; the gateway-issued surface described below is a fourth producer that ADR's
diagram does not depict, and that THIS file, not the ADR, enumerates. It is also
the only place all three instances are listed: `per-tool-deny-path` draws the
issue-18 and issue-88 ones but starts after the issue-17 403 has already passed.
ADR-012 owns the current two-host identity and delegated OBO decision.

### The fourth surface: gateway denial, before the backend

![Per-tool authorization deny path: after the issue-9 and issue-17 checks
pass, API Management parses the JSON-RPC request body once, gates on
tools/call, resolves the tool name (gen_ai.tool.name context variable,
falling back to the parsed body), applies the issue-88 id-validity guard
(rejecting a missing, null or non-scalar id with HTTP 400 and JSON-RPC -32600,
id key omitted, before the map is consulted), then looks the tool up against
the server's tool_authorization_map, and on a deny emits one audit trace to
Application Insights before returning a JSON-RPC Protocol Error (HTTP 200,
code -32001, request id echoed) without ever invoking the backend Function
App.](diagrams/per-tool-deny-path.drawio.svg)

The three tiers above classify a response by its wire shape. That is the right
axis for a client, which sees only the wire, but it is the wrong axis for an
operator, who also needs to know how far the request travelled. There is a
fourth error surface that the three tiers do not name: a denial issued by API
Management itself, entirely inside the server-scope policy's `<inbound>` section,
before `<backend><forward-request />` ever runs. The Function host is never
invoked, so nothing about such a request appears in the backend's logs, and no
`X-MS-CLIENT-PRINCIPAL` is ever minted for it.

Three instances of this surface exist in the repo, and they do NOT share a wire
shape. The property they share is where they happen, not what they look like:

| Denial | Wire shape | Where |
| --- | --- | --- |
| Per-server entitlement (issue 17) | HTTP 403, `WWW-Authenticate: Bearer error="insufficient_scope"` (RFC 6750), JSON body `{"error":"insufficient_scope", ...}`, deliberately no `resource_metadata` | `<inbound>`, after `validate-azure-ad-token` |
| Per-tool authorization (issue 18) | HTTP 200, JSON-RPC 2.0 error object, code `-32001`, request `id` echoed, over the normal response channel | `<inbound>`, after the per-server check and after the id-validity guard below, gated on `method == "tools/call"` |
| Request-validity rejection (issue 88) | HTTP 400, JSON-RPC 2.0 error object, code `-32600`, `id` key OMITTED entirely (MCP forbids a null `id`, so there is none to echo) | `<inbound>`, inside the `method == "tools/call"` branch but BEFORE the per-tool authorization lookup, so it applies regardless of what that decision would have been |

All three are in
`infra/terraform/modules/apim-mcp-server/policies/mcp-server.xml`.

Why the shapes differ, precisely:

- The per-server denial is an HTTP-layer rejection. It is transport-shaped, like
  tier 1, but it is a different case from tier 1 and should not be filed under
  it: tier 1's 401 means the token is missing or invalid, whereas this 403 means
  the token is valid, correctly audienced, and issued to an allowed client, and
  is merely under-entitled for this server. A client that retries acquisition
  will get the same 403; the fix is an entitlement grant, not a fresh token. That
  is also why the challenge carries `error="insufficient_scope"` and no
  `resource_metadata`: there is nothing to discover.
- The per-tool denial is a JSON-RPC-layer rejection. It is NOT an HTTP-layer
  rejection at all: HTTP 200, an error object with the request `id` echoed,
  delivered over the normal request/response channel.

  **VERIFIED:** the MCP specification names Protocol Errors and Tool Execution
  Errors as distinct categories. COMPATIBILITY.md, "MCP tools/call denial wire
  shape", owns the exact source derivation.

  **INFERRED:** the specification does not assign a per-tool authorization
  denial to either category. Its authorization 403 concerns token validation at
  the transport level, while its tool page says only to implement access
  controls. This repository therefore chooses a Protocol Error because the
  gateway refuses before any tool runs. That is a design judgement, not a quoted
  mandate. The backend's `isError` result is equally specification-compliant.

  **INFERRED plus OBSERVED:** HTTP 200 is this deployment's selected wire shape,
  not a status the specification names for an answered `tools/call`.
- The request-validity rejection (issue 88) is not a denial at all, despite
  sharing this table. It fires when a `tools/call` carries an `id` that is
  missing, `null`, or not a string/integer, and it runs BEFORE the per-tool
  authorization lookup, so it applies to a tool the caller is fully entitled to
  just as much as to one they are not. MCP is stricter than base JSON-RPC here:
  "Requests MUST include a string or integer ID" and "Unlike base JSON-RPC, the
  ID MUST NOT be null." The response therefore OMITS `id` rather than echoing
  `null` (which would repeat the violation) or inventing one (which would break
  the caller's own request/response correlation).

  Same discipline as above about what is quoted and what is inferred. For a body
  with a `method` and no `id`, the citation is exact: that is a NOTIFICATION by
  the spec's own typology, and the Streamable HTTP transport's step 4 governs it
  directly, sanctioning a 400 whose body "MAY comprise a JSON-RPC error response
  that has no id". For an explicit `"id": null`, it is an inference: that message
  is neither a valid request nor a valid notification, so step 4 does not cleanly
  reach it and step 5 (requests) names no error status at all. Answering both the
  same way is this repo's choice for a shape the spec leaves unaddressed.

  Two operational consequences. First, it emits NO audit event, unlike the
  `-32001` deny, because no authorization decision happened to record. That is
  not a visibility loss, which is worth being precise about: the check never
  reads the tool name and its response body is a fixed string, so every id-less
  `tools/call` gets byte-identical bytes back whatever tool it names. Pre-fix
  the response varied by tool, which is what made an id-less probe an
  enumeration oracle worth auditing; that oracle is closed now, not hidden.
  Enumeration requires a well-formed `id`, and those requests reach the
  authorization check and emit its audit event as they always did. Second, it
  is the one gateway rejection here that is HTTP-shaped AND JSON-RPC-shaped at
  once: a 400 status carrying a JSON-RPC error object.

The consequence worth internalising is that "which tier" and "how far did it get"
are independent questions. A JSON-RPC error object on the wire no longer implies
the request reached the MCP server: since issue 18 it may equally be the gateway
refusing a `tools/call` it never forwarded. The two are not distinguishable from
the response alone, and that is intentional (the per-tool deny path is the same
for a tool the caller is not entitled to and a tool absent from the map, so the
response does not reveal which). The discriminator is server-side, not on the
wire: every per-tool deny emits exactly one `<trace>` audit event, dimensioned by
caller and tool, into Application Insights. An operator asked "was this denied at
the gateway or by the server?" should answer from that telemetry, not by
inspecting the client's copy of the response.

The spec does not mandate a numeric code for "not authorized for this tool".
`-32001` is a custom code in the MCP-reserved range (-32000 to -32099), chosen
over reusing the spec's `-32602` "Unknown tool" example because that label would
misdescribe a mapped-but-under-entitled caller.

Note on issue #52. Issue #52 ("MCP (JSON-RPC 2.0) vs REST through an APIM
gateway: what transfers, what breaks") has no document in this repo yet
(confirmed 2026-08-06). This section is the canonical home for the
gateway-denial-as-fourth-surface framing. When #52 is written it should link
here rather than restate the taxonomy, so the two documents cannot drift into
disagreeing about it.
