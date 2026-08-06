# ADR-009: Gateway-enforced per-tool authorization

Status: Accepted (issue #18; one provenance implemented, one described)
Date: 2026-08-06

The decision below is accepted in full. Its two halves are NOT equally proven,
and the status says so rather than collapsing them: the enforcement fragment and
the HAND-MAINTAINED (passthrough) map provenance are implemented in the issue #18
PR; the DERIVED (REST-export) map provenance is named here as a growth path,
described and not demonstrated, and is owned by issue #58. This follows the
ADR-006 precedent explicitly (see "Growth path: derived provenance" below):
record the decision when it is made, name the growth path, and let the status
reflect only what a running system has actually proven.

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
MCP servers of EITHER server type; what REST-export provides is static tool
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

### Per-tool authorization is enforced at the gateway, and the MCP-layer app-role check remains a real second layer

Per-tool authorization is enforced by an APIM policy fragment at server scope, in
`inbound`, before the backend is called
(`infra/terraform/modules/apim-mcp-server/policies/mcp-server.xml`). It runs
AFTER the issue-17 per-server entitlement check, so a caller must clear both: the
server-scope check answers "may you reach this server", the per-tool check
answers "may you invoke this tool".

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

It resolves the tool name against a TOTAL map of tool name to required scope,
required role, or an explicit `unrestricted` marker, rendered into the policy by
`templatefile()`. Any tool name with no map entry is denied. Default-deny is the
whole point of the map being total: it is not a list of forbidden tools, it is a
list of the only tools that can be invoked.

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
  across per-server backend logs). It also generalises: it is the ONLY layer that
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
reason to weaken the other. The gateway layer is deliberately NOT given
authority the backend lacks, and the backend layer is deliberately NOT removed
now that the gateway can decide.

### The spine: surface ownership, not policy attachment point

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

### Non-concealment is chosen deliberately, and has a named mechanism where it is genuinely needed

The gateway ENFORCES but does not HIDE. `tools/list` returns every tool's name
and input schema to every caller who reaches this server, whether or not that
caller can invoke it. A caller who cannot invoke `get_order_status` still sees
`get_order_status` and its schema, and learns it is forbidden only by calling it
and being denied.

This is a choice, and it is made on two grounds.

**Concealment is unachievable at the gateway on the passthrough path.** Filtering
`tools/list` means rewriting a response body, and Microsoft Learn states
plainly: "Don't access the response body by using the `context.Response.Body`
variable within MCP server policies. Doing so triggers response buffering, which
interferes with the streaming behavior required by MCP servers."
(COMPATIBILITY.md, "APIM MCP server response-body access in policies", verified
2026-07-27,
https://learn.microsoft.com/azure/api-management/expose-existing-mcp-server#configure-policies-for-the-mcp-server).
The alternative -- filtering at the backend, where tool registration happens --
was not available either: the Functions MCP extension registers tool metadata at
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
asymmetry is the same surface-ownership asymmetry as above, showing up a second
time, and it is the reason "just partition it" is cheap advice for export
servers and expensive advice for passthrough ones.

**The named non-goal, with its cause.** Tool names and input schemas remain
visible to callers who cannot invoke them. Two real costs follow: a wasted
round-trip on the denied call, and the per-turn context an agent spends carrying
schemas for tools it can never use. Both are currently ZERO here, because this
server exposes exactly one tool. They are not zero at a realistic tool count, and
that is the condition under which this decision should be revisited (see
Trigger).

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
and
https://modelcontextprotocol.io/specification/2025-06-18/basic/transports). It is
implementation detail more than architecture, and this ADR does not re-derive it.

One architectural consequence of that shape does belong here: there is ONE deny
path for both the unmapped and the under-entitled case, and the wire response
does not distinguish them. That is consistent with non-concealment being a
posture about the tool LIST rather than about individual denials, and it keeps
the deny path single, which is what the gate asserts against.

### The audit design: a persistent sink, out of band from the ephemeral environment

Every deny emits exactly one audit event, dimensioned by caller and tool, before
the deny response is returned. The mechanism is an APIM `<trace>` element with
`severity="error"`, placed directly in `<inbound>` immediately before the deny
`<return-response>`.

Three properties of that mechanism are load-bearing and were verified rather than
assumed (COMPATIBILITY.md, "APIM trace policy for custom audit telemetry",
2026-08-06, https://learn.microsoft.com/azure/api-management/trace-policy):

- **It is not sampled.** Every invocation of the policy is logged. An audit
  stream that Application Insights sampling could thin is not an audit stream;
  this is why `<trace>` was chosen over any telemetry mechanism subject to
  sampling.
- **`severity` is a fixed contract with the diagnostic setting.** APIM records a
  trace only when the trace's severity is at or above the diagnostic setting's
  configured verbosity. `severity="error"` in the fragment and `error` verbosity
  on the MCP server API's diagnostic setting must match, or the audit event is
  silently dropped. Silently. This coupling is the single most fragile thing in
  the audit design and is why it is written down in both the policy comment and
  here.
- **`on-error` is not an option.** The documented policy sections for `<trace>`
  are `inbound`, `outbound`, and `backend`. The audit event therefore cannot be
  deferred to `on-error`; it sits inline in `inbound`, matching the placement the
  issue-17 entitlement check already established.

**Why the sink is provisioned out of band, and not by the s2 composition.** The
trace needs somewhere durable to land. The live-test environment is ephemeral by
construction: `.github/workflows/ephemeral-env.yml` creates a per-run resource
group (`rg-mcp-tracer-<run_id>`) with a 4-hour expiry tag and deletes it at the
end of the run, verifying the deletion. Anything the s2 composition creates dies
with that resource group. An audit trail that is destroyed at the end of every
run cannot demonstrate an audit trail; worse, it would teach exactly the wrong
lesson for a repository whose subject is enterprise governance.

The Log Analytics workspace and Application Insights resource are therefore
provisioned OUT OF BAND, in their own resource group, outside the ephemeral
lifecycle, by a runbook rather than by the s2 Terraform (companion change in this
PR). This is not a new pattern in this repo; it is the third instance of one
already established twice:

- The Terraform state storage account is bootstrapped out of band in its own
  resource group specifically "so this run's cleanup can never reach it"
  (`.github/workflows/ephemeral-env.yml`).
- The Entra app registrations are created once by a documented manual runbook and
  survive every teardown (`docs/runbooks/entra-app-registrations.md`; the same
  pattern in `docs/runbooks/obo-app-registrations.md`).

The rule those three share is worth stating as a rule, because it will come up
again: an object whose VALUE depends on outliving the environment does not belong
to the environment's lifecycle. State, identity, and audit all qualify. Compute,
gateway, and policy do not.

**How APIM reaches it.** The APIM service already has a system-assigned managed
identity (`infra/terraform/modules/apim-gateway/main.tf`, `managed_identities`;
the principal id is already an output). That identity is granted Monitoring
Metrics Publisher on the cross-resource-group Application Insights resource,
which is the documented requirement for managed-identity credential mode. The
cross-resource-group arrangement itself is documented and supported: "The
Application Insights resource can be in a different subscription or even a
different tenant than the API Management resource" (COMPATIBILITY.md, "APIM
cross-resource-group Application Insights logger", 2026-08-06,
https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights#prerequisites).
The cross-tenant caveat on that page (the portal wizard cannot do it) is moot
here, because this repo provisions through `azapi`/`azurerm` and never the
portal.

The traces land as Trace telemetry (`traces` / `AppTraces`), not `customEvents`,
and are queryable per deny, dimensioned by caller (`oid`, falling back to `azp`)
and tool.

### Deployment coupling: an accepted constraint, not an oversight

Default-deny plus the set-equality gate assertion means that ADDING A TOOL TO THE
FUNCTIONS BACKEND FAILS INFRASTRUCTURE CI until the Terraform map is updated in
the same change. That is intended. It is the mechanism that converts "the
hand-maintained map might drift" from a standing risk into a build failure.

It is correct ONLY under a condition this ADR names and accepts: the Functions
app and the Terraform map must move together, in the same deployment unit. In
this repository they do -- one repo, one gate, one apply, and the gate runs both
compositions against one ephemeral environment. Under independent deployment
cadences (backend shipped by one pipeline, gateway configuration by another) the
same design produces a PRODUCTION DENIAL THAT CI NEVER SAW: the new tool goes
live, the map does not know about it, and every call to it is default-denied by a
gate that was green.

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
  operators never asked for it, and would make the security posture of a server
  a property of the gateway rather than of the server. Per-server, explicit, opt
  in, visible in that server's Terraform block.
- It **does not disable the set-equality assertion**. A default-allow server
  still asserts that its map matches its tool surface; the assertion is a drift
  detector, and drift is MORE interesting, not less, when the consequence of an
  unmapped tool is silent admission rather than loud denial.

This escape hatch is described here for completeness. It is NOT implemented, and
implementing it is explicitly out of scope for issue #18.

### Growth path: derived provenance (#58), described and not demonstrated

The derived (REST-export) map provenance described under "The spine" above is a
NAMED GROWTH PATH. It is anticipated by this ADR, and the fragment's input
contract was designed for it, but it is not demonstrated by anything running:
there is no REST-export MCP server in this repository today, and no derived map
has been rendered, deployed, or gated.

This ADR states that plainly rather than describing the design as if it existed,
following the ADR-006 precedent directly. ADR-006's "Growth paths" section named
the path-suffixed PRM router and hostname-per-server as options with their
trade-offs, at a point when neither was built; issue 17 then landed one of them
and AMENDED that ADR to record what had actually been proven, including
correcting a prediction that had gone stale in the meantime. The same mechanic
applies here: **issue #58 amends THIS ADR** to flip the derived half from
described to demonstrated, and to correct anything in this section that the
implementation refutes. Until then, the status line at the top of this document
is the accurate summary, and no reader should take "the map is derived from the
operation list" as a description of running code.

### Out of scope for this ADR

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
  toggle is built; see "Non-concealment" for why, and for the mechanism that
  exists where concealment is genuinely required.
- **Backend changes.** The MCP-layer app-role check is unchanged by this ticket.

### Trigger

Revisit this decision if any of the following becomes true: (a) APIM gains a
genuine per-tool or per-operation policy scope for MCP servers, which would
replace the map lookup with native attachment and retire the drift problem
entirely; (b) a server's tool count grows to the point where the per-turn context
cost of advertising unusable schemas is measurable, which is the condition under
which non-concealment stops being free; (c) the Functions MCP extension gains a
per-request tool-registration hook, which would make backend-side `tools/list`
filtering achievable and reopen the concealment question on the passthrough path;
or (d) an adopting estate deploys the Functions app and the Terraform map on
independent cadences, which invalidates the deployment-coupling condition above
and forces the escape-hatch choice.

## Consequences

- **A gateway denial is a FOURTH error surface**, extending the three-surface
  contract ADR-006 records under "Request outcomes: HTTP status vs MCP errors": a
  gateway-layer rejection that never reaches the backend, arriving as an HTTP 200
  JSON-RPC protocol error. A robust client already had to inspect HTTP status,
  the JSON-RPC `error` object, and `isError` independently; this adds a case to
  the second of those, not a fourth thing to inspect. The error-taxonomy
  documentation is extended by this ticket in `docs/mcp-request-flow.md`, with
  the overlap against issue #52's error-contract section deduplicated there
  rather than restated here.
- **The map is a maintenance obligation on the passthrough path**, and its only
  defence is the gate. Anyone adding a tool to `src/McpTools` must add a map
  entry in the same change or CI fails. That is the design working, and it will
  read as friction the first time someone hits it.
- **The `severity`/verbosity coupling is a silent-failure mode.** If the
  diagnostic setting's verbosity is ever raised above `error`, denies stop being
  audited and nothing complains. The gate asserts that every deny emits its audit
  event, which is what turns this from a latent silent failure into a caught one;
  that assertion must not be dropped as redundant.
- **The audit sink is now a persistent, human-provisioned dependency** of the
  live gate's audit assertions, in the same class as the Terraform state storage
  account and the Entra app registrations. It bills continuously (a Log Analytics
  workspace with no ingestion is nearly free, but it is not zero), and it is not
  re-created by any apply. Its runbook is the only record of how it came to
  exist.
- **Two enforcement layers must be kept in step conceptually, not mechanically.**
  The gateway map gates on `Orders.Read` for `get_order_status`, and
  `AppRoleAuthorization.RequiredRole` is the same string in the backend. They are
  two independent statements of the same requirement, deliberately not shared
  through a common source, because sharing would make a single edit weaken both
  layers at once and destroy the defense-in-depth property. The cost is that they
  can disagree; the mitigation is that disagreement fails CLOSED in the direction
  that matters (a caller denied at the gateway never reaches the backend, and a
  caller admitted by a too-permissive gateway map still faces the backend check).
- **Nothing here changes the shared-audience non-conformance.** Per-tool
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
  its real cost on the passthrough path is stated above rather than glossed.
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
  (2026-08-06).
