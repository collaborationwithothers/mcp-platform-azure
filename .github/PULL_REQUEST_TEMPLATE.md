<!-- Title: imperative, scoped, e.g. "Add apim-mcp-server azapi module" -->

## What and why

<!-- Two to four sentences. What changed, why, and the design decision if one
was made. Link the spec section for rationale rather than restating it. -->

Closes #

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
- [ ] Docs land in this PR (no code-only change)
- [ ] COMPATIBILITY.md row added or updated for any new/changed pin, or N/A
- [ ] No secrets, keys, connection strings, or tenant/subscription IDs
- [ ] No terraform apply/destroy outside the gated live-test environment
- [ ] Estimates labelled as estimates; no unmeasured figures; synthetic data
      labelled; ASCII punctuation
- [ ] Live-test run link (needs-live-test PRs only):