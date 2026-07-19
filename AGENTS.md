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

## GOVERNANCE (maintained by Hari only; do not edit)

This whole GOVERNANCE section is Hari-owned. Agents do not edit it. It was moved
here from CLAUDE.md by issue 46 as a content-preserving relocation; the standing
"do not edit" rule applies to it in this file exactly as it did in CLAUDE.md.

### What this repo is

Public portfolio reference implementation: enterprise hosting and governance
of MCP servers on Azure. The spec seed is docs/blueprint.md. Read it before
planning any work. Everything here is public and carries Hari's name.

### Scope

- Active scope is v1 only: scenarios S1 (Entra-secured .NET Functions MCP
  server), S2 (multi-tenant APIM MCP gateway, public-demo profile), S3
  (Terraform modules incl azapi modules for APIM MCP server and API Center),
  plus their docs and demo.
- Never create issues, branches, or code for gated or later-phase scenarios
  (private platform, Foundry, Python variant, evals, EMA). If work seems to
  require them, stop and comment on the issue instead.
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
- Never use pull_request_target with a checkout of PR head code.

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
- Docs land in the same PR as the code they describe. No code-only PRs.
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
- The concrete tier-to-model bindings are tool-specific. Claude Code binds the
  implementation tier to Sonnet 5 (effort high) and the review tier to
  Opus 4.8 (effort high); see CLAUDE.md. Codex binds the implementation tier
  in .codex/config.toml. If a governance review session is not on the review
  tier's designated model, the session should say so before reviewing.

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
- Governance review remains Claude/Opus-only for ALL bot PRs, including
  Codex-authored or Codex-resumed ones. It does NOT fail over to Codex. If
  Claude usage is exhausted, review waits for quota reset. Review consistency
  is worth more than continuity; implementation continuity is what the Codex
  fallback exists to provide, and it does not extend to review.
- Mixed-agent PRs (two agent:* labels, i.e. one agent started and the other
  resumed) warrant a harder review pass: the reviewer treats the seam between
  the two agents' work as a place where intent or convention may have drifted.

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
the takeover steps in "Dual-agent operation" above (read the diff, swap the
label, add your agent:* label, resume on the same branch, record the takeover).

Read, in order, before writing anything: AGENTS.md (this file; Claude Code loads
it via CLAUDE.md's @AGENTS.md import), the issue in full (including its
acceptance checklist and out-of-scope list), and the spec sections the issue
links (docs/specs/v1-tracer-bullet.md).

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

Executed by the review-tier agent only. In this repo that is Claude Code on
Opus 4.8; Codex does not perform governance review (see "Dual-agent operation").
The reviewing session is read-only: it does not modify files, merge, approve on
GitHub, or post to GitHub; the findings are for Hari, who acts on them himself.

Identify the issue the PR references (from the PR body). Read, in order:
AGENTS.md, the issue in full (acceptance checklist and out-of-scope list), the
spec sections the issue links (docs/specs/v1-tracer-bullet.md), the PR review
summary, and the full diff (gh pr diff).

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
registry page, a doc paragraph, a design judgement).

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

.github/workflows/ci.yml runs on every pull_request and on push to main. Two of
its jobs are required status checks and their names must stay stable:
terraform-checks (fmt, per-directory init -backend=false + validate, tflint with
the root .tflint.hcl, checkov) and dotnet-build (build + test). A third job,
mcp-parity, runs scripts/check-mcp-parity but is NOT a required check (Hari may
promote it in branch protection). There are no
trigger-level path filters, so both jobs always run; instead each step guards
itself with find and prints SKIPPED until real .tf / .csproj files land. Pinned
toolchain, verified 2026-07-11: Terraform 1.15.8 (checkpoint-api.hashicorp.com),
.NET 10 LTS (Functions 4.x isolated worker per Microsoft Learn), tflint-ruleset-
azurerm 0.32.0. When infra adds a required_version, keep it in step with the
setup-terraform pin here.

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

Both tools use the same three MCP servers: a read-only namespaced Azure server,
the Microsoft Learn documentation server, and the Terraform registry server.
Because Claude Code and Codex read different config formats and neither reads the
other's, the server list is declared twice: .mcp.json (Claude Code) and
.codex/config.toml (Codex). The two files MUST declare the same servers at the
same pins (see COMPATIBILITY.md, "MCP config parity"); scripts/check-mcp-parity
enforces this. The @AGENTS.md import pattern and the Codex project-config
conventions are still churning; re-verify them quarterly (COMPATIBILITY.md,
"Codex/Claude interop freshness").
