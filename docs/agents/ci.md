# Continuous integration: design and detail

This file holds the CI design history and harness detail that used to live in
AGENTS.md. The rules that bind agents (stable job names, the self-guarding
step pattern, pin lockstep, who promotes jobs) stay in AGENTS.md; read that
first. This file explains why the workflows look the way they do.

## Workflow layout

.github/workflows/ci.yml runs on every pull_request and on push to main. It
carries the two required status checks terraform-checks (fmt, per-directory
init -backend=false + validate, tflint with the root .tflint.hcl, checkov)
and dotnet-build (build + test).

The third required check, compat-sync, lives in its own workflow,
.github/workflows/compat-sync.yml (issue #64). It fails any
dependencies-labelled PR that does not also update COMPATIBILITY.md, naming
the pin row to refresh, and so keeps a Dependabot bump in lockstep with its
"Pinned versions" row. It sits in a separate workflow for two reasons: it
needs its own pull_request triggers (including labeled and unlabeled) so a
label change re-runs only this check and not the heavier jobs, and it carries
a stable job name (compat-sync) for branch protection. The workflow ships the
check; promoting it to required in branch protection is Hari's step.

The pr-size job lives in .github/workflows/pr-size.yml. It measures the current
PR base against the current head, including after base, label, or body changes.
The job reads `.github/pr-size-policy.json`, runs its behavior tests, and prints
the largest changed files. Hari promotes the job to required after it is green.

## Why no path filters

There are no trigger-level path filters, so the required jobs always run on
every PR. Instead each step guards itself with find and prints SKIPPED until
real .tf / .csproj files land. This was chosen over path filters because a
required check that is skipped by a path filter reports no status at all,
which blocks the merge queue; a job that runs and prints SKIPPED reports
green. Preserve the pattern when adding steps.

## Non-required jobs

- mcp-parity: runs scripts/check-mcp-parity to keep .mcp.json and
  .codex/config.toml declaring the same MCP servers at the same pins.
- drift-agent-tests: unit tests for the drift agent harness (issue #4),
  stdlib unittest, dependency-free like mcp-parity.
- compatibility-drift-structure: validates the extracted COMPATIBILITY.md
  doc-link structure (issue #100).
- compat-sync-tests: unit tests for the compat-sync guard.

Hari may promote any of these to required in branch protection; agents do
not.

## Pinned toolchain

Verified 2026-07-11: Terraform 1.15.8 (checkpoint-api.hashicorp.com),
.NET 10 LTS (Functions 4.x isolated worker per Microsoft Learn),
tflint-ruleset-azurerm 0.32.0. When infra adds a required_version, keep it in
step with the setup-terraform pin in ci.yml. Re-verify these pins when a
COMPATIBILITY.md re-check trigger fires or a Dependabot PR touches them.

## Drift verification agent: harness detail

.github/workflows/compat-drift.yml is the weekly, read-only drift agent
(issue #4). The binding rules (candidates only, never edits COMPATIBILITY.md,
the seam with issue #64) stay in AGENTS.md. Design: see
docs/specs/compat-drift-agent.md and ADR-008.

The workflow is split so no side effect is in the model's hands. A
deterministic Python harness (scripts/drift/extract_triggers.py,
apply_verdicts.py) extracts the "Re-check trigger:" notes, does dedup,
enforces a 5-issue-per-run cap, creates the drift-candidate issues (labelled
needs-triage), and runs a fail-loud completeness gate. The model (Opus 4.8,
via anthropics/claude-code-action@v1, with only the microsoft-learn MCP
server and file read/write, no gh) only judges each trigger to a JSON file.
The harness is unit-tested by the drift-agent-tests CI job.

Operational note: the judge step needs ANTHROPIC_API_KEY in the protected
drift-agent GitHub Environment (Hari-provisioned). This static LLM key is a
deliberate, ADR-008-recorded exception to the OIDC-only preference; it grants
no Azure access. The workflow is workflow_dispatch-able for first validation
once the key lands.
