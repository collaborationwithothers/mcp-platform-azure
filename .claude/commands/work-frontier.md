---
description: Work the frontier: pick up the next ready v1 issue, implement it, open a PR, stop.
model: sonnet
disable-model-invocation: true
---

Run the frontier workflow defined in AGENTS.md (PROJECT MECHANICS > "Frontier
workflow"), acting as the "claude" agent in AGENTS.md's dual-agent handoff
protocol: branch prefix claude/, apply in-progress:claude on start, add the
agent:claude label on the PR, and follow the takeover steps in "Dual-agent
operation" if the ticket already carries in-progress:codex (read the diff, swap
the label, add agent:claude alongside the existing label, resume on the same
branch, and record the takeover in the PR description).

AGENTS.md is loaded via CLAUDE.md's @AGENTS.md import; follow its frontier
selection rule, read order, issue-start verification step, branch/implement/PR/CI
steps, finish steps, and hard stops exactly. Do not merge. Do not start another
issue.
