---
description: Governance review of a PR against its issue, the spec, and AGENTS.md. Opus-pinned.
model: opus
argument-hint: [pr-number]
disable-model-invocation: true
---

Governance review of PR #$0.

Run the governance review workflow defined in AGENTS.md (PROJECT MECHANICS >
"Governance review workflow"), substituting PR #$0 for "the PR" throughout.
AGENTS.md is loaded via CLAUDE.md's @AGENTS.md import; follow its read order, the
six review steps (code-review pass, independent claim verification, acceptance
checklist walk, out-of-scope check, governance checks, and the mixed-agent harder
pass), the output format, and the hard stops exactly.

This is the review-tier binding: governance review is Claude/Opus-only for all
bot PRs, including Codex-authored or Codex-resumed ones (AGENTS.md, "Dual-agent
operation"). This session is read-only and never merges, approves on GitHub, or
posts to GitHub; the findings are for Hari.
