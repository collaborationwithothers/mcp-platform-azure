# Spec: v1 thickening (Phase 3.5: multi-server, per-tool authorization, content safety)

Status: drafted (Phase B of the blueprint revision cycle, issue #20). Ranking and
ready-for-agent labelling happen at STOP 2, by Hari; this spec carries no triage
state of its own.
Date: 2026-07-27
Scope: Phase 3.5 thickening only, issues #17, #18, #19, each deepening the proven
v1 stack. Deep-gated variants (private platform, Foundry, Python, evals, EMA)
remain out of scope.
Source: grill-with-docs session over the amended docs/blueprint.md (Section 13
Phase 3.5, Section 18 corrections), with every load-bearing Azure claim verified
against Microsoft Learn on 2026-07-27 (azure-docs-verifier). Decisions in this
spec are Hari's, recorded from that session.

This spec thickens the same governed path v1 proved: it multiplies the servers
behind the gateway (#17), adds a per-tool authorization layer that governs both
APIM MCP server types through one mechanism (#18), and screens tool-call
arguments at the gateway (#19). Everything is gateway and composition work; the
Functions backend is untouched.

## Problem Statement

A platform engineer who shipped the v1 slice has proven exactly one MCP server
behind one gateway, with authorization enforced at server granularity and no
inspection of what flows through tool calls. A real estate is none of those
things: gateways carry many servers, callers are entitled to some tools and not
others, and tool arguments are an injection surface into every backend the
platform fronts. Three specific gaps block the "governed service" claim from
scaling past one server:

- Discovery is singleton-shaped. The gateway serves one protected resource
  metadata (PRM) document, and every server instance emits a challenge pointing
  at it. A second server as built today would advertise the first server's
  metadata: discovery fails, or worse, binds a client to the wrong resource.
- Authorization stops at the server boundary. A caller with a valid token for a
  server may invoke every tool that server exposes. The platform documented
  per-tool authorization as a capability (blueprint Sections 4 and 6) but never
  phased or built it, and the v1 assumption that REST-export servers get it
  natively from operation-scope policies is refuted by current documentation.
- Nothing screens content. Tool-call arguments reach backends unexamined, so the
  gateway's governance claim excludes the one payload an agent platform most
  needs screened.

## Solution

One gateway carries three MCP servers, each with spec-conformant per-server
discovery: the original passthrough MCP server, a passthrough clone at its own
path (#17), and a REST-export MCP server created from the existing downstream
Orders API (#18). Each server has its own delegated scope and app role under the
shared Entra registration, so a caller granted one server's scope is rejected at
the others. Every tool invocation passes a per-tool authorization check at the
gateway, default-deny, driven by a total map of tool name to required scope,
role, or an explicit unrestricted marker: hand-maintained and drift-checked for
the passthrough servers, derived from the defining operation list for the
REST-export server. Every tool-call's arguments are screened by the
llm-content-safety policy on all servers, fail-closed, before they reach any
backend. Denials, both authorization and content, are first-class audit events.

## User Stories

1. As a platform engineer, I want a second passthrough MCP server added by
   instantiating the server module again in the composition, so that
   multi-server is a composition change and not a redesign.
2. As an MCP client developer, I want each server's PRM document served at its
   RFC 9728 path-inserted well-known location, so that a conformant client
   discovers each server's metadata deterministically from the server URL alone.
3. As an MCP client developer, I want each server's 401 challenge to lead to
   that server's own metadata, so that a client connecting to server 2 is never
   pointed at server 1's document.
4. As a security reviewer, I want the retained root PRM document to fail closed
   under RFC 9728 s3.3 resource matching when a client falls back to it while
   targeting another server, so that misrouted discovery is rejected rather than
   silently binding to the wrong resource's authorization server.
5. As a platform engineer, I want each server to have its own delegated scope
   and app role under the shared app registration, advertised only in that
   server's PRM document, so that cross-server isolation is enforced at scope
   granularity within the shared audience.
6. As a security reviewer, I want a gate negative proving a client granted only
   server 1's scope is rejected at server 2, so that grant-level isolation is
   demonstrated rather than asserted.
7. As a governance reviewer, I want the shared-audience deviation from the MCP
   authorization spec's audience-binding MUST documented with its cause (the
   Entra resource-indicator deadlock) and its owner (issue #42), so that a
   spec-literate reader finds a documented deviation, not an unnoticed defect.
8. As a platform engineer, I want per-tool authorization enforced at the
   gateway, mapping each tool name to a required scope, role, or an explicit
   unrestricted marker, so that entitlement is decided per invocation, not per
   server.
9. As a security reviewer, I want an unmapped tool name rejected at the gateway,
   so that the platform fails closed on unknown tools.
10. As a backend tool author, I want CI to fail when the backend tool surface
    and the authorization map diverge in either direction, so that a tool I add
    without a mapping entry is caught before it serves ungated traffic, and a
    map entry whose tool is renamed or removed is caught as a dead policy branch.
11. As a security reviewer, I want the map to be total, with deliberate openness
    written as an explicit unrestricted entry, so that "open on purpose" is a
    reviewed line of configuration rather than an absence.
12. As an operator, I want every gateway denial to emit an audit event
    dimensioned by caller and tool, so that the platform's most
    security-relevant outcome is recorded even though it never reaches a
    backend, and so that a tool a client class can see but never invoke shows up
    as a partitioning defect.
13. As an MCP client developer, I want a denial to state insufficient scope
    informatively, so that a client, human or model, re-plans instead of
    retrying.
14. As a platform engineer, I want the REST-export MCP server created from the
    existing Orders API entirely in Terraform, so that the second APIM MCP
    server type is proven under IaC, not portal work.
15. As a platform engineer, I want the export server's authorization map derived
    from the same operation list that defines its tools, so that map drift is
    structurally impossible where APIM owns the tool surface.
16. As a governance reviewer, I want one enforcement fragment applied to both
    server types with two configuration provenances, so that the
    surface-ownership asymmetry is executable architecture rather than prose.
17. As a security reviewer, I want the non-concealment property named: the
    gateway enforces but does not hide the tool surface, with concealment
    achievable only by partitioning tools across servers with per-server scopes,
    so that "tool blocking" is never read as implying concealment.
18. As a platform engineer, I want tool-call arguments screened by the
    llm-content-safety policy on every server through a default-on per-server
    input, so that screening is uniform platform posture with opt-out explicit
    in configuration.
19. As a security reviewer, I want a Content Safety backend failure to reject
    the tool call, so that screening cannot silently degrade to unscreened
    traffic under load or outage.
20. As an operator, I want verdict denials and unavailability denials separated
    in the audit stream, so that security signal and operational signal do not
    poison each other.
21. As a security reviewer, I want prompt-attack detection applied to tool
    arguments where the policy surface supports it, so that the screening
    addresses the injection threat an MCP platform actually faces, not only
    harm categories.
22. As a platform engineer, I want the Content Safety resource on the S0 tier,
    so that the fail-closed gate is deterministic rather than exposed to
    free-tier throttling flakes.
23. As a governance reviewer, I want every Azure claim this phase writes into
    code or docs verified against current documentation with COMPATIBILITY.md
    rows in the same PR, so that the truth discipline v1 established holds
    through the thickening.
24. As an operator, I want the deployment coupling stated: a backend tool
    addition and its map entry move together, so that a denial CI never saw
    cannot appear in production because the Functions app deployed ahead of the
    Terraform that carries the map.

## Implementation Decisions

### Multi-server composition (#17)

- The second server is a passthrough clone: a second instance of the
  apim-mcp-server module at its own path, forwarding to the same backend
  function host. No new backend, no new server type. The REST-export server is
  deliberately NOT built here; it is #18's first task, so that #17 isolates the
  one question it exists to answer (does the gateway-singleton PRM design
  survive a second server) without variables that fail for non-composition
  reasons.
- Per-server PRM, path-inserted form: each server's metadata is served at the
  RFC 9728 s3.1 insert-before-path location for that server's URL. This is the
  RFC's own multi-resource construction (path components exist to support
  multiple resources per host; each protected resource serves its own document
  at a location deterministically derived from its URL), not a workaround. The
  apim-gateway module's PRM interface grows from single-server inputs to a
  per-server collection: a thick-interface change, the pathed well-known
  operation becoming per-server.
- The challenge emitter is the second required artifact: the server module
  currently derives one root-form metadata URL for every instance, so both 401
  sites (missing token, and the on-error invalid-token path) would point every
  server at server 1's document. It becomes per-server, emitting the s3.1 form.
  The deployed type=mcp runtime is known to rewrite the challenge's
  resource_metadata per server path downstream of the policy pipeline (issue-9
  trace), so the gate asserts the CLIENT-VISIBLE challenge, not the emitted
  value; whether the rewrite also applies to the on-error 401 is unestablished
  and goes on the live-gate checklist.
- The root PRM document is retained, describing the primary server. Under RFC
  9728 s3.3 a client that falls back to it while targeting another server sees a
  resource mismatch and MUST discard the document: the asymmetry fails closed.
  This is documented as a safety property with its mechanism, not a limitation.
- Identity: shared app registration and shared audience, with a per-server
  delegated scope and a per-server app role under the one App ID URI. Each
  server's PRM advertises only its own scope. The per-server policy check runs
  after token validation as a policy expression with OR semantics across claims
  (the server's scope in scp, or its app role in roles), because a delegated
  token carries scp and no roles, an app-only token the reverse, and
  required-claims validation ANDs its entries.
- Two honesty clauses attach to the identity decision, verbatim intent:
  (1) the shared audience is a known non-conformance with the MCP authorization
  spec's audience-binding MUST, inherited from the #42 Entra resource-indicator
  deadlock, made visible by the second server; a documented deviation with an
  owner, never phrased as "isolation out of scope". (2) isolation is per grant,
  not per token: a client granted both servers' scopes or roles mints one token
  valid at both; the claim is "cross-server isolation enforced at scope
  granularity within a shared audience, per grant; audience-per-server deferred
  to #42".
- New module inputs: required scope and required role per apim-mcp-server
  instance (per-instance parameters the instantiate-twice design wants anyway).
  Runbook additions: the second server's scope and role, and a least-privilege
  negative-test client granted server 1's entitlements only.
- Issue-start verification (ADR-006 trigger): re-test MCP client well-known
  resolution, with a three-branch clause. Client resolves the path-inserted
  location: proceed. Client no longer resolves it: stop and come back, no
  improvised hostname infrastructure. Partial (client probes the root first or
  caches root-derived metadata): PASS, provided the client proceeds correctly
  after the s3.3 mismatch rejection, that being the fail-closed path working as
  designed.
- Hostname-per-server is rejected for #17: it would pre-decide issue #42's
  custom-domain option and make ADR-006 plus the eventual #42 decision read as
  one decision made twice. ADR-006's growth-paths section is amended to record
  the path-inserted choice on RFC grounds and to correct its now-stale "blocked
  on client support" claim.

### Per-tool authorization and tool blocking (#18)

- Corrected premise, replacing the issue's text: current documentation states
  that policies apply to all API operations exposed as tools in the MCP server,
  for BOTH server types; there is no per-tool policy scope. What REST-export
  provides natively is static tool selection (choosing which operations become
  tools); the passthrough tool surface is backend-owned and offers not even
  that. Runtime per-tool authorization is therefore an MCP-server-scope policy
  problem everywhere, which is what this ticket builds.
- First task: create the REST-export MCP server from the existing Orders API in
  Terraform. Issue-start verification: pin the ARM resource shape and API
  version for MCP tool sub-resources (the documented backingOperationId
  parameter) and confirm azapi expressibility, expecting
  schema_validation_enabled = false per the established provider-schema-lag
  correction. Evidence on this surface is currently disputed (a Learn ARM
  template parameter exists; an independent search found no azapi surface); the
  pinning step settles it, and if it cannot be expressed in IaC the ticket
  stops and says so rather than shipping portal steps.
- The export server is a third server behind the gateway and receives the full
  per-server treatment from #17: its own path-inserted PRM document, scope, app
  role, and audit identity. Exposing an internal downstream as a first-class
  MCP server is a security-model change and is treated as such in the ADR, not
  as a wiring detail.
- One enforcement fragment, two configuration provenances. The fragment's
  contract: a total map of tool name to required scope, required role, or an
  explicit unrestricted marker; gating tools/call only; default-deny for any
  tool name not in the map; one deny path; one audit event. The passthrough
  servers feed it a hand-maintained Terraform map. The export server feeds it a
  map derived in Terraform from the same operation list that defines its tools,
  so drift is structurally impossible there. The surface-ownership asymmetry
  (who owns the tool surface, not where policy attaches) is the spine of the
  new ADR this ticket writes: gateway-enforced versus server-enforced tool
  authorization, defense in depth, both layers real (the MCP-layer app-role
  check from issue #45 remains the second layer).
- Interface constraint, stated once so it does not need re-deriving per
  provenance: the per-tool authorization fragment consumes a rendered
  tool-name-to-claim map as an input. Map provenance is out of scope for the
  fragment. The hand-maintained (passthrough) and derived (REST-export)
  provenances therefore feed the same fragment unchanged, which is why the
  REST-export server is a thickening of per-tool authorization rather than a
  prerequisite for it.
- Completeness is set equality, not iteration: the gate reads tools/list from
  the deployed server and compares returned names to map keys, failing on any
  difference in either direction (an extra map entry indicates a renamed or
  removed tool and a dead policy branch). The comparison runs as a pinned,
  fully-granted identity, stated explicitly in the assertion, so it does not
  silently weaken if tool exposure ever becomes caller-dependent. Per-tool
  positive calls and one unmapped-tool probe remain as proof the mappings
  function and the deny path fires; they are not the completeness check.
- Mechanism selection is a verification item, not an assumption: first
  establish in the live gate whether the documented gen_ai.tool.name context
  variable is populated early enough to drive an inbound policy condition; if
  not, the fragment parses the JSON-RPC request body for tools/call and the
  tool name. Response-body access in MCP server policies is documented as
  unsupported (it breaks streaming) and is never used; request-body reading has
  no documented constraint either way and is therefore live-gate-proven if
  used. The fragment contract is independent of which mechanism wins.
- Non-concealment is chosen deliberately: the gateway enforces but does not
  hide the tool surface. Concealment is unachievable at the gateway on the
  passthrough path (response rewriting is off the table; the Functions MCP
  extension registers tool metadata at startup with no per-request hook found,
  unverified); where concealment is ever required, the mechanism is
  partitioning tools across MCP server instances with per-server scopes, which
  is exactly the #17 primitive. For this server the tool surface is a synthetic
  orders fixture with no sensitive tool names, so the deny response is
  informative: RFC 6750 insufficient_scope semantics. The exact wire shape for
  a mid-session tools/call denial against the current MCP spec revision is a
  spec-time verification item; whichever way it lands, it is one decision
  encoded once, in the fragment and the gate assertions. No posture toggle is
  built.
- The named non-goal, with cause: tool names and input schemas remain visible
  to callers who cannot invoke them; the wasted call and per-turn context cost
  of unusable schemas is a real dynamic, currently zero here because the server
  exposes one tool.
- Deployment coupling, one ADR sentence: default-deny plus set equality means a
  backend tool addition fails infrastructure CI, which is correct only if the
  Functions app and the Terraform map move together; independent deployment
  would produce a production denial CI never saw.
- Escape hatch, documented and not built: if a real estate ever needs it, the
  relaxation is per-server default-allow as an explicit configuration opt-in,
  never a global fallback.
- Gateway denials (authorization and content) constitute a fourth error surface
  extending the v1 three-layer error contract (protocol/auth rejection, thrown
  tool error, typed domain result): a gateway-layer rejection that never
  reaches the backend. The error-layering documentation is extended here, and
  the overlap with issue #52's error-contract section is deduplicated at
  ticket time.

### Content safety on tool-call arguments (#19)

- The llm-content-safety policy (GA; documented for MCP tool requests) screens
  tool-call arguments on every MCP server behind the gateway: a per-server
  content-safety input on the server modules, default-on, opt-out explicit.
  Uniformity is composition posture, not global-scope attachment: the policy
  attaches per server API, and the PRM well-known API is never in the screening
  path, so discovery cannot depend on Content Safety.
- Direction: requests only (tool-call arguments), per the issue's scope.
  Response screening is out of scope and collides with the documented streaming
  constraint.
- Ordering: the per-tool authorization fragment runs before content safety, so
  denied and unmapped calls never spend a Content Safety transaction. The
  policy-ordering and buffering constraints shared with #18 are designed and
  documented in whichever of #18/#19 lands second, per the standing note on
  both tickets.
- Screening scope: harm categories plus prompt-attack detection. Shield-type
  (prompt-attack) checking is documented as a `shield-prompt="true | false"`
  on/off attribute, separate from and alongside the per-category severity
  thresholds; it is an on/off switch, not itself threshold-configurable
  (COMPATIBILITY.md, 2026-07-27).
- Failure mode: fail-closed. A Content Safety backend failure (unreachable,
  throttled, 5xx) rejects the tool call. The two deny classes are separated in
  the audit stream: a verdict denial is a security event; an unavailability
  denial is an operational event. Spec-time verification item: whether the
  policy's own backend-failure behaviour is configurable and what its default
  is; if it fails open with no override, that is a refuted assumption that
  changes this ticket's shape and comes back to Hari.
- Resource: a new Azure AI Content Safety resource in the S2 composition, S0
  tier (determinism over pennies: free-tier throttling under a fail-closed
  uniform design would flake the gate, the failure mode the registry-assertion
  discipline exists to forbid). The APIM managed identity gets Cognitive
  Services User on it. Accepted consequence, stated: fail-closed uniform
  screening makes Content Safety a single point of failure for the entire tool
  path, in the gate and in any deployment.

## Testing Decisions

Three seams, all existing, no new ones. A good test at every seam asserts
externally observable behaviour: what a client receives, what a deployed
control does, never how a policy is written.

- The gated live-test workflow is the primary seam; every acceptance-grade
  assertion is client-visible behaviour through the deployed gateway. Per
  server: the path-inserted PRM document returns 200 AND its resource value
  equals that server's URL exactly (s3.3 first equality); the client-visible
  challenge leads to that server's metadata, asserted wherever the header path
  is observable (s3.3 second equality); reachability-only assertions are
  insufficient by decision. Cross-server: the least-privilege client's token is
  accepted at server 1 and rejected at server 2 (grant-level isolation
  negative). Per-tool: tools/list set equality against the map under the
  pinned fully-granted identity; each mapped tool callable by an entitled
  caller; an unmapped probe denied; a mapped tool denied to a caller lacking
  its scope/role; every deny emitting its audit event. Content safety: a clean
  call passes; a flagged payload is denied with a security-class audit event
  (the unavailability class is not inducible in the gate and is stated as
  such).
- Module contract tests: the apim-mcp-server instantiate-twice pattern extends
  to the new per-server inputs (scope, role, content-safety block, per-server
  PRM wiring through apim-gateway).
- Static Terraform CI: fmt, per-directory validate, tflint, checkov, unchanged
  in kind; fragment and map rendering must survive validate without
  credentials, per the existing policy templatefile pattern.
- Prior art: the issue-9 gate stages (discovery assertions, call stage), the
  shadow-key proof and role-less negative patterns, and the issue-53
  assignment-required gate are the models for the new negatives.

## Out of Scope

- Audience-per-server and interactive sign-in: owned by issue #42 (OAuth
  mediation versus custom verified domain). This phase documents the
  non-conformance; it does not resolve it.
- Hostname-per-server PRM growth path: rejected for this phase; revisit only
  via #42's custom-domain work.
- Concealment of the tool surface: tools/list filtering, per-caller response
  rewriting, opaque uniform denials, and any posture toggle between informative
  and opaque. Non-concealment is the documented posture.
- Per-server default-allow escape hatch: documented, never built here.
- Response-direction content screening.
- Backend (McpTools) changes of any kind; the MCP-layer app-role check from
  issue #45 stands as-is as the second defense layer.
- Registry-as-governance (#23), long-running tools (#26), AKS variant (#51),
  the MCP-vs-REST doc (#52, except the error-taxonomy dedup noted above), and
  all deep-gated scenarios.

## Further Notes

- Dependency edges, no rank implied (ranking is Hari's at STOP 2): #17 before
  #18 (the fragment extends #17's claim-inspection layer; the export server
  rides #17's per-server PRM machinery); #19 requires only #17. The gate stays
  one workflow against the one S2 composition, each ticket extending its
  assertion stages.
- Consolidated spec-time/issue-start verification items: MCP client well-known
  resolution re-test (three-branch clause, #17); ARM shape and API version for
  export tool sub-resources plus azapi expressibility (#18); gen_ai.tool.name
  availability in an inbound policy condition (#18); mid-session tools/call
  denial wire shape against the current MCP spec revision (#18);
  llm-content-safety backend-failure behaviour and configurability (#19);
  whether the platform challenge rewrite applies to the on-error 401 (#17,
  gate checklist).
- Documentation artifacts: ADR-006 amendment (#17); a new ADR on
  gateway-enforced versus server-enforced tool authorization (#18); the
  error-taxonomy extension (#18); the ordering/buffering note (whichever of
  #18/#19 lands second); COMPATIBILITY.md rows for the 2026-07-27 verifications
  land with this spec, and every new pin lands with its ticket.
- Ticket plan: no new issues are expected; #17, #18, and #19 are amended to
  match this spec (each currently diverges from it: #17's scope changed, #18's
  premise is refuted by current documentation, #19 predates the Q6-Q9
  decisions). The stale S2 composition variable description (PRM resource
  wrongly described as deriving from the audience) is fixed with the ticket
  set.
