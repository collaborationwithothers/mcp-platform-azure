# Spec: scheduled semantic doc-drift agent for COMPATIBILITY.md

Issue: #4 (Post-v1: weekly COMPATIBILITY.md drift verification agent)
Status: design approved 2026-08-02; implementation pending on branch
`claude/issue-4-compat-drift-agent`.
Date: 2026-08-02.

This spec fills the acceptance gap in issue #4, whose body pointed at a
2026-07-11 coaching-session design that was never recorded in the repo. The
design below was reconstructed with Hari on 2026-08-02 and is the authoritative
acceptance surface for the PR. The durable decision record is ADR-008 (shipped
in the same PR); this spec is the implementation-facing companion.

## 1. Purpose and boundary

A weekly, read-only agent that evaluates the `Re-check trigger:` notes already
authored into COMPATIBILITY.md against current Microsoft Learn documentation and
opens one GitHub issue per row whose trigger appears to have fired. Each issue is
framed as a *candidate* for a human to verify, never as an assertion of fact.

The agent:

- verifies only the semantic conditions written in `Re-check trigger:` notes;
- never checks package/provider/module versions (that is registry drift, owned
  by Dependabot under issue #64; see the seam in section 2);
- never edits COMPATIBILITY.md, never opens PRs, never merges, never touches
  branch protection;
- never assumes a trigger fired: when a trigger has no answer on Microsoft Learn
  (an internal event, an ADR cross-reference, a non-Learn source), it records
  the row as out of the agent's coverage rather than guessing.

### Why "flag, never assert"

These are public GitHub issues under Hari's name. The repo's governing rule
(AGENTS.md) is that "a confident wrong public doc is not recoverable." A machine
that writes public text weekly must therefore emit candidates a human confirms,
not conclusions. This constraint shapes every downstream decision: the model
returns judgements to a file, and only deterministic code opens issues.

## 2. Seam with issue #64 (Dependabot)

Issue #64 owns *registry drift*: has a newer version of a pinned package (NuGet,
Terraform provider, AVM/registry module) been published. It is mechanical,
registry-driven, and handled by native GitHub tooling.

This agent (issue #4) owns *semantic doc drift*: has the vendor's documented
contract changed under a fixed pin (feature GA/preview status, ARM API-version
behaviour, payload shapes, documented auth behaviour). It is judgement-driven and
docs-driven.

The two are complementary and must not overlap. In particular this agent DOES
cover "a newer ARM api-version ships" triggers (api-version strings embedded in
azapi bodies, e.g. `2024-06-01-preview`), because those are not provider or
module versions and Dependabot cannot see them. It does NOT cover az-CLI
extension or package release triggers that Dependabot's ecosystems already track.

## 3. Non-goals (out of scope for this PR)

- Any change to COMPATIBILITY.md content or to the pins themselves.
- Package/provider/module version checking (issue #64).
- Auto-closing or auto-resolving issues it previously opened.
- Verification against non-Learn sources (IETF datatracker, npm, PyPI). Triggers
  that reference those are classified `not_doc_checkable` and surfaced, not acted
  on.
- Any live Azure resource access (no `azmcp`, no OIDC to Azure). This is a
  docs-versus-repo agent; it never touches the Azure estate.
- Promoting the new CI job to a required status check (branch protection is
  Hari-only; the job ships non-required).

## 4. Architecture: thin agent, fat harness

Three steps. The non-deterministic judgement (model-only) is isolated from every
side effect (deterministic code-only). The model never has write access or a
`GITHUB_TOKEN`.

```
cron / manual dispatch
  -> [1 extract]  scripts/drift/extract_triggers.py     (deterministic)
        reads COMPATIBILITY.md -> work-list.json
  -> [2 judge]    anthropics/claude-code-action@v1       (Opus 4.8; learn MCP + read/write only)
        reads work-list.json, consults Microsoft Learn -> verdicts.json
  -> [3 apply]    scripts/drift/apply_verdicts.py        (deterministic)
        reads verdicts.json + open drift-candidate issues
        -> dedup + 5-cap -> opens/labels issues -> run summary
```

Language: Python 3, matching `scripts/check-mcp-parity` (the existing
repo-hygiene checker already exercised in CI). No new runtime.

### 4.1 Component: `scripts/drift/extract_triggers.py`

- Input: `COMPATIBILITY.md` (path arg, default repo root).
- Behaviour: line-based parse. A candidate row is a Markdown table row (line
  begins with `|`) whose text contains `Re-check trigger:`. For each, split on
  `|`; cell 0 is the identifying label; capture the trigger substring (from
  `Re-check trigger:` to end of cell or line) and any `https://learn.microsoft`
  URL(s) present in the row.
- Output: `work-list.json`, an array of objects (see 5.1). Deterministic and
  stable: same input yields byte-identical output (rows in file order).
- Exit non-zero only on unreadable input or a malformed table row it cannot key.

### 4.2 Component: judge step (`claude-code-action@v1`)

- Action: `anthropics/claude-code-action@v1` (the GA entrypoint; `base-action` is
  a mirror). Driven by a direct `prompt` input plus a `claude_args` string
  carrying `--model claude-opus-4-8`, `--mcp-config` (inline JSON declaring the
  remote HTTP microsoft-learn server), `--allowedTools`, and `--max-turns`.
- Tools granted via `--allowedTools "Read,Write,mcp__microsoft-learn__*"`: the
  `microsoft-learn` MCP server (public HTTP endpoint
  `https://learn.microsoft.com/api/mcp`, no auth; the same server already
  declared in `.mcp.json`), file read, and file write (needed only to emit
  `verdicts.json`). Explicitly NOT granted: any Bash/`gh`, the `azure` MCP
  server. With no Bash or `gh` the model cannot reach `GITHUB_TOKEN` even though
  the job holds `issues:write`; and because the job is `contents: read`, any
  stray file write is inert (nothing is committed or pushed).
- Prompt: committed at `scripts/drift/prompt.md`. Instructs the model to, for
  each work-list item, classify the trigger and (when it is a Microsoft-docs
  condition) consult current Learn docs and judge whether the documented contract
  now differs from the row's recorded claim.
- Output contract: writes `verdicts.json` (see 5.2). One verdict per work-list
  item, keyed by `key`. Every item in must appear out; the apply step enforces
  this (a missing key fails the run) so a truncated agent run is a red run, not a
  silent partial pass.

### 4.3 Component: `scripts/drift/apply_verdicts.py`

- Inputs: `work-list.json` (from extract) and `verdicts.json` (from the judge
  step); the set of currently-open issues labelled `drift-candidate` (fetched via
  `gh issue list`, or injected for tests).
- Completeness gate (before anything else): every `work-list` key must have a
  verdict and every verdict key must be in the work-list; otherwise fail-loud.
  This turns a truncated or malformed agent run into a red run rather than a
  silent partial pass.
- Behaviour:
  1. Keep only `status == fired` or `status == uncertain`. Drop `clear` and
     `not_doc_checkable` (but count them for the summary).
  2. Dedup: derive each candidate's issue title `drift-candidate: <key>`; if an
     open issue with that exact title exists, skip opening (record as
     "still-open") and stay silent on the issue.
  3. Enforce the 5-cap on *new* issues per run. Beyond 5, do not open; record
     "N more suppressed" with their keys.
  4. For each opened issue: title `drift-candidate: <key>`, body from the
     verdict's drafted body (trigger text, the row's recorded claim, the current
     Learn link, what looks different, and an explicit "candidate - a human must
     verify before changing COMPATIBILITY.md" banner), labels `needs-triage` +
     `drift-candidate`.
  5. Write a run summary to `$GITHUB_STEP_SUMMARY`: opened, still-open,
     suppressed, clear, not_doc_checkable (with reasons), and any key previously
     open that now judges `clear` ("you may close #N").
- `--dry-run`: perform steps 1-3 and print intended `gh` actions without calling
  `gh`. Used by unit tests and for local runs.
- Fail-loud: malformed/absent `verdicts.json` or `work-list.json`, a
  completeness-gate violation, or any `gh` failure exits non-zero (turns the run
  red).

### 4.4 Component: `.github/workflows/compat-drift.yml`

- Triggers: `schedule` (weekly cron) and `workflow_dispatch` (manual).
- `permissions: { issues: write, contents: read }` (least privilege; no
  `pull-requests`, no `contents: write`).
- `environment:` a protected GitHub Environment holding `ANTHROPIC_API_KEY`.
- `concurrency:` a fixed group so overlapping runs cannot double-open.
- `timeout-minutes:` set (bounded weekly run).
- `runs-on: ubuntu-latest` only (hard rule; never the VNet runner group).
- Steps: checkout -> setup Python -> `extract_triggers.py` -> judge action ->
  `apply_verdicts.py`. Any step failing fails the job (fail-loud).

## 5. Data contracts

### 5.1 work-list.json (extract -> judge)

```json
[
  {
    "key": "microsoft-apicenter-apisources-targetenvironmentid",
    "label": "Microsoft.ApiCenter/services/workspaces/apiSources targetEnvironmentId format",
    "trigger_text": "any newer Microsoft.ApiCenter API version, or a docs correction to the apiSources sample.",
    "recorded_claim": "<the row's Notes cell, trimmed>",
    "doc_links": ["https://learn.microsoft.com/rest/api/resource-manager/apicenter/api-sources/create-or-update"],
    "last_verified": "2026-07-14"
  }
]
```

`key`: deterministic slug of `label` (lowercased, non-alphanumeric -> `-`,
collapsed, trimmed). Stable across runs so dedup works. Collisions (two rows
slugging identically) are a hard error in extract, not a silent merge.

### 5.2 verdicts.json (judge -> apply)

```json
[
  {
    "key": "microsoft-apicenter-apisources-targetenvironmentid",
    "status": "fired | clear | uncertain | not_doc_checkable",
    "reason": "one-line why (esp. for not_doc_checkable / uncertain)",
    "evidence": "what the current Learn doc says vs the recorded claim",
    "learn_url": "https://learn.microsoft.com/... (the page consulted)",
    "drafted_body": "markdown body for the issue (used only when fired/uncertain)"
  }
]
```

- `fired`: the documented contract appears to have changed; open a candidate.
- `uncertain`: the model could not resolve it either way; open a candidate
  (framed as needing human judgement) rather than dropping it. Conservative by
  design.
- `clear`: the docs still match the recorded claim; no issue.
- `not_doc_checkable`: the trigger is not a Microsoft-Learn condition (internal
  event, ADR reference, non-Learn source, package release owned by #64); no
  issue, but surfaced in the summary.

## 6. Dedup and lifecycle

- Title `drift-candidate: <key>` is the dedup handle. One open issue per key.
- A still-open candidate that re-fires next week is left silent (summary lists
  it). A human closes the issue after re-verifying and updating the row.
- The agent never auto-closes. If a key that has an open issue now judges
  `clear`, the summary says "key X now clear - you may close #N"; the human
  decides.
- Issue author is `github-actions[bot]` (the Actions default token), which reads
  as unambiguously machine-generated. The `agent:claude` label is a PR
  attribution rule in governance, not an issue rule, and is not applied here.

## 7. Safety and governance

- Fail-loud: any step's non-zero exit turns the run red so a dead weekly agent
  is visible (a silently-dead drift checker is itself an undetected drift risk).
- 5 new issues max per run; overflow suppressed and recorded.
- The model has no write tools and no `GITHUB_TOKEN`; the worst a bad model day
  can do is produce wrong *verdicts* in a JSON file, which the harness caps and a
  human triages. It cannot open rogue issues beyond the cap.
- No secrets in the repo. The single credential is `ANTHROPIC_API_KEY`, provided
  by Hari in a protected GitHub Environment, scoped to the LLM only (it grants no
  access to the Azure estate; it is not a cloud/tenant credential). This is a
  deliberate, Hari-approved exception to the OIDC-only preference, recorded in
  ADR-008 with its rationale.
- `ubuntu-latest` only; never `pull_request_target`.

## 8. Testing and CI

- Unit tests (Python stdlib `unittest`, no third-party dependency, matching the
  dependency-free stance of `scripts/check-mcp-parity`) for the deterministic
  scripts:
  - `extract_triggers.py`: a fixture COMPATIBILITY.md snippet (including a
    non-trigger row, a trigger row, and a row whose trigger is an ADR reference)
    -> asserted work-list, including key-slug determinism and the collision
    error path.
  - `apply_verdicts.py` via `--dry-run`: fixture work-list + verdicts + a mocked
    open-issues list -> asserted intended actions for each status, the
    completeness gate, the dedup skip, the 5-cap suppression, and the "now clear
    -> you may close" summary line.
- A new **non-required** CI job in `.github/workflows/ci.yml` (stable job name,
  not added to branch protection) runs these tests. It guards itself with `find`
  and prints SKIPPED until the scripts land, consistent with the existing
  self-guarding CI steps. The job runs `python3 -m unittest discover` over
  `scripts/drift/tests` using the runner's stdlib Python (no `pip install`),
  mirroring the dependency-free `mcp-parity` job.
- The model's judgement is not unit-tested (non-deterministic). The harness
  around it is fully tested.

## 9. Documentation deliverables (same PR)

- **ADR-008** in `docs/decisions/`: the decision record - flag-not-assert; the
  thin-agent/fat-harness split; the `ANTHROPIC_API_KEY`-in-protected-environment
  exception to OIDC-only and why; the #4<->#64 seam; and rejected alternatives
  (assert-as-fact; staleness-only reminder; fat-agent-with-write; GPT-via-OIDC
  which would violate the Claude verification-tier binding).
- A short **"Drift verification agent"** subsection under AGENTS.md PROJECT
  MECHANICS (Hari-approved edit; outside the Hari-only GOVERNANCE block),
  parallel to the CI and MCP-parity subsections, describing the workflow and
  pointing at the #64 seam.

## 10. Acceptance checklist

- [ ] `scripts/drift/extract_triggers.py` parses COMPATIBILITY.md and emits the
      work-list contract (5.1); deterministic; collision path errors.
- [ ] `scripts/drift/prompt.md` instructs the judge step per 4.2 and the verdict
      contract (5.2), including the `not_doc_checkable` classification.
- [ ] `scripts/drift/apply_verdicts.py` implements dedup, the 5-cap, label
      application (`needs-triage` + `drift-candidate`), the run summary, and
      `--dry-run`; fails loud on malformed input.
- [ ] `.github/workflows/compat-drift.yml`: weekly cron + `workflow_dispatch`;
      `issues:write`+`contents:read`; protected environment for
      `ANTHROPIC_API_KEY`; concurrency guard; `ubuntu-latest`; model
      `claude-opus-4-8`; microsoft-learn MCP wired, no write tools.
- [ ] stdlib `unittest` tests for `extract` and `apply` (via `--dry-run`)
      covering the status matrix, completeness gate, dedup, cap, and collision
      path.
- [ ] Non-required CI job added to `ci.yml` with a stable name, self-guarding
      with `find`, not promoted to required (PR requests Hari promote if wanted).
- [ ] ADR-008 recording decisions and rejected alternatives.
- [ ] AGENTS.md PROJECT MECHANICS "Drift verification agent" subsection + #64
      seam note.
- [ ] `drift-candidate` label created in the repo (via `gh label create`, noted
      in the PR body; it is a filter/attribution label, not a Hari-only triage
      label).
- [ ] PR references issue #4, carries `agent:claude`, review requested from Hari,
      not merged.

## 11. Tooling facts (verified 2026-08-02 via claude-code-guide against the
action's docs; Anthropic/GitHub facts, not Azure claims)

- `anthropics/claude-code-action@v1` is the GA entrypoint (the `base-action` repo
  is a mirror). It takes a direct `prompt` and `anthropic_api_key`, plus a
  `claude_args` string carrying CLI flags: `--model`, `--mcp-config` (inline JSON
  or file), `--allowedTools`, `--max-turns`. It exposes outputs `conclusion`
  (`success`/`failure`) and `execution_file`.
- A remote HTTP MCP server is declared as
  `--mcp-config '{"mcpServers":{"microsoft-learn":{"type":"http","url":"https://learn.microsoft.com/api/mcp"}}}'`.
  MCP tools are allowlisted as `mcp__<server>__*`. This is the same endpoint the
  repo already declares in `.mcp.json` and against which dozens of
  COMPATIBILITY.md rows were verified, so its reachability is established, not
  assumed.
- Opus 4.8 API id is `claude-opus-4-8` (dashes; `claude-opus-4.8` 404s).
- First real end-to-end execution requires Hari's `ANTHROPIC_API_KEY` in the
  protected environment; the workflow is `workflow_dispatch`-able so Hari can
  validate it once the secret lands. Fail-loud makes a broken run visible.

## 12. Rejected alternatives (summary; full reasoning in ADR-008)

- **Staleness-only reminder** (flag rows past a date threshold, no live doc
  check): secrets-free and simplest, but does not do what the issue asks
  ("re-verify against current Microsoft docs"). Rejected as under-delivering.
- **Assert drift as fact**: cleaner issue text, but any hallucination becomes a
  confident public false claim. Rejected on the honesty rule.
- **Fat agent with `gh` write access**: least code, but puts public-issue
  creation and the safety rails in the model's instruction-following. Rejected;
  side effects must be deterministic.
- **GPT via Azure OpenAI OIDC**: removes the static secret and is native to the
  Azure estate, but contradicts the CLAUDE.md binding of the verification tier to
  Claude/Opus. Rejected as a governance inconsistency.
