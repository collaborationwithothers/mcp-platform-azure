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

## Deliver the results twice

First in chat, exactly per the AGENTS.md output format: verdict, numbered
findings by severity, "For Hari to check by hand". The chat output is the
source of truth.

Then as a scannable report page, published with the Artifact tool (this is the
rendering AGENTS.md's "Governance review workflow" Output section permits).
Write the HTML to the session scratchpad, never into the repository; the
read-only hard stop governs repository files and GitHub, not the scratchpad or
the Artifact tool. The artifact is private to Hari unless he shares it. Load
the artifact-design skill before writing the page. Title the page
"Governance review: PR #$0" and keep the same favicon across re-publishes.

Page structure, top to bottom:

1. Verdict banner: APPROVE or REQUEST CHANGES, stated in text as well as
   colour, with the PR number and title, the referenced issue, the agent:*
   labels, and a visible flag when the mixed-agent harder pass applied.
2. Counts strip: findings per severity; claims VERIFIED / REFUTED / PARTIAL /
   UNVERIFIABLE; acceptance checklist items evidenced versus unevidenced.
   Every number links or scrolls to its section.
3. Findings, ranked by severity. Each finding shows its one-sentence problem
   statement and its file/line or claim citation always visible; supporting
   detail sits in a collapsible block. Severity is shown as a text label plus
   colour, never colour alone.
4. Claim verification table, one row per load-bearing claim, colour-coded by
   verdict with the verdict word in the cell, linking the re-derived Microsoft
   Learn or registry evidence (not the PR's own links).
5. Acceptance checklist walk: each item with its status and the quoted diff
   evidence in a collapsible block; unevidenced items are visually loud, not
   hidden.
6. Out-of-scope and governance checks as a compact pass/fail list; only
   failures carry detail.
7. "For Hari to check by hand" as a visually distinct callout, always
   expanded, never collapsible.

Rendering rules: the page carries exactly the chat output's content, ordered
the same way, softening or omitting nothing. An APPROVE with zero findings
yields a deliberately short page; do not pad it. If the Artifact tool is
unavailable in the session, say so and stop after the chat output; the chat
output alone satisfies the workflow.
