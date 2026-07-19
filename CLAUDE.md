@AGENTS.md

# CLAUDE.md

This file is the Claude Code entry point. Its first line imports AGENTS.md, the
single source of truth for all tool-neutral rules (governance, scope, safety,
verification, ticket workflow, dual-agent operation). Claude Code expands that
import at session start, so a Claude session loads the same effective
instructions it did before AGENTS.md was split out; the sections below add only
the Claude-Code-specific bindings that AGENTS.md deliberately leaves to each
tool. Do not duplicate any AGENTS.md rule here.

## Claude Code bindings

### Model bindings for the tier split

AGENTS.md ("Implementation and governance review are separate") defines two
tiers tool-neutrally. Claude Code binds them:

- Implementation tier: Sonnet 5 (effort high). Implementation sessions run on
  this model. The /code-review self-check that runs before opening a PR is part
  of implementation and runs on the implementation model.
- Review tier: Opus 4.8 (effort high). Governance review runs on this model, in
  a separate session, with Hari, and never by the session or agent that authored
  the change. If Hari starts a governance review session that is not on
  Opus 4.8, the session should say so before reviewing.

The rule that governance review is Claude/Opus-only for all bot PRs and does not
fail over to Codex lives in AGENTS.md ("Dual-agent operation"); this binding is
why the review tier is Opus 4.8.

### Agent identity for the handoff protocol

When Claude Code acts as the loop agent it is the "claude" agent in AGENTS.md's
handoff protocol: branch prefix claude/, in-progress label in-progress:claude,
attribution label agent:claude.

### Commands

- /work-frontier (.claude/commands/work-frontier.md, Sonnet): runs the frontier
  workflow defined in AGENTS.md as the claude agent.
- /governance-review (.claude/commands/governance-review.md, Opus): runs the
  governance review workflow defined in AGENTS.md.

### Subagents

- azure-docs-verifier is Claude Code's binding for the documentation-
  verification role in AGENTS.md's truth and verification rules. Use it for
  every Azure capability claim, ARM API version, azapi shape, AVM input, policy,
  or auth setting before it goes into code or docs. If it returns UNVERIFIABLE,
  the claim does not ship.

## PROJECT MECHANICS (Claude Code: append below as you learn the codebase)

Tool-neutral mechanics (issue tracker, triage labels, domain docs, CI, skills,
Terraform version, MCP parity) live in AGENTS.md under PROJECT MECHANICS. Append
only Claude-Code-specific mechanics here.
