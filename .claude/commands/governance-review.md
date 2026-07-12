---
description: Governance review of a PR against its issue, the spec, and CLAUDE.md. Opus-pinned.
model: opus
argument-hint: [pr-number]
disable-model-invocation: true
---

Governance review of PR #$0.

Identify the issue this PR references (from the PR body). Read, in order:
CLAUDE.md, the issue in full (acceptance checklist and out-of-scope list),
the spec sections the issue links (docs/specs/v1-tracer-bullet.md), the PR
review summary, and the full diff (gh pr diff $0).

Then:

1. Run /code-review on the diff.
2. Independently verify the load-bearing claims using the
   azure-docs-verifier subagent and the terraform MCP registry tools: every
   ARM API version, azapi payload shape, AVM version and input name, policy
   or auth setting, and every COMPATIBILITY.md row added or changed. Do not
   trust the PR's own links; re-derive them. Report each claim as
   VERIFIED / REFUTED / PARTIAL / UNVERIFIABLE.
3. Walk the issue's acceptance checklist item by item: quote the diff
   evidence that satisfies each item, or state plainly which items lack
   evidence. An unticked or unevidenced item is a finding, not a footnote.
4. Check the out-of-scope list: confirm nothing forbidden is present in the
   diff.
5. Check governance: no secrets, keys, or tenant/subscription ids; pins
   present with COMPATIBILITY.md rows in the same PR; docs land with the
   code; module interfaces match the ticket exactly; PR template checklist
   ticks are each actually true; ASCII punctuation in docs; no unmeasured
   figures, estimates labelled.

Output: a verdict (APPROVE or REQUEST CHANGES) followed by a numbered
findings list ordered by severity, each finding citing the file and line or
claim it concerns. Separate a final short section: "For Hari to check by
hand", naming the one or two highest-leverage things a human should verify
directly (a registry page, a doc paragraph, a design judgement).

Hard stops:
- Do not merge, approve on GitHub, or post to GitHub; the findings are for
  Hari, who acts on them himself.
- Do not modify any file. This session is read-only; fixes happen in the
  implementation session or a follow-up commit by Hari.
- If the PR's referenced issue cannot be identified, stop and say so. 