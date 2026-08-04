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

The three response tiers (transport 401 vs JSON-RPC error vs tool `isError`) are
diagrammed and explained in ADR-006, "Reference diagrams" and "Request outcomes".
The identity flows (app-only vs delegated OBO) are also in ADR-006.
