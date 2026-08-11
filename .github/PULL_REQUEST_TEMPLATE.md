<!-- Title: imperative, scoped, e.g. "Add apim-mcp-server azapi module" -->

## The concept

<!-- Ten lines max. The one idea this PR adds, stated as a change to the
reader's mental model: what was true of the system before this PR, what is
true after, and the design decision if one was made. No file names here; the
concept must make sense without the diff. Link the spec section for rationale
rather than restating it. A reader who stops here must leave with the right
idea. -->

Before this PR:

After this PR:

Closes #

## Reading order: core files first

<!-- Split every changed file into two lists. Core: the files that carry the
concept (aim for one to three). Supporting: every other file, one line each
naming the repo rule that pulled it in (docs land with code, COMPATIBILITY.md
row, gate evidence, diagram honesty, runbook currency). Reading the core
files alone must be enough to understand the change; the supporting list
exists so its bulk stops hiding the concept. -->

Core:

-

Supporting:

-

## Merge class

<!-- Exactly one. See CLAUDE.md GOVERNANCE > Merge classes. -->

- [ ] auto-merge-ok: docs formatting, typos, or lockfiles ONLY (label must be
      applied by Hari before merge)
- [ ] Requires review: everything else (infra, src, .github, ADRs, README,
      COMPATIBILITY.md)
- [ ] needs-live-test: changes deployed behaviour (label applied; live
      apply-call-destroy run link goes below before merge)

## Review summary

<!-- Written by the implementing agent. What a reviewer must check, and the
Microsoft docs links that justify every azapi payload, ARM API version, AVM
input, policy, or auth setting in this diff. UNVERIFIABLE claims do not ship. -->

## Checklist

- [ ] Review pass run on Opus 4.8
- [ ] Azure capability claims verified via azure-docs-verifier (links above)
- [ ] Docs land in this PR, or this is a code PR whose same-ticket docs PR
      is linked in "The concept" (no code-only ticket)
- [ ] COMPATIBILITY.md row added or updated for any new/changed pin, or N/A
- [ ] No secrets, keys, connection strings, or tenant/subscription IDs
- [ ] No terraform apply/destroy outside the gated live-test environment
- [ ] Estimates labelled as estimates; no unmeasured figures; synthetic data
      labelled; ASCII punctuation
- [ ] Live-test run link (needs-live-test PRs only):