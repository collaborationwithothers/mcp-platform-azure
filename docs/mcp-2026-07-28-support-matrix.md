# MCP 2026-07-28 Support Matrix

Status: DRAFT - spike pending. APIM cells marked "Spike" are unverified.
Last verified: 2026-08-12 (spec and SDK columns; APIM documented cells cite docs written for pre-2026-07-28 revisions). The four spec-resolvable [verify] rows (subscriptions/listen, completion, elicitation, EMA) are resolved as of this date; APIM "Spike" cells remain unresolved pending the child (c) spike.
Issue references verified: 2026-08-12 against gh issue list output (authoritative source). The line-24 closed-issue reference is #18; the line-28 reference was corrected from an erroneous #83 (wrong issue, unrelated) to #88, the actual null-id echo fix.
Scope: the union of live (non-deprecated, non-removed) features in MCP revision 2026-07-28, tested through this platform's gateway path (APIM passthrough MCP resource fronting the demo server).

## How to read this document

- **Feature**: a capability of the 2026-07-28 revision.
- **What it means**: one plain-English sentence.
- **SDK v2**: support status in ModelContextProtocol C# SDK 2.0.0 (stable, aligned with 2026-07-28).
- **APIM passthrough**: whether APIM's native MCP passthrough resource handles the feature. "Doc: yes/no" means Microsoft documentation states it, but that documentation was written against the 2025-06-18 era protocol; behaviour under 2026-07-28 is unverified until the spike. "Spike" means no documented answer exists.
- **Platform disposition**: what this repo does about it. Values: adopt, spike-first, de-scope, n/a.
- Rows marked [verify] carry a claim sourced from secondary material, not the spec text. Confirm against the specification before citing this row publicly.

## 1. Transport and base protocol

| Feature | What it means | SDK v2 | APIM passthrough | Platform disposition |
|---|---|---|---|---|
| Stateless Streamable HTTP (SEP-2567) | No protocol sessions and no Mcp-Session-Id header; any server instance can answer any request. | Yes (stateless is the default) | Spike - existing passthrough docs assume the session-era protocol | Adopt. Dissolves the premise of issue #51 (AKS session-state); re-scope that issue |
| Handshake removal (SEP-2575) | No initialize exchange; every request carries protocol version, client info, and client capabilities in _meta. | Yes | Spike - does the passthrough expect or inject a handshake? | Adopt |
| Version negotiation / down-level interop | Clients and servers negotiate the revision per request; SDK v2 peers interoperate down to 2025-11-25 and earlier. | Yes | Spike - is the passthrough transparent to negotiation or does it pin a version? | Adopt; dual-version support is the migration bridge |
| Standard HTTP headers: Mcp-Method, Mcp-Name, Mcp-Param-{name} | The JSON-RPC method and target name are mirrored into HTTP headers so gateways can route and authorize without parsing bodies. | Yes (required when negotiated version is 2026-07-28) | Spike - do the headers reach APIM policy context unmodified? | Adopt. Replaces the platform's earlier body-inspection authorization approach: issue #18 ("Per-tool authorization and tool blocking at the gateway", closed), confirmed 2026-08-12 by reading the issue. Security note: headers are client-supplied; policy must enforce header-body consistency (fail closed on mismatch) unless the SDK is confirmed to reject mismatches server-side [verify] |
| Multi Round-Trip Requests (SEP-2322) | A server can pause a request and ask the client for more input using opaque state tokens, replacing server-initiated requests over a persistent stream. | Yes | Spike - does the passthrough relay the multi-exchange flow? | Spike-first. Prerequisite for interactive flows incl. elicitation |
| subscriptions/listen stream (SEP-2575) | Change notifications (tools/prompts/resources list changes, resource updates) arrive on a single opt-in stream, tagged with a subscription id; the old GET notification stream is gone. | Partial in 2.0.0 (verified 2026-08-12): the SDK ships built-in handling for standard `*/list_changed` notifications over `subscriptions/listen`, but the public typed handler that lets server authors deliver custom subscription kinds (`WithSubscriptionsListenHandler`) shipped one release later, in 2.1.0 (2026-08-05, PR modelcontextprotocol/csharp-sdk#1775, closing issue #1662, which states the 2.0.0 gap explicitly). This platform's tool set does not currently need custom subscription kinds, so the 2.0.0 built-in path is sufficient if adopted at 2.0.0; re-check the pinned SDK version against 2.1.0+ if custom subscriptions become a requirement. | Spike - long-lived stream through APIM: timeouts, buffering, policy interaction | Spike-first |
| List caching hints / TTL (SEP-2549) | tools/list, prompts/list, and resources/list results carry time-to-live hints so clients and intermediaries can cache them. | Yes (incl. conformance diagnostics) | Spike - does APIM caching respect, strip, or ignore the hints? | Adopt |
| Error model: transport vs application errors | Transport failures use real HTTP status codes; JSON-RPC errors are application-level; post-parse Streamable HTTP errors must echo the request id. | Yes | Spike | Adopt. Correction 2026-08-12: the closed-issue reference in the on-disk draft was wrong. Issue #83 is "decide how the policy's scope branch is evidenced" (unrelated). The gateway-echoed-null-id fix is issue #88 ("gateway may echo a null JSON-RPC id on the -32001 deny path"), landed via PR #102. Cross-check against the now-mandatory 2026-07-28 base-protocol id echo (confirmed live in the SDK: csharp-sdk v2.0.0 release notes list "Echo the request ID in post-parse Streamable HTTP errors #1687"): PR #102's fix rejects an id-less or null-id `tools/call` with HTTP 400 before the authorization decision runs, and its error body omits the `id` key entirely rather than echoing null - this is a transport-level rejection (real HTTP status, matching the 2026-07-28 error-model split), not a post-parse JSON-RPC error, so the fix does not need to change to satisfy the new mandatory echo rule: the echo rule applies to responses that carry an id, and PR #102's fix never reaches a point where it would echo one. Not adopted (2026-07-28 is not adopted), so no code change follows from this row; the citation is recorded for when (d)'s migration ADR is written |
| Progress notifications | Servers report progress on the response stream of the originating request when the client supplies a progress token. | Yes | Spike | Adopt |
| Cancellation | A client can cancel an in-flight request via notification. | Yes | Spike | Adopt |
| Pagination | List operations page with opaque cursors. | Yes | Spike (low risk - body-level) | Adopt |

## 2. Server features

| Feature | What it means | SDK v2 | APIM passthrough | Platform disposition |
|---|---|---|---|---|
| Tools (tools/list, tools/call) | The server's callable operations, discovered at runtime with JSON schemas. | Yes | Doc: yes (pre-2026 revision); Spike for stateless flow | Adopt - core platform scenario |
| Structured tool output (outputSchema) | Tool results can declare and return typed, structured content instead of free text. | Yes | Body-level; no gateway interaction expected. Spike optional | Adopt |
| Tool annotations | Hints describing tool behaviour (e.g. read-only, destructive) for client-side handling. | Yes | Body-level; n/a to gateway | Adopt |
| Resources (list, read, templates, subscribe) | Server-exposed data the client can read and subscribe to, addressed by URI. | Yes | Doc: yes (pre-2026 revision); subscribe path now rides subscriptions/listen - Spike | Adopt |
| Prompts (prompts/list, prompts/get) | Server-provided prompt templates a client can fetch and render. | Yes | Doc: NO - passthrough explicitly does not support prompts (pre-2026 docs) | Decide in migration ADR: de-scope prompts, or model as plain HTTP API to escape the limitation |
| Completion (completion/complete) | Argument autocompletion for prompts and resource templates. Confirmed live in 2026-07-28 (verified 2026-08-12): the spec's own `completion/complete` page is published under the `/specification/2026-07-28/` path with the new `resultType: "complete"` envelope in its example responses, so the feature is neither removed nor deprecated in this revision. | Yes. `completion/complete` predates 2026-07-28 and the 2026-07-28 changelog does not list it as removed or deprecated; the SDK v2.0.0 release adds "the `complete` result discriminator" (csharp-sdk#1684), which is the SDK-side implementation of the `resultType` field the spec now requires on this method's response | Spike | Spike-first, low priority |

## 3. Client-interaction features

| Feature | What it means | SDK v2 | APIM passthrough | Platform disposition |
|---|---|---|---|---|
| Elicitation | The server asks the user for structured input mid-call; in 2026-07-28 this flows through Multi Round-Trip Requests rather than a server-initiated request on a session stream. Confirmed against the spec (verified 2026-08-12): the changelog's minor change 11 removes `notifications/elicitation/complete` and the `elicitationId` field introduced in 2025-11-25, stating "Under the Multi Round-Trip Requests pattern, the client learns the outcome of an out-of-band interaction by retrying the original request" - servers needing to correlate an elicitation across retries now encode their own identifier in `requestState` instead. | Yes. csharp-sdk v2.0.0 adds MRTR (csharp-sdk#1458) and exposes elicitation as an `InputRequiredException` a tool throws, carrying required inputs and a `requestState` string echoed back on retry, matching the spec's replacement mechanism exactly | Spike - inherits the MRR row's result | Spike-first. Relevant to issue #42 (interactive auth UX) |

## 4. Extensions (opt-in, negotiated via the extensions framework)

| Feature | What it means | SDK v2 | APIM passthrough | Platform disposition |
|---|---|---|---|---|
| Extensions framework (SEP-2133) | Capabilities outside the core protocol are declared, versioned, and negotiated as named extensions. | Yes | Spike - does the passthrough relay extension negotiation untouched? | Adopt |
| Tasks (io.modelcontextprotocol/tasks, SEP-2663) | Long-running work: the server returns a task handle; the client polls tasks/get and can send input via tasks/update. Redesigned from the 2025-11-25 experimental version (blocking tasks/result and tasks/list removed). | Yes - separate package ModelContextProtocol.Extensions.Tasks | Spike | Spike-first. This is the standardized answer to issue #26 (durable execution); re-scope #26 against the extension |
| MCP Apps (SEP-1865) | Servers ship sandboxed interactive HTML UIs that hosts render; UI actions go through the normal tool-call audit path. Final since 2026-01-26. | Yes - separate extension package | Not tested | De-scope for v2.0.0; note as out of scope in README |
| Enterprise Managed Authorization (EMA) | An extension named in the published specification for enterprise-managed authorization, `io.modelcontextprotocol/enterprise-managed-authorization` (SEP-990). Read the extension spec (verified 2026-08-12, github.com/modelcontextprotocol/ext-auth/blob/main/specification/stable/enterprise-managed-authorization.mdx and modelcontextprotocol.io/extensions/auth/enterprise-managed-authorization): the organization's IdP mediates an Identity Assertion JWT Authorization Grant (ID-JAG) exchange between MCP client and the MCP server's authorization server, so employees sign in once via corporate SSO instead of authorizing each MCP server individually. Extensions are opt-in and never active by default; a client or server that does not declare the extension is unaffected. Stable since 2026-06-18 per the official MCP blog announcement (blog.modelcontextprotocol.io/posts/enterprise-managed-auth/, dated 2026-06-18) | Yes. csharp-sdk v2.0.0 release notes list "Add Enterprise Managed Authorization support (SEP-990)" (csharp-sdk#1305): `IdentityAssertionGrantProvider` and supporting types in `ModelContextProtocol.Authentication` implement the ID-JAG flow (RFC 8693 token exchange at the enterprise IdP, then RFC 7523 JWT bearer grant at the MCP authorization server) | Spike if adopted | Investigate before the migration ADR: this repo's per-tool authorization model (issue #18) gates on scope/role claims inside a token APIM already receives; EMA changes how that token is obtained (IdP-mediated ID-JAG exchange), not what claims it carries, so it is additive to #18's model rather than a replacement - but it is opt-in per client/server, so this repo would need to declare it and stand up IdP-side policy to use it. Directly relevant to issue #42 (interactive auth UX / Entra deadlock): EMA is a corporate-SSO-first flow, which may sidestep the RFC 8707 resource-indicator deadlock by not routing through the same authorization-code flow at all - worth checking in the migration ADR before dismissing #42 as unaffected by 2026-07-28 |

## 5. Authorization

| Feature | What it means | SDK v2 | APIM passthrough | Platform disposition |
|---|---|---|---|---|
| OAuth 2.1 resource server + Protected Resource Metadata (RFC 9728) | The server advertises its authorization server via a well-known PRM document; clients discover where to log in. PRM must be served at the gateway root (existing platform finding). | Yes; SDK roadmap targets deeper end-to-end auth in 2.x | Partially in place today (platform-built); Spike for changes under the new revision | Adopt. Re-test issue #42 (Entra RFC 8707 deadlock) under the new OAuth/OIDC alignment before writing the OAuth-proxy vs custom-domain ADR |
| Closer OAuth 2.0 / OpenID Connect alignment | The revision tightens authorization semantics toward standard enterprise OAuth/OIDC deployment practice. | Yes | Spike | Adopt; document deltas against the platform's existing Entra flow |

## 6. Removed or deprecated - consciously excluded from test scope

| Item | Status | Note |
|---|---|---|
| Protocol sessions / Mcp-Session-Id | Removed (SEP-2567) | Servers needing cross-call state mint explicit handles passed as tool arguments |
| initialize / notifications/initialized | Removed (SEP-2575) | Replaced by per-request _meta |
| ping | Removed | - |
| logging/setLevel | Removed | Log level set per request via io.modelcontextprotocol/logLevel in _meta; servers must not emit notifications/message without it |
| notifications/roots/list_changed | Removed | - |
| Old HTTP GET notification stream | Removed | Replaced by subscriptions/listen |
| Roots | Deprecated (SEP-2577) | Working for >= 12 months; replaced by tool parameters, resource URIs, or server configuration. New implementations must not adopt |
| Sampling | Deprecated (SEP-2577) | Replaced by direct LLM provider API integration |
| Logging capability | Deprecated (SEP-2577) | Replaced by stderr (stdio) and OpenTelemetry |
| Legacy HTTP+SSE transport | Deprecated | Year-long offramp; platform never targeted it |

## Spike exit criteria

Every "Spike" cell in sections 1-5 resolved to yes / no / partial with a dated note and, where partial, the exact failing behaviour. Output feeds the migration ADR (native passthrough vs plain HTTP modelling). Timebox: 2 days.

## Sources

- MCP 2026-07-28 changelog: modelcontextprotocol.io/specification/2026-07-28/changelog
- MCP release blog posts (2026-07-28 stable and release candidate), blog.modelcontextprotocol.io
- C# SDK v2.0.0 release notes: github.com/modelcontextprotocol/csharp-sdk/releases
- APIM passthrough documentation: learn.microsoft.com/azure/api-management/expose-existing-mcp-server (states tools and resources supported, prompts not; written pre-2026-07-28)
