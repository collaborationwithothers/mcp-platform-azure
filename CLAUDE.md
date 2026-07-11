# CLAUDE.md

Rules for AI agents working in this repository. The GOVERNANCE section is
maintained by Hari only; do not edit it. Append discovered mechanics
(commands, conventions) under PROJECT MECHANICS at the bottom.

## GOVERNANCE (do not edit)

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

### Style

- ASCII punctuation only everywhere: no em dashes, no en dashes, no smart
  quotes. Metric units.
- Docs land in the same PR as the code they describe. No code-only PRs.
- ADRs record real reasoning and rejected alternatives, not generic
  explanations.

## PROJECT MECHANICS (Claude Code: append below as you learn the codebase)

## Agent skills

Config for the Matt Pocock engineering skills. Full details under docs/agents/.

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