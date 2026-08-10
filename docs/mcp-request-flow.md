# MCP request flow: session lifecycle and header propagation

How a request travels through the v1.0.0 platform, from the MCP client's
`initialize` handshake to a `tools/call` result, and which HTTP headers each hop
adds, strips, or reads. Two audiences: the session lifecycle is the protocol
depth; the header table is the operator's debugging reference.

Scope and honesty. This page describes the Streamable HTTP transport at tag
v1.0.0. Where Microsoft Learn does not document a behaviour, that is stated as a
gap, not filled by inference. The session-state maintenance mechanism for
Streamable HTTP is one such gap (see below).

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
3. `tools/list`. The client discovers `get_order_status`.
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
| `Authorization: Bearer <token>` | client -> APIM -> Function | MCP client (server-audience token) | APIM `validate-azure-ad-token`, then Easy Auth on the Function; forwarded to the backend by the APIM policy; the tool reads it via `HttpTransport.Headers` for the OBO exchange | VERIFIED (repo policy + source; azure-docs-verifier prior passes) |
| `WWW-Authenticate: Bearer resource_metadata="..."` | Function/APIM -> client (on 401) | APIM MCP-server policy (no-token) and `on-error` (invalid token) | MCP client, to discover the PRM document (RFC 9728) | VERIFIED (`infra/terraform/modules/apim-mcp-server/policies/mcp-server.xml`; ADR-006) |
| `X-MS-CLIENT-PRINCIPAL` | injected at the Function | Easy Auth V2 (strips any client-supplied copy, injects its own base64-encoded claims JSON) | the app decodes and parses it (`ClientPrincipal.TryParse`), then `IdentityModeResolver` / authorization code does claims-based checks (no in-code signature check) | VERIFIED (ADR-006 "header trust chain"; docs/security.md; `src/McpTools/Identity/ClientPrincipal.cs`) |
| `X-MS-TOKEN-AAD-ACCESS-TOKEN` | injected at the Function only when the token store is enabled | Easy Auth token store | the tool, as the preferred inbound-token source; falls back to `Authorization` | ABSENT in this deployment (token store not enabled; validation-only provider). The tool uses the `Authorization` fallback. See the note below. |
| `X-Mcp-Caller-Azp`, `X-Mcp-Caller-Oid` | Function -> downstream Orders API | the tool (`get_order_status`) | downstream, as audit-grade correlation only (NOT authorization) | VERIFIED (repo source; ADR-006 issue 45) |
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

## Debugging map

- No `Authorization` header -> HTTP 401 + `WWW-Authenticate` PRM challenge at the
  gateway (transport tier).
- Invalid / wrong-audience token -> HTTP 401 from `validate-azure-ad-token` or
  Easy Auth (transport tier); the gateway `on-error` adds the same challenge.
- Missing / malformed `X-MS-CLIENT-PRINCIPAL` -> request rejected per-request;
  and the host refuses to start at all if built-in auth is off (`BuiltInAuthGuard`).
- Authenticated but wrong tool name / bad params -> HTTP 200 with a JSON-RPC
  `error` object (protocol tier).
- Authenticated, valid call, missing `Orders.Read` -> HTTP 200 with a
  `CallToolResult` where `isError = true` ("403 Forbidden ..."), no downstream
  call (tool tier).
- Valid token, but it lacks this server's delegated scope and its app role ->
  HTTP 403 + `WWW-Authenticate: Bearer error="insufficient_scope"` at the
  gateway, no backend call (gateway tier, HTTP-shaped; issue 17).
- Valid token, entitled to the server, but not to the tool named in a
  `tools/call` (or naming a tool with no entry in this server's authorization
  map) -> HTTP 200 with a JSON-RPC `error` object, code `-32001`, request `id`
  echoed, no backend call (gateway tier, JSON-RPC-shaped; issue 18).
- A `tools/call` whose `id` is missing, `null`, or not a string/integer ->
  HTTP 400 with a JSON-RPC `error` object, code `-32600`, and NO `id` key at
  all, no backend call (gateway tier; issue 88). MCP forbids a null `id`
  ("the ID MUST NOT be null"), so there is no valid id to echo and inventing
  one would break the caller's own correlation. This fires ahead of the
  per-tool authorization check, so it applies even for a tool the caller IS
  entitled to: it is a request-validity rejection, not an authorization
  decision, and unlike the `-32001` deny it emits no audit event.
- A `tools/call` (or any method) whose body is not valid JSON -> HTTP 500,
  APIM's generic policy-expression failure, with no JSON-RPC envelope. This
  happens at the gateway's unconditional request-body parse, before any of
  the checks above. Known and out of scope for issue 88; a spec-conformant
  response here would be a separate change.

The three response tiers (transport 401 vs JSON-RPC error vs tool `isError`) are
diagrammed and explained in ADR-006, "Reference diagrams" and "Request outcomes".
Read those three as the tiers produced by the transport, the MCP runtime, and the
tool; the gateway-issued surface described below is a fourth producer that ADR's
diagram does not depict (its re-export is a pending human step) and that THIS
file, not the ADR, enumerates.
The identity flows (app-only vs delegated OBO) are also in ADR-006.

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

> **Diagram export pending.** The `.drawio` source above carries the issue-88
> id-validity guard (step 4b); the embedded `.drawio.svg` does not yet, because
> under this repo's Diagrams rule the export is a human step performed after
> layout is corrected by hand. Until that export lands, the rendered image shows
> the pre-issue-88 path. This PR is not complete without it.

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

  Two things are being claimed there, and only one of them comes from the spec.
  Keeping them apart matters, because an earlier revision of this passage ran
  them together and a reader could not tell which was which (corrected
  2026-08-08; the same correction was applied to COMPATIBILITY.md's
  "MCP tools/call denial wire shape" row).

  **From the spec.** The MCP specification (2025-06-18) defines exactly two
  error categories for `tools/call`: Protocol Errors, which are standard
  JSON-RPC 2.0 error objects, and Tool Execution Errors, which are
  `CallToolResult` with `isError: true`. The rule is a SHOULD, and it lives in
  `schema/2025-06-18/schema.ts` rather than the prose page: any errors that
  "originate from the tool" SHOULD be reported inside the result object with
  `isError` set to true, "not as an MCP protocol-level error response.
  Otherwise, the LLM would not be able to see that an error occurred and
  self-correct."

  **This repo's decision, NOT a spec requirement.** Which category a per-tool
  authorization denial belongs to is not something the spec settles.

  Deal with the nearest counter-evidence rather than around it, because a
  skeptical reader will find it: the authorization section DOES carry an error
  table whose 403 row reads "Invalid scopes or insufficient permissions", and a
  per-tool denial is arguably insufficient permissions. That table is read here
  as governing the HTTP status of OAuth 2.1 TOKEN validation, not the JSON-RPC
  reporting channel of a tool-level decision, for two reasons: the section
  scopes itself to authorization "at the transport level", and its neighbouring
  rows ("Authorization required or token invalid", "Malformed authorization
  request") are all token-lifecycle cases evaluated before any MCP method is
  dispatched. On the tool side the spec says only "implement proper access
  controls", with no guidance on reporting channel at all. That reading is a
  judgement, not a quotation, and someone could reasonably land the other side
  of it.

  So the gateway
  emitting a Protocol Error here is a design choice, argued on its merits:
  nothing "originated from the tool" when the denial happens wholly inside
  `<inbound>` and the tool never runs. HTTP 401/403 ahead of any JSON-RPC
  envelope is reserved in this repo for transport and session violations, which
  this is not.

  The corollary is worth stating plainly, because the backend does the opposite
  and that is not a contradiction: the MCP server's own role check returns
  `isError: true`, and it is EQUALLY spec-compliant. It has no alternative in
  any case, since a tool method cannot emit a Protocol Error (COMPATIBILITY.md,
  "MCP tool method: thrown exception wire shape"). The gateway can, because it
  refuses before any tool runs.

  One more precision: the spec names no HTTP status for a well-formed
  `tools/call` that the server answered, since its transport section enumerates
  only 202, 400, 404 and 405. "HTTP 200" here is an inference from the absence
  of any rule requiring a 4xx, plus live observation, not a quoted mandate.

  See COMPATIBILITY.md, "MCP tools/call denial wire shape", verified against the
  MCP spec directly rather than against Microsoft Learn, since this is a
  protocol contract and not an Azure one.
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
