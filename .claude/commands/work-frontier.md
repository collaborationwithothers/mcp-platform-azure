---
description: Work the frontier: pick up the next ready v1 issue, implement it, open a PR, stop.
model: sonnet
disable-model-invocation: true
---

Work the frontier: the lowest-numbered open v1 issue labelled
ready-for-agent. If none exists, say so and stop; do not select any other
issue.

Read, in order, before writing anything: CLAUDE.md, the issue in full
(including its acceptance checklist and out-of-scope list), and the spec
sections the issue links (docs/specs/v1-tracer-bullet.md).

First action: any issue-start verification step the ticket defines (AVM
capability checks, ARM API version re-verification, package pins), using
the azure-docs-verifier subagent and the terraform MCP registry tools.
Record the outcome as the ticket requires before implementing against it.
If the ticket defines no such step, proceed.

Then: create a branch from up-to-date main named for the issue, and
/implement the ticket, honouring its acceptance checklist and out-of-scope
list exactly. Open a PR referencing the issue using the PR template, watch
CI with gh pr checks, and fix failures until green.

Finish: complete the PR template's review summary section, including the
Microsoft Learn links justifying every Terraform, azapi, policy, or auth
decision in the diff; tick only the checklist items that are actually true;
request review from haripraghash; and stop.

Hard stops:
- Do not merge, regardless of CI state or merge class.
- Do not start another issue.
- Do not modify the issue's scope; if the ticket cannot be verified or
  completed as written, say so in the PR (or as an issue comment if no PR
  is warranted) instead of improvising.