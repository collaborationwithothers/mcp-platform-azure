# ADR-009: Gateway-enforced per-tool authorization

Status: Accepted (issue #18; one provenance implemented, one described)
Date: 2026-08-06
Amended: 2026-08-07, interception order between the two enforcement layers
(see Consequences, C5).
Restructured: 2026-08-08. Presentation only. No decision, measurement, or
verification in this document was changed, added, or removed by that
restructure; the engineering log and the corrections to earlier drafts moved
from the body into Appendix A and Appendix B verbatim.

## Summary

MCP `tools/call` requests reaching this platform were authorized per SERVER but
never per TOOL. This ADR records how per-tool authorization was added.

Five decisions, each expanded below:

- **D1.** Enforce per tool at the GATEWAY, in an APIM policy fragment at server
  scope, and KEEP the existing backend app-role check as a genuine second layer.
  Neither supersedes the other.
- **D2.** Deny by default, from a TOTAL map of tool name to required claim. The
  map is not a list of forbidden tools; it is the list of the only tools that can
  be invoked.
- **D3.** The map has two provenances, and which one applies follows who owns the
  TOOL SURFACE, not where policy attaches. Policy attaches at server scope for
  both server types, because no other scope exists.
- **D4.** Enforce without concealing. `tools/list` returns every tool to every
  caller who reaches the server. Concealment at tool granularity is forbidden by
  a documented platform constraint, not declined; concealment at SERVER
  granularity already exists and is the supported substitute.
- **D5.** Audit every deny, to a sink that outlives the ephemeral environment.

Two halves of this decision are NOT equally proven, and the Status line says so
rather than collapsing them. The enforcement fragment and the HAND-MAINTAINED
(passthrough) map provenance are implemented in the issue #18 PR. The DERIVED
(REST-export) map provenance is a named growth path, described and not
demonstrated, owned by issue #58. This follows the ADR-006 precedent: record the
decision when it is made, name the growth path, and let the status reflect only
what a running system has actually proven.

## Context

### What the platform already enforces, and what it does not

Before this ticket, an MCP `tools/call` request reaching a server behind the
gateway had cleared four checks, none of which knows which TOOL is being called:

1. `validate-azure-ad-token` at the gateway (issuer, audience, allowed client
   application ids).
2. The per-server entitlement check at the gateway (issue 17): this server's
   delegated scope in `scp` OR this server's app role in `roles`, expressed as a
   policy expression because `validate-azure-ad-token`'s `required-claims` block
   ANDs its entries and cannot express an OR across two claim names (ADR-006,
   "Identity: shared registration, per-server scope and role, OR-checked").
3. Easy Auth on the Functions backend (audience validation, and the stripping of
   client-supplied `X-MS-*` headers that makes the injected
   `X-MS-CLIENT-PRINCIPAL` trustworthy).
4. The MCP-layer app-role check in the tool code
   (`src/McpTools/Identity/AppRoleAuthorization.cs`,
   `HasOrdersRead(ClientPrincipal)`), the issue-45 trusted-subsystem arm that
   returns a deterministic 403 tool error and makes no downstream call when
   `Orders.Read` is absent.

Checks 1 and 2 are SERVER-scoped: they answer "may this caller reach this MCP
server at all". Check 4 is the only one that is per-tool, and it lives inside the
one tool that exists. Nothing between the client and the backend decides, per
tool, whether the calling identity may invoke THAT tool.

### The corrected premise: there is no per-tool policy scope

Issue #18's original framing assumed the REST-export server type gave native
per-tool authorization through operation-scoped policies. That is refuted.
Microsoft Learn states, in identical wording on both the export and the
passthrough pages, that "the policies apply to all API operations exposed as
tools in the MCP server". No per-tool or per-operation policy scope exists for
MCP servers of EITHER server type. What REST-export provides is static tool
SELECTION (choosing which backend operations become tools via the Tools blade or
`backingOperationId`), which is a deployment-time surface choice, not a runtime
authorization decision (COMPATIBILITY.md, "APIM MCP server policy scope (both
server types)", verified 2026-07-27,
https://learn.microsoft.com/azure/api-management/export-rest-mcp-server#configure-policies-for-the-mcp-server).

Runtime per-tool authorization is therefore a server-scope policy problem
everywhere, for every server type. It is not a switch to turn on; it is a
mechanism this repo builds inside one server-scope fragment that inspects which
tool a request is calling and decides. That is the thing this ADR records the
architecture of.

## Decision

### D1. Enforce at the gateway, and keep the backend check as a real second layer

Per-tool authorization is enforced by an APIM policy fragment at server scope, in
`inbound`, before the backend is called
(`infra/terraform/modules/apim-mcp-server/policies/mcp-server.xml`). It runs
AFTER the issue-17 per-server entitlement check, so a caller must clear both: the
server-scope check answers "may you reach this server", the per-tool check
answers "may you invoke this tool".

**Both layers are real; neither supersedes the other.** This is defense in depth
in the specific sense ADR-006 already uses for the issue-53 issuance gate versus
the request-time `allowedApplications` check: two distinct checks, at two
distinct moments, each catching something the other cannot.

- The gateway layer denies BEFORE the backend is ever reached. That is what buys
  blast-radius containment (an unauthorized invocation never becomes backend
  execution, never touches a downstream, never mints a downstream token), cost
  containment (the denied call spends no Functions execution, and, once #19
  lands, no Content Safety transaction), and audit AT THE EDGE (the deny is
  recorded on the shared control point that fronts every server, not scattered
  across per-server backend logs). It also generalises: it is the only layer that
  can decide per tool for a server whose backend this repo does not own, which is
  precisely the REST-export case #58 will add.
- The MCP-layer check is the last line if the gateway layer is bypassed or
  misconfigured. It is not hypothetical that the gateway can be bypassed: the
  Functions backend is reachable directly on its own hostname (this repo probed
  it and got a 405, not a 401, on 2026-07-16 -- see the `set-header
  Authorization` comment in the fragment), so Easy Auth plus
  `AppRoleAuthorization.HasOrdersRead` is what stands between a direct caller and
  the tool. A rendered-map bug, a drifted map, or a policy deployment that failed
  to apply would all be invisible to the gateway layer and caught here.

Neither layer is redundant with the other, and the existence of one is not a
reason to weaken the other. The gateway layer is deliberately NOT given authority
the backend lacks, and the backend layer is deliberately NOT removed now that the
gateway can decide.

### D2. Deny by default, from a total map

The fragment resolves the tool name against a TOTAL map of tool name to required
scope, required role, or an explicit `unrestricted` marker, rendered into the
policy by `templatefile()`. Any tool name with no map entry is denied.
Default-deny is the whole point of the map being total: it is not a list of
forbidden tools, it is a list of the only tools that can be invoked.

### D3. Map provenance follows tool-surface ownership

The map has two provenances, and the difference between them is the spine of this
decision. It is a difference in WHO OWNS THE TOOL SURFACE, not in where policy
attaches. Policy attaches identically for both server types, at server scope,
because no other scope exists (COMPATIBILITY.md, "APIM MCP server policy scope
(both server types)", 2026-07-27). Anyone reading this ADR as "export servers get
per-tool policies and passthrough servers do not" has read it backwards.

- **Passthrough (implemented here).** The BACKEND owns the tool definitions. The
  Functions MCP extension registers tools at startup; the gateway learns nothing
  about them. The gateway therefore keeps a HAND-MAINTAINED second copy of the
  tool surface, as a Terraform map
  (`infra/terraform/scenarios/s2-apim-mcp-gateway/variables.tf`,
  `tool_authorization_map` and `server_2_tool_authorization_map`). A second copy
  of a fact owned elsewhere can drift from it. Nothing structural prevents that
  drift, so it is caught behaviourally instead: the live gate reads `tools/list`
  from each deployed server and asserts SET EQUALITY against that server's map
  keys, failing on a difference in either direction. An unmapped returned tool
  would be silently default-denied in production; a mapped name with no returned
  tool is a renamed or removed tool and a dead policy branch. The comparison runs
  as a pinned, fully-granted identity, stated explicitly in the assertion, so it
  does not silently weaken if tool exposure ever becomes caller-dependent.
- **REST-export (#58, described here, not built).** The GATEWAY owns the tool
  surface: the tools ARE the selected operations. The map is derived in Terraform
  from the same operation list that defines the tools, so the map and the tool
  surface are two renderings of one source. Drift is structurally impossible
  there, and the set-equality assertion becomes a tautology-check rather than a
  drift-detector. It is kept anyway, because it costs nothing and because it is
  the assertion that would catch a derivation bug.

The fragment is agnostic to provenance. It consumes a rendered
tool-name-to-claim map as an INPUT
(`infra/terraform/modules/apim-mcp-server/variables.tf`,
`tool_authorization_map`), and both provenances feed it unchanged. That is why
#58 is a thickening of this decision rather than a prerequisite for it, and why
this ADR can be written and accepted before #58 exists.

### D4. Enforce without concealing

The gateway ENFORCES but does not HIDE. `tools/list` returns every tool's name
and input schema to every caller who reaches this server, whether or not that
caller can invoke it. A caller who cannot invoke `get_order_status` still sees
`get_order_status` and its schema, and learns it is forbidden only by calling it
and being denied.

This is a choice, and it is made on two grounds.

**Concealment is unachievable at the gateway on the passthrough path.** Filtering
`tools/list` means rewriting a response body, and Microsoft Learn states plainly:
"Don't access the response body by using the `context.Response.Body` variable
within MCP server policies. Doing so triggers response buffering, which
interferes with the streaming behavior required by MCP servers."
(COMPATIBILITY.md, "APIM MCP server response-body access in policies", verified
2026-07-27,
https://learn.microsoft.com/azure/api-management/expose-existing-mcp-server#configure-policies-for-the-mcp-server).
The alternative, filtering at the backend where tool registration happens, was
not available either: the Functions MCP extension registers tool metadata at
startup and no per-request hook was found, and that negative is recorded as
UNVERIFIED rather than asserted. So concealment at the gateway is not a thing
this repo declined to build; it is a thing the documented platform constraint
forbids on this path.

**Where concealment IS genuinely required, this repo already has the mechanism:
partition the tools across separate MCP server instances with per-server scopes.**
That is the issue-17 primitive, already built and live-gate-proven in this
repository: each server gets its own path-inserted PRM document, its own
delegated scope, its own app role, and its own entitlement check (ADR-006,
"Multi-server composition (issue 17)"). A caller lacking server 2's scope is
rejected at server 2's entitlement check and never reaches its `tools/list` at
all. Concealment at server granularity is available today; concealment at tool
granularity within one server is not.

**The cost of that escape hatch, stated honestly, because it differs by
provenance.** On the passthrough path, partitioning requires duplicating the
BACKEND, not just adding a gateway configuration block: the tool surface is
backend-owned, so a second server with a different tool surface means a second
Functions app (or at minimum a second, separately-deployed tool registration)
behind it. That is a deployment-topology change, not a config change. On the
export path (#58), partitioning is a config-level operation selection over ONE
shared backend: two MCP servers, two operation subsets, one Orders API. The
asymmetry is the same surface-ownership asymmetry as D3, showing up a second
time, and it is the reason "just partition it" is cheap advice for export servers
and expensive advice for passthrough ones.

**The named non-goal, with its cause.** Tool names and input schemas remain
visible to callers who cannot invoke them. Two real costs follow: a wasted
round-trip on the denied call, and the per-turn context an agent spends carrying
schemas for tools it can never use. Both are currently ZERO here, because this
server exposes exactly one tool. They are not zero at a realistic tool count, and
that is the condition under which this decision should be revisited (see
Trigger).

### D5. Audit every deny, to a sink that outlives the environment

Every deny emits exactly one audit event, dimensioned by caller and tool, before
the deny response is returned.

**Why the sink is provisioned out of band, and not by the s2 composition.** The
audit record needs somewhere durable to land. The live-test environment is
ephemeral by construction: `.github/workflows/ephemeral-env.yml` creates a
per-run resource group (`rg-mcp-tracer-<run_id>`) with a 4-hour expiry tag and
deletes it at the end of the run, verifying the deletion. Anything the s2
composition creates dies with that resource group. An audit trail that is
destroyed at the end of every run cannot demonstrate an audit trail; worse, it
would teach exactly the wrong lesson for a repository whose subject is enterprise
governance.

The Log Analytics workspace and Application Insights resource are therefore
provisioned OUT OF BAND, in their own resource group, outside the ephemeral
lifecycle, by a runbook rather than by the s2 Terraform. This is not a new
pattern in this repo; it is the third instance of one already established twice:

- The Terraform state storage account is bootstrapped out of band in its own
  resource group specifically "so this run's cleanup can never reach it"
  (`.github/workflows/ephemeral-env.yml`).
- The Entra app registrations are created once by a documented manual runbook and
  survive every teardown (`docs/runbooks/entra-app-registrations.md`; the same
  pattern in `docs/runbooks/obo-app-registrations.md`).

The rule those three share is worth stating as a rule, because it will come up
again: **an object whose VALUE depends on outliving the environment does not
belong to the environment's lifecycle.** State, identity, and audit all qualify.
Compute, gateway, and policy do not.

The mechanism, the roles, and the separate gate-verification path are described
under "How it is built" below.

## How it is built

This section is mechanism, not decision. A reader who only needs the
architecture can stop at the end of the Decision section.

### The policy fragment

The fragment gates `tools/call` only. It reads the JSON-RPC request body once
(`context.Request.Body.As<JObject>(preserveContent: true)`), and every other
JSON-RPC method, `tools/list` included, falls through unchanged. It resolves the
tool name primarily from the documented `gen_ai.tool.name` context variable,
which Microsoft Learn documents as an MCP telemetry dimension populated on every
`tools/call` request, with a fallback to the already-parsed body's `params.name`
(COMPATIBILITY.md, "APIM `gen_ai.tool.name` context variable", 2026-08-06,
https://learn.microsoft.com/azure/api-management/monitor-mcp-servers#mcp-telemetry-reference).
Both mechanisms are built deliberately, per operator decision on 2026-08-06: the
live gate settles which one fires on this preview surface, and the unused path is
pruned afterwards. The fragment's CONTRACT is independent of which one wins, so
that pruning is not an architectural change.

### The deny wire shape

A denial is a JSON-RPC 2.0 Protocol Error: HTTP 200, the request `id` echoed, an
`error` object with code -32001 (a custom code in the MCP-reserved -32000 to
-32099 range) and an RFC 6750 `insufficient_scope` message. It is NOT a
`CallToolResult` with `isError: true` (that tier is reserved for failures during
actual tool EXECUTION, and this call never executed), and NOT an HTTP 401/403
ahead of any JSON-RPC envelope (that tier is reserved for transport and session
violations). This was verified directly against the MCP specification revision
2025-06-18, not against Microsoft Learn; the full derivation, including why
-32602 "Unknown tool" would misdescribe a mapped-but-under-entitled denial, is
recorded in COMPATIBILITY.md, "MCP tools/call denial wire shape", 2026-08-06
(https://modelcontextprotocol.io/specification/2025-06-18/server/tools#error-handling
and https://modelcontextprotocol.io/specification/2025-06-18/basic/transports).

One consequence of that shape is architectural rather than incidental: there is
ONE deny path for both the unmapped and the under-entitled case, and the wire
response does not distinguish them. That is consistent with non-concealment (D4)
being a posture about the tool LIST rather than about individual denials, and it
keeps the deny path single, which is what the gate asserts against. Operators who
need to tell the two cases apart use the audit event, which carries the tool
name.

### The audit event, and the roles that carry it

The audit mechanism is an APIM `<trace>` element with `severity="error"`, placed
directly in `<inbound>` immediately before the deny `<return-response>`.

Three properties of that mechanism are load-bearing and were verified rather than
assumed (COMPATIBILITY.md, "APIM trace policy for custom audit telemetry",
2026-08-06, https://learn.microsoft.com/azure/api-management/trace-policy):

- **It is not sampled.** Every invocation of the policy is logged. An audit
  stream that Application Insights sampling could thin is not an audit stream;
  this is why `<trace>` was chosen over any telemetry mechanism subject to
  sampling.
- **`severity` is a monotonic gate, not an exact-match contract.** APIM records a
  trace only when the trace's severity is at or above the diagnostic setting's
  configured verbosity. `severity="error"` is the MAXIMUM tier, so it clears that
  gate at ANY verbosity the diagnostic setting is configured to (verbose,
  information, or error). See Appendix B, correction 1.
- **`on-error` is not an option.** The documented policy sections for `<trace>`
  are `inbound`, `outbound`, and `backend`. The audit event therefore cannot be
  deferred to `on-error`; it sits inline in `inbound`, matching the placement the
  issue-17 entitlement check already established.

**How APIM reaches the sink.** The APIM service already has a system-assigned
managed identity (`infra/terraform/modules/apim-gateway/main.tf`,
`managed_identities`; the principal id is already an output). That identity is
granted Monitoring Metrics Publisher on the cross-resource-group Application
Insights resource, which is the documented requirement for managed-identity
credential mode. The cross-resource-group arrangement itself is documented and
supported: "The Application Insights resource can be in a different subscription
or even a different tenant than the API Management resource" (COMPATIBILITY.md,
"APIM cross-resource-group Application Insights logger", 2026-08-06,
https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights#prerequisites).
The cross-tenant caveat on that page (the portal wizard cannot do it) is moot
here, because this repo provisions through `azapi`/`azurerm` and never the
portal.

The traces land as Trace telemetry (`traces` / `AppTraces`), not `customEvents`,
and are queryable per deny, dimensioned by caller (`oid`, falling back to `azp`)
and tool.

### The audit-event pass/fail check: a second signal, not a replacement

Everything above is unchanged and remains true: the `<trace>` element still fires
on every deny, and the Application Insights sink is still the durable,
human-reviewable audit trail, still provisioned out of band for the reason given
in D5.

What changed is which signal the LIVE GATE reads to decide pass/fail. Through
issue-18's first nine live-gate rounds the gate polled Application Insights with
a bounded-timeout KQL query after each deny. Application Insights ingestion
documents no latency SLA at all, and real measured latency ranged from ~286s to
over 600s across three independent rounds, non-deterministically. No fixed
timeout is provably safe against an undocumented, unbounded latency
characteristic. The full record of that saga, including every measurement, is
Appendix A.

The fix was not a better timeout. It was a second delivery path with a different
latency characteristic. The policy fragment now ALSO emits the same tool/caller
pair via an independent policy element, `<log-to-eventhub>`, to an EPHEMERAL
Event Hub namespace (Basic tier, single partition) provisioned by the s2
composition itself. Unlike the Application Insights resource this one is NOT out
of band, because nothing about it needs to outlive the run that produced it: no
human ever reads it, and the live gate that does read it runs entirely within
that run's own lifetime. That is D5's rule applied correctly, not an exception to
it.

The live gate (`tests/integration/discovery-assertions.ps1`,
`Assert-AuditEventEmitted`) reads the Event Hub with a short bounded wait
(`scripts/gate/wait_for_eventhub_audit.py`, using the `azure-eventhub` SDK, since
`az` CLI has no Event Hubs data-plane receive command) instead of the KQL query.
Managed-identity credential mode throughout, matching the Application Insights
logger's pattern exactly (no connection string or key in the repo): the APIM
identity holds Event Hubs Data Sender on the Event Hub, and the live gate's OIDC
principal holds Event Hubs Data Receiver, both via the same
`data_reader_principal_ids` variable already used for the Application Insights
path (extended, not duplicated).

This is D3's "surface ownership, not policy attachment point" spine applied one
level down. The AUDIT TRAIL and the GATE VERIFICATION are two different consumers
with two different requirements (durability and human readability, versus bounded
latency within one run). Conflating them into one sink was the actual defect. Not
the KQL, not the timeout: the coupling.

## Constraints accepted

### Deployment coupling

Default-deny plus the set-equality gate assertion means that ADDING A TOOL TO THE
FUNCTIONS BACKEND FAILS INFRASTRUCTURE CI until the Terraform map is updated in
the same change. That is intended. It is the mechanism that converts "the
hand-maintained map might drift" from a standing risk into a build failure.

It is correct ONLY under a condition this ADR names and accepts: the Functions
app and the Terraform map must move together, in the same deployment unit. In
this repository they do (one repo, one gate, one apply, and the gate runs both
compositions against one ephemeral environment). Under independent deployment
cadences, with the backend shipped by one pipeline and gateway configuration by
another, the same design produces a PRODUCTION DENIAL THAT CI NEVER SAW: the new
tool goes live, the map does not know about it, and every call to it is
default-denied by a gate that was green.

This is a real constraint this repo is choosing to accept, with its eyes open,
because the alternative (default-allow, discussed under Alternatives) trades a
loud coupling failure for a silent authorization failure. Any estate that adopts
this fragment under split deployment cadences must either adopt the coupling or
adopt the escape hatch below, and should not discover the choice in production.

### Escape hatch: per-server default-allow, documented and NOT built

If a real estate genuinely cannot accept the coupling above, the relaxation is a
PER-SERVER default-allow, expressed as an explicit configuration opt-in on that
server's module instantiation: unmapped tool names fall through to the per-server
entitlement check instead of being denied.

Two constraints on its shape, recorded now so a future implementation does not
get them wrong:

- It is **never a global fallback**. A gateway-wide or fragment-wide
  default-allow would silently weaken every server, including ones whose
  operators never asked for it, and would make the security posture of a server a
  property of the gateway rather than of the server. Per-server, explicit, opt in,
  visible in that server's Terraform block.
- It **does not disable the set-equality assertion**. A default-allow server
  still asserts that its map matches its tool surface; the assertion is a drift
  detector, and drift is MORE interesting, not less, when the consequence of an
  unmapped tool is silent admission rather than loud denial.

This escape hatch is described here for completeness. It is NOT implemented, and
implementing it is explicitly out of scope for issue #18.

## Growth path: derived provenance (#58), described and not demonstrated

The derived (REST-export) map provenance described under D3 is a NAMED GROWTH
PATH. It is anticipated by this ADR, and the fragment's input contract was
designed for it, but it is not demonstrated by anything running: there is no
REST-export MCP server in this repository today, and no derived map has been
rendered, deployed, or gated.

This ADR states that plainly rather than describing the design as if it existed,
following the ADR-006 precedent directly. ADR-006's "Growth paths" section named
the path-suffixed PRM router and hostname-per-server as options with their
trade-offs, at a point when neither was built; issue 17 then landed one of them
and AMENDED that ADR to record what had actually been proven, including
correcting a prediction that had gone stale in the meantime. The same mechanic
applies here: **issue #58 amends THIS ADR** to flip the derived half from
described to demonstrated, and to correct anything in D3 that the implementation
refutes. Until then, the Status line at the top of this document is the accurate
summary, and no reader should take "the map is derived from the operation list"
as a description of running code.

## Out of scope for this ADR

- **Policy ordering and buffering with Content Safety (#19).** The spec's
  standing note is that the ordering and buffering constraints shared by #18 and
  #19 are designed and documented in whichever of the two lands SECOND. #18 lands
  first, so those constraints are genuinely undecided at the time of writing and
  belong to #19. What #18 fixes is only the intent: the per-tool authorization
  fragment runs BEFORE content safety, so denied and unmapped calls never spend a
  Content Safety transaction. The mechanics of making that ordering work
  alongside a second body-reading policy are #19's to establish, not this ADR's
  to guess at.
- **`tools/list` filtering, concealment mechanisms, and posture toggles.** No
  toggle is built; see D4 for why, and for the mechanism that exists where
  concealment is genuinely required.
- **Backend changes.** The MCP-layer app-role check is unchanged by this ticket.

## Trigger

Revisit this decision if any of the following becomes true:

- (a) APIM gains a genuine per-tool or per-operation policy scope for MCP
  servers, which would replace the map lookup with native attachment and retire
  the drift problem entirely.
- (b) A server's tool count grows to the point where the per-turn context cost of
  advertising unusable schemas is measurable, which is the condition under which
  non-concealment stops being free.
- (c) The Functions MCP extension gains a per-request tool-registration hook,
  which would make backend-side `tools/list` filtering achievable and reopen the
  concealment question on the passthrough path.
- (d) An adopting estate deploys the Functions app and the Terraform map on
  independent cadences, which invalidates the deployment-coupling condition above
  and forces the escape-hatch choice.

## Consequences

**C1. A gateway denial is a FOURTH error surface.** It extends the three-surface
contract ADR-006 records under "Request outcomes: HTTP status vs MCP errors": a
gateway-layer rejection that never reaches the backend, arriving as an HTTP 200
JSON-RPC protocol error. A robust client already had to inspect HTTP status, the
JSON-RPC `error` object, and `isError` independently; this adds a case to the
second of those, not a fourth thing to inspect. The error-taxonomy documentation
is extended by this ticket in `docs/mcp-request-flow.md`, with the overlap
against issue #52's error-contract section deduplicated there rather than
restated here.

**C2. The map is a maintenance obligation on the passthrough path**, and its only
defence is the gate. Anyone adding a tool to `src/McpTools` must add a map entry
in the same change or CI fails. That is the design working, and it will read as
friction the first time someone hits it.

**C3. The audit sink is a persistent, human-provisioned dependency** of the live
gate's audit assertions, in the same class as the Terraform state storage account
and the Entra app registrations. It bills continuously (a Log Analytics workspace
with no ingestion is nearly free, but it is not zero), and it is not re-created
by any apply. Its runbook is the only record of how it came to exist.

**C4. The `severity`/verbosity relationship is robust, not a silent-failure
mode.** The only way this audit event drops is the diagnostic setting's
Application Insights integration being disabled outright, which is a loud,
visible configuration change, not a silent one. The gate still asserts that every
deny emits its audit event; that assertion is worth keeping as a regression
check, just not on the premise that it guards a fragile coupling. See Appendix B,
correction 1.

**C5. Two enforcement layers must be kept in step conceptually, not
mechanically.** The gateway map gates on `Orders.Read` for `get_order_status`,
and `AppRoleAuthorization.RequiredRole` is the same string in the backend. They
are two independent statements of the same requirement, deliberately not shared
through a common source, because sharing would make a single edit weaken both
layers at once and destroy the defense-in-depth property. The cost is that they
can disagree; the mitigation is that disagreement fails CLOSED in the direction
that matters (a caller denied at the gateway never reaches the backend, and a
caller admitted by a too-permissive gateway map still faces the backend check).

The operational consequence of that sameness, recorded on 2026-08-07: because
both layers name `Orders.Read` for `get_order_status`, the gateway ALWAYS denies
first on the gateway path, so a caller under-entitled for this tool is
under-entitled at BOTH layers and the backend check becomes unreachable through
APIM. Any test that intends to prove the BACKEND layer for this tool must
therefore call the backend hostname directly. The live gate does exactly that and
keeps the two proofs separate:

| Layer | Proven by | Path |
| --- | --- | --- |
| Backend (`AppRoleAuthorization.HasOrdersRead`, issue #45) | `scripts/gate/invoke-and-assert.ps1` step [3] | Functions host directly, `$BackendMcpUrl` |
| Gateway (per-tool map, issue #18) | `tests/integration/discovery-assertions.ps1` check [9]-d, `Assert-ToolAuthorization`'s `UnderEntitledToken` branch | Through APIM |

Step [3] was retargeted at the backend by commit `e6f8967` (shipped in PR #74)
after it began failing on the gateway's `-32001` protocol error. The runbook
consequence for the negative-test client's Entra grants is recorded in
`docs/runbooks/entra-app-registrations.md`, section 3.

**C6. Nothing here changes the shared-audience non-conformance.** Per-tool
authorization gates on `scp`/`roles` values within one audience, exactly as the
per-server check does. The audience-binding deviation and its owner (issue #42)
are unchanged by this decision, and this ADR must not be read as narrowing it.

## Alternatives considered

- **Server-enforced per-tool authorization only (no gateway layer).** Rejected.
  It puts every authorization decision behind the backend's execution boundary:
  an unauthorized call still becomes a Functions invocation, still costs a
  Content Safety transaction once #19 lands, and is audited per-server rather
  than at the shared control point. Most decisively, it does not generalise to a
  server whose backend this repo does not own, which is the REST-export case #58
  adds. It was not rejected as WRONG, though, which is why the MCP-layer check
  survives as the second layer rather than being removed.
- **Gateway-enforced only (removing the MCP-layer app-role check).** Rejected.
  The Functions backend is directly reachable on its own hostname, so removing
  the backend check would make the gateway a bypassable single point of
  authorization. It would also mean a failed policy deployment silently opens
  every tool.
- **Concealment: filter `tools/list` at the gateway.** Rejected as unachievable,
  not as undesirable. It requires response-body access, which Microsoft Learn
  documents as breaking MCP streaming (COMPATIBILITY.md, 2026-07-27). The
  substitute where concealment is genuinely required is server partitioning, and
  its real cost on the passthrough path is stated in D4 rather than glossed.
- **Default-allow for unmapped tools.** Rejected as the default. It removes the
  deployment-coupling friction described above, and pays for it with a silent
  authorization hole: a tool added to the backend is immediately invocable by
  anyone who cleared the per-server check, and nothing in CI or at runtime says
  so. A loud coupling failure is strictly better than a silent authorization
  failure. Retained only as a documented, per-server, explicitly-opted-into
  escape hatch, and not built.
- **A fixed list of expected tool names in the gate instead of set equality.**
  Rejected. A fixed list is correct at one server and one tool, and quietly wrong
  at the second of either; it also cannot detect a mapped name whose tool no
  longer exists (a dead policy branch). Set equality, expressed as a loop over
  the server instances, is correct at two servers, at three when #58 lands, and
  at ten, and #58 inherits it without editing #18's gate.
- **A sampled or metrics-based audit mechanism instead of `<trace>`.** Rejected.
  Application Insights sampling can thin telemetry, and an audit record that may
  or may not exist is not an audit record. `<trace>` is documented as unaffected
  by sampling: every invocation of the policy is logged (COMPATIBILITY.md,
  2026-08-06).
- **Provisioning the audit sink inside the s2 composition (Terraform-managed).**
  Rejected. The ephemeral resource group is deleted at the end of every live-gate
  run, so a Terraform-managed workspace would be destroyed along with the
  evidence it holds. Out-of-band provisioning follows the precedent already set
  twice in this repo for state and identity.
- **Emitting the audit event from `on-error` instead of inline in `inbound`.**
  Rejected on documented grounds, not preference: `<trace>`'s documented policy
  sections are `inbound`, `outbound`, and `backend`; `on-error` is not among them
  (COMPATIBILITY.md, 2026-08-06).
- **Widening the Application Insights KQL timeout again.** Rejected. See
  Appendix A; the timeout was widened twice (300s, then 600s) and exceeded a
  third time, and no fixed timeout is provably safe against an undocumented,
  unbounded latency characteristic.

## Appendix A: audit-verification engineering log

This appendix is the evidence behind "The gate-verification path is a second
signal, not a replacement". It is kept in full because the numbers in it are
measured, not estimated, and because the repo's rule is to measure and label
rather than to widen a timeout and move on. Nothing here changes the decision;
it is the record of how the decision was tested.

### Rounds 1-9: the Application Insights KQL path, and why it failed

The gate polled Application Insights with a bounded-timeout KQL query after each
deny. That query was CORRECT. Every fix to it was proven correct by direct
re-execution against real data, repeatedly (COMPATIBILITY.md, "Kusto `contains`
operator on a `dynamic` column").

The problem was never the query. Application Insights ingestion documents no
latency SLA at all, and real measured latency ranged from **~286s to over 600s**
across three independent rounds, non-deterministically. A widened timeout (300s,
then 600s) bought headroom twice and was exceeded a third time. Widening it
further would only have been picking a new number to eventually exceed again.

### Round 10-11: the Event Hub bet, and what it actually rests on

`<log-to-eventhub>` is NOT a documented low-latency delivery path. Stating it as
one would be a claim this repo cannot support:

- An `azureEventHub` logger defaults `isBuffered` to `true`.
- Microsoft's "sophisticated buffer" language describes Event Hub decoupling APIM
  from slow DOWNSTREAM consumers, not fast delivery TO the first consumer.
- No numeric latency SLA is documented for `log-to-eventhub`, any more than for
  Application Insights.
- The one documented signal is qualitative: the observability overview's
  feature-comparison table lists "Seconds" of data lag for Event Hub logging
  against "Minutes" for Azure Monitor Logs.

The `eventhub_logger` resource sets `isBuffered = false` explicitly, the
documented direction for reducing buffering, but Microsoft does not state a
timing effect for that flag beyond the binary buffered/not semantic.

So this is an ENGINEERING BET that Event Hub's "Seconds" category will in
practice clear a bounded gate wait more reliably than Application Insights'
undocumented, empirically 286-620s ingestion did. The bet is falsifiable, and
rounds 11-13 are what tested it. See Appendix B, correction 2, for the stronger
claim an earlier draft made here and why it was withdrawn.

### Round 11 (2026-08-07, gate run 31145487738): the bet held, with a caveat

Both the unmapped-probe deny and the under-entitled deny were confirmed via Event
Hub in **~16s**, against the 60s gate timeout. A wide margin, and roughly 18-40x
faster than the Application Insights figures this redesign replaced. `isBuffered`
was still at its default `true`.

### Round 12 (2026-08-07, gate run 31147183034): the FIRST event missed entirely

With `isBuffered = false` live for the first time, the unmapped-probe deny (the
first audit event through that run's freshly created `eventhub_logger`) was
**never observed within 60s**. A real gate failure, not a flake dismissed without
evidence. The under-entitled deny, firing about a second later, was confirmed in
**~5.5s**.

Read together with round 11, whose own first event (~16s) was also the slower of
its two, the pattern across both rounds is: first use of a freshly created
`eventhub_logger` is the slow/at-risk case; a subsequent use moments later is
fast every time.

That reads as a cold-start effect on APIM's connection to a brand-new Event Hub,
NOT as evidence that `isBuffered = false` is itself the regression. Each
configuration has exactly one data point, confounded with being first-vs-second
use within its own run. Per this ADR's own rule (measure and label, do not just
widen the timeout), the fix is structural, not a bigger number: the live gate now
fires one throwaway, non-gated warm-up deny before check 9's timed assertions
run, moving the cold-start cost out of the checks that decide pass/fail
(`tests/integration/discovery-assertions.ps1`).

### Round 13 (2026-08-07, gate run 31148903377): the warm-up fix confirmed

With the throwaway warm-up deny firing before check 9's timed assertions, the
warm-up itself absorbed the cold-start cost (**~7.6s** to its own, non-gated
audit confirmation), and BOTH real gating checks that followed were fast and
consistent: unmapped-probe deny **~7.1s**, under-entitled deny **~6.1s**, against
the 60s timeout, with `isBuffered = false` still in effect. This is check (c)
specifically, the one that overran 60s entirely in round 12, now passing
comfortably once it is no longer the first event through the logger.

### The pattern across all three rounds

| Round | First event through a fresh logger | Subsequent events | `isBuffered` |
| --- | --- | --- | --- |
| 11 | ~16s | ~16s | `true` (default) |
| 12 | >60s (gate failure) | ~5.5s | `false` |
| 13 | ~7.6s (warm-up, non-gated) | ~7.1s, ~6.1s | `false` |

Three rounds in, the pattern holds without exception: whichever event is first
through a freshly created `eventhub_logger` is the one at risk; every subsequent
event has been fast, independent of `isBuffered`. See COMPATIBILITY.md, "APIM
`log-to-eventhub` policy", for all three rounds' measurements and their caveats.

## Appendix B: corrections to earlier drafts of this ADR

These corrections are recorded rather than silently overwritten, because two of
them were produced by independent re-verification refuting a confident claim this
document had already made, and that is exactly the failure mode the repo's
verification rules exist to catch. The body above states the CORRECTED position
only; a reader who needs no history can ignore this appendix entirely.

**Correction 1 (severity/verbosity).** An earlier draft described the
`severity`/verbosity relationship as requiring an exact match, and called it "the
single most fragile thing in the audit design". A later draft described denies as
silently unaudited if verbosity is "raised above `error`". Both are wrong.
Verbosity is ordered verbose < information < error, so `error` is already the
strictest/highest tier the enum has, and a trace at `severity="error"` clears the
gate at every configurable verbosity. "Raised above `error`" describes an
impossible state. The relationship is robust precisely because `error` is the
ceiling (COMPATIBILITY.md).

**Correction 2 (Event Hub latency).** An earlier draft claimed Event Hub delivery
has "no batching or ingestion indirection between the policy firing and a
consumer reading it". Independent re-verification refuted that (COMPATIBILITY.md,
"APIM `log-to-eventhub` policy"). The withdrawn claim asserted a documented
property; what actually exists is one qualitative comparison table and an
`isBuffered` flag with no documented timing effect. The body and Appendix A now
present this as an engineering bet, which is what it is.

**Correction 3 (interception order).** Before 2026-08-07 this ADR recorded that
the two enforcement layers use the same `Orders.Read` string deliberately, but
did not record the operational consequence: that the gateway therefore always
denies first on the gateway path, making the backend layer unreachable through
APIM for this tool. Issue #76 read the un-amended text and concluded, incorrectly,
that the backend-layer proof had become dead code. The consequence is now stated
in C5. No decision changed; the record was incomplete rather than wrong.

## Close-out: cross-tool differentiation (issue #80)

Issue #76 identified a real gap in this ADR's live proof: every gate check
through round 13 exercised only ONE tool (`get_order_status`), so none of them
could show that per-tool authorization actually differentiates between tools.
A caller either had the one checked role or did not; nothing distinguished
"denied because wrong tool" from "denied because no role at all". Issue #79
added a second tool (`get_service_info`, role `ServiceInfo.Read`) so a
cross-tool proof became possible; issue #80 wrote it.

**What is now proven, both directions, on both server instances.** A caller
entitled to `get_order_status` (`Orders.Read`) and NOT to `get_service_info`
(`ServiceInfo.Read`) is denied `get_service_info` (check (e)). A caller
entitled to `get_service_info` and NOT to `get_order_status` succeeds on
`get_service_info` (check (f), a positive result assertion, not merely the
absence of a `-32001`) and is denied `get_order_status` (check (g)). All three
run on server 1 as gating checks and on server 2 as `WarnOnly`, the same
split (b) through (d) already used, because server 2's caller entitlement
remains out-of-band to this gate (ADR-006, "Multi-server composition"). This
closes #76's stated gap: entitlement for one tool on a server does not carry
over to another tool on the SAME server, shown by direct assertion rather than
inferred from the single-tool checks.

**What remains unproven, and why this gate cannot close it.** The
`tool_authorization_map`'s policy fragment supports three claim shapes per
tool: `role`, `scope`, and `unrestricted` (D2 above). Checks (b), (d), (e),
(f), and (g) exercise `role`; (c) exercises the map's default-deny path, which
fires for a tool name with no map entry at all rather than for any claim shape.
Issue #82 added a third tool, `get_access_guidance`,
mapped `unrestricted`, and gate check (h) asserts that the under-entitled
client of `docs/runbooks/entra-app-registrations.md` section 3 calling that
tool gets a real result back rather than a `-32001`. That check ran green on
2026-08-09 (run
[31314241913](https://github.com/collaborationwithothers/mcp-platform-azure/actions/runs/31314241913),
commit `27e30c4`): check (a) reported the map and `tools/list` equal at three
tools, and check (h) reported `get_access_guidance` succeeding with the
under-entitled token, with a real result and `isError` not set. The
`unrestricted` branch is therefore exercised rather than merely rendered. That
leaves `scope` as the only shape no LIVE GATE check covers, and it is
unprovable by THIS gate as constructed. The gate's tokens are all
client-credentials tokens, and client-credentials tokens carry no `scp` claim
at all (ADR-006, "OBO exchange" and the delegated-token discussion). A `scp`
claim requires a delegated, user-context token, which no non-interactive CI
mechanism can acquire. Proving the `scope` branch needs either an interactive
token source or a different test harness, not a new Entra client. See
"Close-out: the delegated scope branch (issue #83)" below for how that gap is
actually closed -- by two different mechanisms, neither of which is the live
gate.

**What `unrestricted` relaxes, stated exactly, because the word invites a
larger reading than the branch deserves.** It drops the per-TOOL entitlement
check, and nothing else. A caller still needs a valid token for the server's
audience, which `validate-azure-ad-token` checks before any per-tool logic
runs. The per-SERVER entitlement check still applies one layer earlier: on
server 1 that is `Orders.Invoke.All`, or the matching scope under the same
OR semantics, and a caller holding neither is refused before the map is read at
all. The backend's Easy Auth still validates the token independently and
injects the client principal. And the tool itself still resolves that principal
and fail-closed rejects a caller it cannot identify
(`src/McpTools/Tools/GetAccessGuidance.cs`). Unrestricted is not
unauthenticated; it is one check fewer, at one layer.

That per-server check is also why check (h) runs on server 1 only, and why the
absence of a server 2 result is deliberate rather than an oversight. The
under-entitled client holds `Orders.Invoke.All` and nothing for server 2, so at
server 2 its token is refused at the per-server check one layer before the
per-tool map is consulted. A success assertion there could never pass, and
running it `WarnOnly` would print a permanent warning that says nothing. If a
future client is granted both servers' entitlements, the same check covers
server 2 unchanged.

**Audit events were deliberately not extended to checks (e) and (g).** The
audit-event mechanism itself is already proven, twice, by checks (c) and (d)
(Appendix A). Each additional Event Hub read adds a bounded 60s wait to the
gate, and rounds 11 and 12 (Appendix A) showed Event Hub delivery timing is the
single most fragile part of this gate, once even failing the run outright.
Issue #80 judged two more reads, proving nothing the existing two do not
already prove, not worth that risk. Check (f), the one new SUCCESS case, has
no deny to audit in the first place.

## Close-out: the delegated scope branch (issue #83)

### Widening `get_order_status`

`get_order_status`'s `tool_authorization_map` entry now carries a delegated
scope, `Orders.Read.AsUser`, alongside its existing role, `Orders.Read`,
OR-checked exactly as the per-server entitlement check already is. This is a
real widening, confirmed by Hari on issue #83 before implementation, not a
side effect of wanting a testable code path: a delegated (human-signed-in)
caller who holds the scope can now call `get_order_status` without holding the
`Orders.Read` role, which is more access than existed before this change.

The alternative considered and rejected was reusing `Orders.Invoke`, the
scope the per-server check already demands. It costs no new Entra object, but
it makes the per-tool check re-ask a question the per-server check already
answered: every delegated caller who reaches the tool check at all would pass
it. That proves the code path executes and never that it can refuse, and a
future tool copying the same pattern would make per-tool authorization on the
delegated path decorative rather than real. `Orders.Read.AsUser` keeps a
genuine negative case constructible: a caller holding `Orders.Invoke` alone is
still refused.

**Naming departure, stated plainly.** This repo's convention elsewhere is a
delegated scope `X.Y` paired with an application role `X.Y.All`
(`docs/runbooks/entra-app-registrations.md` section 1a). `Orders.Read.AsUser`
does not follow it, because it cannot: Entra rejects a scope whose value
duplicates an existing app role value on the same application ignoring case,
and `Orders.Read` is already `get_order_status`'s backend role
(`AppRoleAuthorization.RequiredRole`). The convention-clean alternative --
renaming the role to `Orders.Read.All` and the scope to `Orders.Read` -- was
rejected for this ticket. It reaches into the C# constant, the live app
registration, the negative-test client grants (section 3), and gate checks
(e) through (g), all to fix a naming inconsistency this ADR would rather just
name than pay to remove.

### What now closes the evidence gap, and what still does not

Two separate mechanisms close this, and neither is the live gate, which
remains structurally unable to acquire a delegated token (ADR-006).

1. **Rendering, PR-blocking, automated.** A `terraform test` fixture
   (`infra/terraform/modules/apim-mcp-server/tests/policy-rendering/`) calls
   `templatefile()` on the real `mcp-server.xml` with a fixture map covering
   all four claim shapes -- role only, scope only, scope and role together,
   unrestricted -- and asserts the generated switch-case expression for each.
   It runs as a step in the required `terraform-checks` CI job. This proves
   the `scope` shape renders correctly; it proves nothing about a real caller,
   because it has no provider, no backend, and no token of any kind.
2. **Execution, human-run, evidenced.** `docs/demos/obo-happy-path.md`
   extends the existing OBO device-code procedure into a matched pair: a
   client holding `Orders.Invoke` and `Orders.Read.AsUser` succeeds on
   `get_order_status` (the scope branch actually admits a caller); a second
   client holding `Orders.Invoke` only is refused with the same `-32001` a
   role-only caller without `Orders.Read` would get. A single client cannot
   produce both tokens -- Entra returns every scope a client is consented for
   on a resource, regardless of what a given token request names (verified
   against Microsoft Learn, 2026-08-10) -- so this needs two client app
   registrations
   (`docs/runbooks/entra-app-registrations.md` sections 4 and 4a), not two
   requests from one.

Whether mechanism 2 has actually been run, and when, is authoritative only in
that file's own "Captured evidence" section, by date. This ADR does not
restate it, to avoid the same drift already corrected once in
`docs/runbooks/live-test-tfvars-reference.md`: a claim recorded in two places
only has to go stale in one of them.

### The layer asymmetry this widening makes load-bearing

For an app-only caller, per-tool entitlement is checked twice: once at the
gateway (`tool_authorization_map`), once again in the backend
(`AppRoleAuthorization`, issue #45). For a delegated caller it is checked
once. `GetOrderStatus.Run` calls `AppRoleAuthorization.HasOrdersRead` only on
its `AppContext` branch; the `Delegated` branch goes straight to the OBO
exchange with no per-tool check of its own
(`src/McpTools/Tools/GetOrderStatus.cs`). Before this widening that asymmetry
was inert -- a delegated caller could never reach the tool at all, so the
backend's missing second check never mattered. After it, the gateway's
`tool_authorization_map` is the ONLY thing standing between a delegated
caller and this tool, for every future scope anyone adds to this or any other
row.

The downstream "Assignment required" gate (issue 53) is a real second control
on the delegated path -- live-evidenced in `docs/demos/obo-happy-path.md`,
"Run 2026-07-22" -- but it is not a substitute for a per-tool check and must
not be read as one. It gates whether the OBO exchange succeeds for THIS USER
against the DOWNSTREAM APPLICATION, not whether this user may call THIS TOOL.
A `tool_authorization_map` misconfiguration -- the wrong scope, or a scope on
a tool that should not have one -- would not be caught by it.

Adding a matching per-tool `scp` check to the backend, mirroring
`AppRoleAuthorization`'s existing per-tool role check, would close this
symmetrically. It is explicitly out of scope for issue #83, which decides
what evidence is gathered, not how authorization works. Tracked as issue #98.

## References

- MCP specification 2025-06-18, tool error handling:
  https://modelcontextprotocol.io/specification/2025-06-18/server/tools#error-handling
- MCP specification 2025-06-18, transports:
  https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- Expose an existing MCP server (passthrough), policy configuration and the
  response-body constraint:
  https://learn.microsoft.com/azure/api-management/expose-existing-mcp-server#configure-policies-for-the-mcp-server
- Export a REST API as an MCP server, policy configuration:
  https://learn.microsoft.com/azure/api-management/export-rest-mcp-server#configure-policies-for-the-mcp-server
- Monitor MCP server traffic in API Management, MCP telemetry reference
  (`gen_ai.tool.name`):
  https://learn.microsoft.com/azure/api-management/monitor-mcp-servers#mcp-telemetry-reference
- `trace` policy reference:
  https://learn.microsoft.com/azure/api-management/trace-policy
- Integrate API Management with Application Insights, prerequisites
  (cross-resource-group and managed-identity role requirement):
  https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights#prerequisites
- ADR-006, "Multi-server composition (issue 17)" (the partitioning primitive and
  per-server scopes), "Workload identity hardening: app roles and trusted
  subsystem (issue 45)" (the MCP-layer app-role check), "Request outcomes: HTTP
  status vs MCP errors" (the three error surfaces this decision extends), and
  "Growth paths" (the record-the-decision, name-the-growth-path precedent this
  ADR follows).
- `docs/specs/thickening.md`, "Per-tool authorization and tool blocking (#18)":
  the authoritative spec for this decision.
- COMPATIBILITY.md rows: "APIM MCP server policy scope (both server types)"
  (2026-07-27), "APIM MCP server response-body access in policies" (2026-07-27),
  "APIM `gen_ai.tool.name` context variable" (2026-08-06), "MCP tools/call denial
  wire shape" (2026-08-06), "APIM cross-resource-group Application Insights
  logger" (2026-08-06), "APIM trace policy for custom audit telemetry"
  (2026-08-06), "Kusto `contains` operator on a `dynamic` column", "APIM
  `log-to-eventhub` policy".
