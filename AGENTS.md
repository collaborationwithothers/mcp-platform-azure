# AGENTS.md

Single source of truth for all tool-neutral rules that govern AI agents working
in this repository: repo conventions, governance policy, verification discipline,
the ticket workflow, and the dual-agent (Claude Code + Codex) operating rules.

How each tool loads this file:
- OpenAI Codex CLI reads AGENTS.md natively (repo root, trusted project).
- Claude Code does NOT read AGENTS.md natively. It reads CLAUDE.md, whose first
  line is `@AGENTS.md`, which imports this file at session start. That import
  line is load-bearing; without it Claude Code loses every rule below.

Tool-specific bindings (which model runs which tier, which command or subagent
implements a tool-neutral role) live in each tool's own file, not here:
- Claude Code: CLAUDE.md and .claude/commands/*.md.
- Codex CLI: .codex/config.toml and the Codex notes in this file.

## Style precedence
- This file and CLAUDE.md override the global ~/.claude/CLAUDE.md response style.
- Global brevity rules do not apply to: ADRs, README content, PR descriptions,
  commit bodies, COMPATIBILITY.md entries, or governance review output.
- Global brevity rules do apply to: chat responses, status updates, and
  ticket pickup confirmations.

## GOVERNANCE (maintained by Hari only; do not edit)

This whole GOVERNANCE section is Hari-owned. Agents do not edit it. It was moved
here from CLAUDE.md by issue 46 as a content-preserving relocation; the standing
"do not edit" rule applies to it in this file exactly as it did in CLAUDE.md.

### What this repo is

Public portfolio reference implementation: enterprise hosting and governance
of MCP servers on Azure. The spec seed is docs/blueprint.md. Read it before
planning any work. Everything here is public and carries Hari's name.

### Scope

- Active scope is v1 only: scenarios S1 (Entra-secured .NET MCP server,
  re-platforming from Azure Functions to AKS under epic 108; the deployed
  backend is still Functions until child (b4) cuts over), S2 (multi-tenant
  APIM MCP gateway, public-demo profile), S3
  (Terraform modules incl azapi modules for APIM MCP server and API Center),
  plus their docs and demo.
- Never create issues, branches, or code for gated or later-phase scenarios
  (private platform, Foundry, Python variant, evals, EMA). If work seems to
  require them, stop and comment on the issue instead.
- Exception, added 2026-08-13, scoped to epic 108 child (b) only: the private
  network path between APIM and the migrated MCP server backend is in v1 scope.
  That covers a virtual network, an AKS internal ingress gateway, APIM
  Standard v2 outbound virtual network integration, and private DNS for the
  backend. It does not open scenario S4. APIM's own gateway host stays publicly
  reachable, APIM gets no inbound private endpoint, and no other gated scenario
  is unlocked by this exception. This exception is removed when epic 108
  child (b) merges; removing it is part of closing that ticket.
- Exception, added 2026-08-18, scoped to issue #121: exposing the Argo CD UI
  and API to the public internet through a dedicated AKS Istio external ingress
  gateway is in v1 scope. That covers a Standard static public IP, the external
  ingress gateway add-on component, a Cloudflare DNS-only A record under
  consultwithcloud.com managed by the cloudflare Terraform provider, cert-manager
  TLS, a dedicated Entra app registration, and read-only Argo CD RBAC for invited
  guests. It does not open any gated scenario (S4 private platform, Foundry,
  Python variant, evals, EMA). The security posture is Entra SSO plus read-only
  RBAC alone: no WAF and no IP allowlist. Argo CD's local admin account is
  disabled; access is SSO-only. This is a new public entry point distinct from
  APIM's MCP path, and it does not alter ADR-001, which stays scoped to MCP
  client traffic. See ADR-011. Unlike the epic 108 exceptions above, this is a
  standing scope addition, not a temporary one: it persists after #121 merges,
  because the public access it authorizes is permanent.
- One issue at a time. Finish or park the current issue before starting
  another. Branch per issue, PR references the issue.
- Implementation sessions authenticate to GitHub as haripraghash-bot, never as
  haripraghash.

### Hard safety rules

- NEVER run terraform apply or terraform destroy, locally or in any workflow
  you author outside the gated live-test environment. You may run fmt,
  validate, plan, and lint.
- NEVER add secrets, keys, connection strings, or tenant/subscription IDs to
  the repo. Cloud credentials exist only as OIDC via the live-test
  environment. If a task appears to need a secret, stop and ask.
- Workflows you author run on runs-on: ubuntu-latest only. Never reference
  the org VNet runner group; those runners bill per minute and reach private
  networks. Only Hari adds jobs targeting that group.
- Exception, added 2026-08-13, scoped to epic 108 child (b) only: once the MCP
  backend sits behind an internal ingress gateway, a ubuntu-latest runner
  cannot reach it at all, so the live-test gate's direct-to-backend assertions
  need a runner inside the virtual network. An agent may author jobs targeting
  the VNet runner group in the ephemeral live-test gate only, and only for the
  steps that must reach the private backend. Every other job in every other
  workflow stays on ubuntu-latest. The per-minute billing warning stands: keep
  the VNet-runner job as small as it can be, and never put a build or a test
  compile in it. This exception is removed when epic 108 child (b) merges;
  removing it is part of closing that ticket.
- Exception, added 2026-08-18, scoped to issue #121 and issue #115, which is
  epic 108 child (b2): the Cloudflare DNS record for argocd.consultwithcloud.com
  is managed by the cloudflare Terraform provider. cert-manager uses Cloudflare
  DNS-01 challenges to issue TLS certificates for both that public Argo CD host
  and the private MCP host mcp.internal.consultwithcloud.com. These operations
  need a Cloudflare API token. That token is not Azure OIDC. It is stored only as
  a live-test environment secret in GitHub Actions; it is never committed to the
  repo. The same token is used two ways, both from that one secret: injected as a
  Terraform variable during the live-test apply for the cloudflare provider, and
  created as a Kubernetes secret in the cluster's cert-manager namespace for the
  DNS-01 challenges. The private MCP A record stays in Azure Private DNS and is
  never created in Cloudflare. Cert-manager may create public
  _acme-challenge.mcp.internal.consultwithcloud.com TXT records. The issued
  certificate may expose the private hostname in public certificate transparency
  logs. Neither action makes the MCP host publicly routable. The cluster has no
  ingress controller or Gateway API for HTTP-01; see ADR-011. This is the one
  permitted non-OIDC credential; every other credential stays OIDC via the
  live-test environment as the rule above requires. This is a standing exception;
  it persists while either certificate or the Argo CD record is managed by this
  platform.
- Never use pull_request_target with a checkout of PR head code.
- Bot commits and PRs carry no Claude session deep links. The binding is
  attribution.sessionUrl = false in .claude/settings.json (shared, checked
  in); do not remove or override it.

### Merge classes

- You may merge a PR only if ALL of: it carries the auto-merge-ok label
  applied by Hari, CI is green, and it touches only docs formatting, typos,
  or lockfiles.
- Everything else, including anything under /infra, /src, /.github,
  /docs/decisions, README.md, COMPATIBILITY.md: open the PR, post a review
  summary (what changed, why, links to the Microsoft docs that justify any
  azapi payload, ARM API version, or APIM policy), request review from Hari,
  and stop. Never merge these. Never ask to have the gate relaxed.
- Infra PRs that change deployed behaviour also get the needs-live-test
  label.

### Truth and verification rules

- Before writing any Azure capability claim, SKU, API version, or policy
  behaviour into code or docs, verify it against current Microsoft Learn
  documentation. Do not rely on training data for Azure MCP features; they
  are newer than you think and change monthly.
- azapi resources pin explicit ARM API versions. When you pin or change one,
  update COMPATIBILITY.md with the date and doc link.
- Never write benchmark numbers, latency figures, or cost figures that were
  not actually measured. Estimates must say "estimate", their basis, and the
  date. Demo data is synthetic and must be labelled synthetic.
- If you do not know, say so in the PR rather than guessing. A stalled issue
  is recoverable; a confident wrong public doc is not.
- Verification of Azure claims is performed with a documentation-verification
  agent that checks current Microsoft Learn documentation, not by recalling
  training data. If verification returns UNVERIFIABLE, the claim does not go
  into code or docs. Each tool binds this role to a concrete mechanism: Claude
  Code uses the azure-docs-verifier subagent (see CLAUDE.md); Codex uses the
  microsoft-learn MCP server declared in .codex/config.toml.

### Style

- ASCII punctuation only everywhere: no em dashes, no en dashes, no smart
  quotes. Metric units.
- Docs land in the same ticket as the code they describe. The default is
  still one PR. A ticket may split into a code PR (the code plus any
  COMPATIBILITY.md row it forces) and a docs PR (the remaining ADR, runbook,
  diagram, and flow-doc updates) when the split helps the reader; the docs
  PR is opened before the code PR merges, each links the other, and the
  ticket is not done until both merge. No code-only tickets.
- ADRs record real reasoning and rejected alternatives, not generic
  explanations.

### Implementation and governance review are separate

- Implementation and governance review are separate concerns run in separate
  sessions. Implementation runs on the implementation tier. The pre-PR
  code-review self-check is part of implementation and runs on the
  implementation tier.
- Governance review is the separate review that decides whether a PR is
  approved. It runs in its own session on the designated review tier, with
  Hari, and is NEVER performed by the session or agent that authored the
  change. An implementation session never approves or merges its own PR
  regardless of model or agent; it requests review from Hari and stops.
- The concrete tier-to-model bindings are tool-specific and live in each
  tool's own file (CLAUDE.md, .codex/config.toml). If a governance review
  session is not on the review tier's designated model, the session should
  say so before reviewing.

### Dual-agent operation (Claude Code primary, Codex fallback)

Established by issue 46. The repo supports two agents, but they never run at the
same time.

- Claude Code is the primary loop agent. Codex is a sequential fallback for when
  Claude usage limits are exhausted. Fallback invocation is manual; there is no
  automated detection of Claude usage exhaustion.
- The two loops are NEVER run concurrently. This is an operator rule. The label
  protocol below is a handoff marker, not a race guard; it is best-effort and is
  sufficient only because loops run sequentially. Building stronger mutual
  exclusion than labels is out of scope.
- ready-for-agent stays agent-neutral: it does not name an agent, and either
  agent may pick up a ticket carrying it.

Handoff protocol (defined once here, implemented by each tool's shim):
- On starting a ticket, apply the in-progress label for the acting agent:
  in-progress:claude or in-progress:codex.
- Bot branches are prefixed by the agent that creates them: claude/ or codex/.
  Branches are NOT renamed on takeover; the original branch name is kept.
- Every bot PR carries the agent:* label(s) of its authoring agent(s):
  agent:claude and/or agent:codex. This is mandatory because both agents share
  the haripraghash-bot account and PR authorship cannot distinguish them; the
  agent:* label is the only attribution.
- On taking over a ticket that already carries the OTHER agent's in-progress
  label, the incoming agent must, before making any change: read the ticket and
  the full branch diff; swap the in-progress label (remove the other agent's,
  add its own); keep the original branch name; add its own agent:* label
  ALONGSIDE the existing one (labels are additive on takeover, so a resumed PR
  ends up with both agent:claude and agent:codex); and record the takeover in
  the PR description (started by X, resumed by Y at commit Z).
- Default takeover mode is resume (continue the existing branch and PR).
  Restart-from-scratch is an operator override, not the default.

Governance review under dual-agent operation:
- Governance review remains Claude-only on the review tier for ALL bot PRs,
  including Codex-authored or Codex-resumed ones. It does NOT fail over to
  Codex. If Claude usage is exhausted, review waits for quota reset. Review
  consistency is worth more than continuity; implementation continuity is what
  the Codex fallback exists to provide, and it does not extend to review.
- Mixed-agent PRs (two agent:* labels, i.e. one agent started and the other
  resumed) warrant a harder review pass: the reviewer treats the seam between
  the two agents' work as a place where intent or convention may have drifted.

## Writing standards

Everything an agent writes for a human to read (docs, PR descriptions, review
summaries, ADR text, issue and PR comments, COMPATIBILITY.md notes) has one
reader with limited time. Prose that needs a second read, or a follow-up
"explain what this says" question, has failed even when it is accurate. These
rules are tool-neutral and bind both agents. They add to, and never override,
the GOVERNANCE Style rules and the truth and verification rules: plain wording
never comes at the cost of precision about what is verified versus estimated.

The exemplar and the banned-constructions list live in
docs/agents/writing-style.md. Read that file before writing any substantial
doc and match its register; a concrete sample beats any adjective below.

- Open with the point. Every doc and PR description starts with two or three
  plain sentences: what this is, why it exists, what changed. A reader who
  stops there must still leave with the right idea.
- Write like one engineer explaining something to another at a whiteboard,
  not like a spec generated by committee. Explain why before what: lead with
  the problem, then the solution.
- One idea per sentence. A sentence that needs more than one qualifying
  clause gets split.
- Gloss jargon on first use. Any term not defined in the relevant CONTEXT.md
  gets a plain-English gloss the first time a doc uses it.
- No filler, no inflation. The banned-constructions list in
  docs/agents/writing-style.md is enforceable: a banned construction in a PR
  is a review finding, not a taste question.
- Output budgets: a PR review summary fits in 20 lines; a status or pickup
  comment fits in 5; a review finding states the problem in one plain
  sentence before any supporting detail. A budget bends only when the content
  genuinely cannot fit, never for ceremony.
- Self-check before delivering any human-facing prose: reread it cold, as
  Hari would on a phone. Anything you would have to read twice, rewrite
  first.
- Every PR description completes the template's "The concept" section (ten
  lines max: the mental-model change, before and after, no file names) and
  its "Reading order: core files first" section. The core list names the one
  to three files that carry the concept; the supporting list names every
  other file and the rule that pulled it in. This exists because the repo's
  own rules make small concepts ship inside large diffs; the split keeps the
  concept findable. A missing, padded, or file-listing concept section is a
  review finding.

### Comprehension load

The rules above police sentences. These rules police structure. A doc can
pass every sentence-level rule and still fail, because comprehension load
comes from how many new things a reader must hold at once and whether each
one is anchored to something already held. These rules bind chat
explanations as well as committed artifacts.

- Anchor before detail. Before describing any component, mechanism, or
  change, one sentence places it in the system the reader already knows:
  what it belongs to and what it talks to. A reader must never meet a new
  name before knowing where it lives.
- New-concept budget: a doc, PR description, or explanation introduces at
  most three new concepts. If the content needs a fourth, split the doc, or
  move detail to a linked section the reader opens only if needed.
- Layered structure: point, then picture, then detail. First the conclusion
  in plain words, then one concrete example or walkthrough that makes the
  mechanism visible, then the full detail. A reader who stops after any
  layer leaves with a correct, if less complete, model.
- One concept at a time. Finish explaining a concept before starting the
  next. Never interleave two half-explained ideas.

### Procedural register

For procedures, commands, operational changes, rollback steps, and
acceptance criteria - anything an operator or agent must execute - the
register tightens beyond the rules above:

- State the condition before the action: "If the plan shows a destroy,
  stop", never "Stop if the plan shows a destroy".
- One principal action per step.
- Name the actor of every step: Hari, the agent, CI, or the workflow.
- Preserve the exact order of operations. Never rely on the reader to
  reorder steps.
- Repeat the noun whenever a pronoun could bind to more than one thing.

Correction ratchet: when Hari corrects wording, tone, or structure in a
session (asks for a simplification, an explanation of something already
written, or a rewrite), the agent does two things in that same session: apply
the correction, and distil the general rule behind it into one line appended
to the "Learned rules" list in docs/agents/writing-style.md (in the open PR
if one exists, otherwise as its own small docs change). Each correction is
paid for once; the list converges on Hari's actual taste instead of any
model's default register. A correction applied without a Learned-rules line
is incomplete work.

## PROJECT MECHANICS

### Frontier workflow

The frontier workflow is the tool-neutral procedure for picking up and
implementing the next ready ticket. Each tool has a thin shim that binds the
acting agent's identity (agent name, branch prefix, in-progress label) and
points here; the procedure itself lives here so both shims share one definition.

Frontier selection: the lowest-numbered open v1 issue labelled ready-for-agent.
If none exists, say so and stop; do not select any other issue.

Handoff first: before implementing, apply the acting agent's in-progress label
and, if the ticket already carries the other agent's in-progress label, follow
the takeover steps in "Dual-agent operation" above.

Read, in order, before writing anything: AGENTS.md (this file; Claude Code loads
it via CLAUDE.md's @AGENTS.md import), the issue in full (including its
acceptance checklist and out-of-scope list), and the spec sections the issue
links. The issue's links are the authority on which spec applies; do not
substitute another spec document.

First action: any issue-start verification step the ticket defines (AVM
capability checks, ARM API version re-verification, package pins), using the
documentation-verification agent (see the truth and verification rules) and the
terraform MCP registry tools. Record the outcome as the ticket requires before
implementing against it. If the ticket defines no such step, proceed.

Then: create a branch from up-to-date main, named for the issue and prefixed
with the acting agent's branch prefix (claude/ or codex/), and implement the
ticket, honouring its acceptance checklist and out-of-scope list exactly. Open a
PR referencing the issue using the PR template, apply the acting agent's agent:*
label, watch CI (gh pr checks), and fix failures until green.

Live preflight before review: when a PR changes an existing read-only
`workflow_dispatch` verification path that uses the `live-test` Environment,
dispatch that workflow at the PR branch ref and record the successful run in the
PR before requesting review. `workflow_dispatch` must exist on the default
branch before GitHub can dispatch it, but a branch ref is valid once it does.
This preflight is read-only. Static CI proves repository behaviour only. It does
not replace an Azure control-plane or data-plane check. See https://docs.github.com/actions/managing-workflow-runs/manually-running-a-workflow.

The `refs/heads/main` dispatch guard that once blocked `bootstrap`, `teardown`,
apply, and destroy from a branch was removed 2026-08-18 at Hari's instruction
(see the gated workflows' header comments), so a gated lifecycle workflow may now
be dispatched from an unmerged branch. That is an operator choice, not a
weakening of the hard safety rule above: apply and destroy still run only inside
the gated `live-test` Environment, never outside it.

Finish: complete the PR template's review summary section, including the
Microsoft Learn links justifying every Terraform, azapi, policy, or auth
decision in the diff; tick only the checklist items that are actually true;
request review from Hari; and stop.

Hard stops:
- Do not merge, regardless of CI state or merge class.
- Do not start another issue.
- Do not modify the issue's scope; if the ticket cannot be verified or completed
  as written, say so in the PR (or as an issue comment if no PR is warranted)
  instead of improvising.

### Governance review workflow

Executed by the review-tier agent only; Codex does not perform governance
review (see "Dual-agent operation"). The reviewing session is read-only: it
does not modify files, merge, approve on GitHub, or post to GitHub; the
findings are for Hari, who acts on them himself.

Identify the issue the PR references (from the PR body). Read, in order:
AGENTS.md, the issue in full (acceptance checklist and out-of-scope list), the
spec sections the issue links, the PR review summary, and the full diff
(gh pr diff).

Then:
1. Run the code-review pass on the diff.
2. Independently verify the load-bearing claims using the
   documentation-verification agent and the terraform MCP registry tools: every
   ARM API version, azapi payload shape, AVM version and input name, policy or
   auth setting, and every COMPATIBILITY.md row added or changed. Do not trust
   the PR's own links; re-derive them. Report each claim as
   VERIFIED / REFUTED / PARTIAL / UNVERIFIABLE.
3. Walk the issue's acceptance checklist item by item: quote the diff evidence
   that satisfies each item, or state plainly which items lack evidence. An
   unticked or unevidenced item is a finding, not a footnote.
4. Check the out-of-scope list: confirm nothing forbidden is present in the diff.
5. Check governance: no secrets, keys, or tenant/subscription ids; pins present
   with COMPATIBILITY.md rows in the same PR; docs land with the code; module
   interfaces match the ticket exactly; PR template checklist ticks are each
   actually true; ASCII punctuation in docs; no unmeasured figures, estimates
   labelled.
6. If the PR is a mixed-agent PR (carries both agent:claude and agent:codex),
   apply the harder review pass described in "Dual-agent operation": scrutinise
   the seam between the two agents' work for drifted intent or convention.

Output: a verdict (APPROVE or REQUEST CHANGES) followed by a numbered findings
list ordered by severity, each finding citing the file and line or claim it
concerns. Separate a final short section: "For Hari to check by hand", naming
the one or two highest-leverage things a human should verify directly (a
registry page, a doc paragraph, a design judgement). The output is delivered
in chat only.

Hard stops:
- Do not merge, approve on GitHub, or post to GitHub; the findings are for Hari.
- Do not modify any file. This session is read-only; fixes happen in the
  implementation session or a follow-up commit by Hari.
- If the PR's referenced issue cannot be identified, stop and say so.

### Issue tracker

Issues live as GitHub issues in collaborationwithothers/mcp-platform-azure via
the gh CLI. External PRs are NOT a triage surface (Issues only). See
docs/agents/issue-tracker.md.

### Triage labels

Five canonical roles use their default label strings: needs-triage, needs-info,
ready-for-agent, ready-for-human, wontfix. See docs/agents/triage-labels.md.

### Domain docs

Multi-context: root CONTEXT-MAP.md points at infra/CONTEXT.md and src/CONTEXT.md.
ADRs live under docs/decisions/ (per governance), not docs/adr/. See
docs/agents/domain.md.

### Continuous integration

Rules that bind agents; design history and harness detail live in
docs/agents/ci.md.

- Required status checks with stable job names: terraform-checks and
  dotnet-build (both in .github/workflows/ci.yml), and compat-sync (its own
  workflow, .github/workflows/compat-sync.yml). Never rename these jobs.
- compat-sync fails any dependencies-labelled PR that does not also update
  COMPATIBILITY.md; a Dependabot bump and its "Pinned versions" row move in
  lockstep.
- There are no trigger-level path filters; each step guards itself with find
  and prints SKIPPED until real .tf / .csproj files land. Preserve this
  pattern when editing workflows.
- Toolchain pins live in ci.yml and .terraform-version. When infra adds a
  required_version, keep it in step with the setup-terraform pin.
- Non-required jobs (mcp-parity, drift-agent-tests,
  compatibility-drift-structure, compat-sync-tests) may be promoted to
  required only by Hari.

### Drift verification agent

.github/workflows/compat-drift.yml is a weekly, read-only agent (issue #4) that
re-checks COMPATIBILITY.md "Re-check trigger:" notes against current Microsoft
Learn docs and opens drift-candidate issues for a human to verify. Rules that
bind agents:

- It flags CANDIDATES only. It never asserts drift as fact and never edits
  COMPATIBILITY.md. Do not modify its workflow, harness, or prompts as part
  of any other ticket.
- Seam with issue #64 (Dependabot): the drift agent owns semantic doc drift
  (the documented behaviour of a fixed pin changing, including ARM
  api-version strings embedded in azapi bodies that Dependabot cannot see);
  #64 owns registry drift (a newer version of a pinned package published).
  They are complementary and must not overlap.

Design, harness split, model binding, and the ANTHROPIC_API_KEY environment
note live in docs/specs/compat-drift-agent.md, ADR-008, and docs/agents/ci.md.

### Skills

Agent skills are a Claude Code feature (the Matt Pocock engineering skills; full
details under docs/agents/). They are not shared with Codex. Codex has its own
skills mechanism at $REPO_ROOT/.agents/skills/ with SKILL.md, but its directory
and format differ from Claude's .claude/skills, and migrating or symlinking the
Claude skills carries churn risk for the primary agent that is out of proportion
to any benefit; issue 46 therefore left the skills untouched and gave Codex only
AGENTS.md, .codex/config.toml, and the loop shim. Revisit if the Codex skills
convention stabilises.

### Terraform version

The repo pins the toolchain in .terraform-version. If local terraform does not
satisfy the compositions' required_version, run `tfswitch` (reads
.terraform-version) before validate/plan, then proceed; do not skip validation
and do not report version drift as a blocker. CI remains the merge authority.

### MCP servers and config parity

Both tools use the same four MCP servers: a read-only namespaced Azure server,
the Microsoft Learn documentation server, the Terraform registry server, and
the drawio diagram server (produces `.drawio` XML only, see Diagrams below).
Because Claude Code and Codex read different config formats and neither reads the
other's, the server list is declared twice: .mcp.json (Claude Code) and
.codex/config.toml (Codex). The two files MUST declare the same servers at the
same pins (see COMPATIBILITY.md, "MCP config parity"); scripts/check-mcp-parity
enforces this. The @AGENTS.md import pattern and the Codex project-config
conventions are still churning; re-verify them quarterly (COMPATIBILITY.md,
"Codex/Claude interop freshness").

## Diagrams

Location: `docs/diagrams/`. Two files per diagram:
- `<name>.drawio` - mxGraph XML. Agent-owned, source of truth.
- `<name>.drawio.svg` - editable SVG export. Human-owned, the file docs
  embed. Exported with "Include a copy of my diagram" and labels
  converted to native SVG text, never foreignObject.

Agents generate and update the `.drawio` source using the drawio MCP
server. Agents MUST NOT produce or edit `.drawio.svg`; that export is a
human step, performed after layout is corrected by hand. A ticket that
changes topology is not complete until the human export has landed, and
the ticket must say so.

Honesty rule extends to diagrams. A diagram is a public claim on the same
footing as a benchmark number. Depict only what the tagged release
actually deploys. Components owned by Proposed ADRs must not appear as
though they exist; target-state elements belong in a separate, captioned
diagram naming the ADR that owns each deferred piece.

Icons: official Microsoft Azure Architecture Icons. The editable-SVG
export embeds the artwork, so the icon terms of use apply to this public
repository.
