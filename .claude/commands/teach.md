---
description: Socratic walkthrough of a merged PR for Hari's learning; ends with a note in his Obsidian vault. Repo read-only.
argument-hint: [pr-number]
disable-model-invocation: true
---

Teach PR #$0. If no number is given, use the most recently merged PR.

This command exists because this repo's purpose is Hari's learning, and diffs
are a poor medium for it: the repo's own governance rules make a one-concept
change ship inside a 10-file fan-out, and reading that fan-out teaches
editing, not architecture. This session converts one merged PR into one
understood concept. It is not a review; the PR already merged.

Hard rules for this session:

- Read-only on the repository and GitHub. Do not edit files, commit, or post
  to GitHub. The only artifact this session produces is the Obsidian note.
- Hari's global interviewing style applies throughout: one question at a
  time, never a list of questions in one turn.

## Prepare (before saying anything substantive)

Read the PR body, the issue it closes, and the diff (gh pr view, gh pr diff).
Find the kernel: the one to three files that carry the concept. PRs opened
after the template gained a "Reading order" section declare it; for older
PRs, derive it yourself and say which files you chose and why.

## Walk through (the bulk of the session)

Work from the kernel outward, Socratically. The goal is that Hari can
reconstruct the change from memory, not that he has seen every hunk.

1. State the concept in the writing-style register: what was true of the
   system before this PR, what is true after, why it mattered.
2. Walk the kernel files. For each, explain what it does in the running
   system, then ask Hari one question that checks the mental model (a "what
   happens if" or "why not the alternative" question, never trivia like file
   names or line numbers).
3. If Hari's answer reveals a gap, rebuild that part of the explanation from
   the ground up before moving on. Do not paper over a wrong answer to keep
   the session short.
4. Summarise the fan-out in at most one line per file: which rule pulled it
   in. Do not walk fan-out diffs unless Hari asks.
5. Surface the one thing worth remembering in six months: the decision, its
   strongest rejected alternative, and the trade-off that decided it.

## Capture (end of session)

Use the obsidian-vault skill to save one note to Hari's vault. Title:
"mcp-platform issue NN: <concept in five words or fewer>". Body is five
bullets, nothing more:

- Problem: what was wrong or missing before.
- Decision: what the change does, one sentence.
- Rejected: the strongest alternative and why it lost.
- Mechanism: how the kernel works, two sentences max.
- Remember: the one thing worth knowing in six months.

Wikilink related notes from earlier teach sessions where they exist. If the
vault is unreachable, print the note in chat and say it was not saved; do not
silently drop it.
