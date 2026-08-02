# ADR-008: Scheduled semantic doc-drift agent for COMPATIBILITY.md

Status: Accepted (issue #4; implemented in the issue #4 PR)
Date: 2026-08-02

## Context

COMPATIBILITY.md is this repo's defence against preview churn: it records, per
Azure capability the code depends on, what was verified, when, against which
Microsoft Learn page, and - crucially - a `Re-check trigger:` note saying what
future condition should prompt re-verification (a newer ARM api-version, a
preview surface going GA, Microsoft documenting a behaviour we observed live but
found undocumented). Today those triggers only fire when a human remembers to
re-read the docs. The blueprint always intended "drift-detecting" tooling to
close that gap (docs/blueprint.md).

Issue #4 asks for a weekly agent that re-verifies those claims against current
Microsoft docs and opens an issue on drift. The issue body pointed at a
2026-07-11 coaching-session design that was never recorded; the design here was
reconstructed with Hari on 2026-08-02 (docs/specs/compat-drift-agent.md).

Three constraints shape the design:

1. **The honesty rule.** AGENTS.md: "a confident wrong public doc is not
   recoverable." A machine that opens public issues under Hari's name weekly must
   therefore produce candidates a human confirms, not assertions.
2. **The no-secrets rule.** AGENTS.md forbids adding secrets; cloud credentials
   exist only as OIDC via the gated environment. But real doc verification needs
   an LLM, and there is no in-CI LLM infrastructure in this repo.
3. **The #64 seam.** Issue #64 (Dependabot) owns *registry drift* - a newer
   version of a pinned package. This agent must own only *semantic doc drift* -
   the documented contract changing under a fixed pin - and not duplicate it.

## Decision

A weekly, read-only GitHub Actions workflow (`.github/workflows/compat-drift.yml`)
in three steps, with a deliberate split between judgement and effect:

1. **Extract** (`scripts/drift/extract_triggers.py`, deterministic): parse
   COMPATIBILITY.md into a work-list of the rows carrying `Re-check trigger:`.
2. **Judge** (`anthropics/claude-code-action@v1`, Opus 4.8): for each trigger,
   classify it and - when it is a Microsoft-docs condition - consult current
   Microsoft Learn via the `microsoft-learn` MCP server and emit a structured
   verdict (`fired` / `clear` / `uncertain` / `not_doc_checkable`) to a file. The
   model is granted only file read/write and the learn MCP; no Bash, no `gh`.
3. **Apply** (`scripts/drift/apply_verdicts.py`, deterministic): a completeness
   gate, dedup by a stable per-row key, a 5-issue-per-run cap, then open one
   `drift-candidate` issue per fired/uncertain row with `needs-triage`, and write
   a run summary.

Load-bearing choices:

- **Flag, never assert.** Issues are framed as candidates; the model's prose is
  attributed and explicitly "verify before editing COMPATIBILITY.md." The verdict
  set includes `uncertain` so the model can decline to decide, and
  `not_doc_checkable` for triggers with no Learn answer (an internal live-gate
  event, an ADR cross-reference, an IETF draft, a package release owned by #64).
  Coverage is therefore honestly a subset of the trigger rows, surfaced in the
  run summary rather than silently dropped.
- **Thin agent, fat harness.** Every side effect and safety rail (dedup, the cap,
  fail-loud, label application, the completeness gate) is deterministic Python,
  unit-tested with stdlib `unittest`. The model, which cannot be unit-tested,
  holds no write access to GitHub. The worst a bad model day produces is wrong
  verdicts in a JSON file that the harness caps and a human triages - never rogue
  public issues. Defence in depth: the job is `contents: read`, so even a
  misbehaving `Write` cannot corrupt COMPATIBILITY.md in a way that persists.
- **Opus 4.8.** The workload is tiny (weekly, ~16 trigger rows), so cost is a
  rounding error, and CLAUDE.md already binds the doc-verification tier to Opus.
- **Rolling issue per row, fail-loud, 5-cap.** A candidate is an independent unit
  of work a human closes on its own timeline; a stable title keyed to the row
  gives natural dedup. A run that errors turns red (a silently-dead drift checker
  is itself an undetected drift risk). The cap bounds a prompt regression.

### The OIDC-only exception (recorded deliberately)

The judge step needs an LLM credential. There is no OIDC path to Claude in this
repo's setup, so the design uses a static `ANTHROPIC_API_KEY` held in a protected
GitHub Environment (`drift-agent`), NOT a plain repo secret. This is a deliberate
exception to the AGENTS.md "credentials exist only as OIDC" preference, approved
by Hari on 2026-08-02. Rationale for accepting it: the key is an LLM credential
only - it grants no access to the Azure estate, no tenant/subscription reach, and
is not a cloud credential in the sense the no-secrets rule targets (which is
about Azure/tenant access and secrets committed to the repo). It is never written
to the repo; it lives in a protected environment gated by Hari. The cleaner
alternative (Claude via AWS Bedrock with OIDC federation) was rejected for now as
disproportionate setup for a weekly hygiene job; it remains a future option.

## Alternatives considered and rejected

- **Staleness-only reminder** (flag rows past a `Last verified` date threshold,
  no live doc check): secrets-free and trivial, but does not do what issue #4
  asks - it flags what to re-verify without verifying. Under-delivers.
- **Assert drift as fact** (issue states "row X has drifted"): cleaner to read,
  but any hallucination becomes a confident public false claim. Rejected on the
  honesty rule.
- **Fat agent with `gh` write access** (the model opens issues itself, enforcing
  the cap by instruction): least code, but puts public-issue creation and every
  safety rail in the model's instruction-following, which can regress silently.
  Rejected; effects must be deterministic and testable.
- **GPT via Azure OpenAI OIDC**: removes the static secret and is native to the
  Azure estate, but contradicts the CLAUDE.md binding of the verification tier to
  Claude/Opus. Rejected as a governance inconsistency.
- **"Dependabot already covers this"**: false. Dependabot sees registry versions,
  not whether the documented behaviour of a fixed pin changed, and cannot see ARM
  api-version strings embedded in azapi bodies. The two are complementary; the
  seam is stated in AGENTS.md and issue #64.

## Consequences and honest limits

- The agent's coverage is the doc-checkable subset of trigger rows; the rest are
  reported `not_doc_checkable`, not verified. This is visible in every run
  summary.
- The model can be wrong in both directions; that is why issues are candidates a
  human closes and why nothing edits COMPATIBILITY.md automatically.
- First real end-to-end execution requires Hari to create the `drift-agent`
  environment with `ANTHROPIC_API_KEY`. The workflow is `workflow_dispatch`-able
  for that first validation; until then CI exercises only the deterministic
  harness (a non-required `drift-agent-tests` job).
- Reachability of the `microsoft-learn` HTTP MCP endpoint is established: it is
  the same server already declared in `.mcp.json` and used to verify many
  existing COMPATIBILITY.md rows.
