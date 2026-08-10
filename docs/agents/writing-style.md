# Writing style

This file is the concrete half of the "Writing standards" section in
AGENTS.md. That section holds the rules; this file holds the exemplar that
shows the target register, the banned-constructions list that reviews enforce,
and the Learned rules list that grows by the correction ratchet. Read this
file before writing any substantial doc and match the exemplar's register.

## The register: one sample, before and after

Both paragraphs below describe the same feature and contain the same facts.
The first is the register agents drift into by default. The second is the
register this repo requires.

Before (do not write like this):

> This document provides a comprehensive overview of the implementation of
> per-tool authorization functionality within the APIM gateway. It should be
> noted that the authorization capability is facilitated through the
> utilization of the gen_ai.tool.name context variable, which enables the
> differentiation of individual tool invocations. In order to ensure that
> unauthorized tool calls are rejected in a robust manner, a policy fragment
> has been implemented that performs validation of the caller's application
> roles against the requested tool.

After (write like this):

> The gateway decides, per call, whether the caller may run the tool it is
> asking for. Without this check, any caller holding a valid token could run
> every tool the server exposes. The policy reads the tool name from the
> gen_ai.tool.name context variable that APIM sets on each MCP call, checks
> it against the caller's app roles, and rejects the call with a typed MCP
> error when the role is missing.

Why the second one works:

- It opens with what the thing does and why it matters, in plain words. The
  "before" paragraph opens by describing itself.
- Every verb is doing work: decides, reads, checks, rejects. The "before"
  version hides those actions inside nouns (implementation, utilization,
  differentiation, validation).
- Same facts, fewer words, and nothing lost. Simplifying is cutting ceremony,
  not cutting content.

## Banned constructions

Using one of these in a doc, PR description, review summary, ADR, or comment
is a review finding. The replacement is always shorter.

| Banned | Write instead |
| --- | --- |
| it should be noted that / it is important to note | (delete; just say the thing) |
| in order to | to |
| utilize, utilization | use |
| leverage (as a verb) | use |
| facilitate, enable (when the subject just does the thing) | the plain verb: does, runs, checks |
| comprehensive, robust, seamless, cutting-edge | (delete; empty praise proves nothing) |
| functionality, capability (as filler) | name the behaviour |
| the implementation of X was performed | X was implemented, or better: we/it implemented X |
| as mentioned above / as previously discussed | restate the fact in half a sentence, or link the section |
| passive voice that hides who acts, when the actor matters | name the actor: "the gateway rejects", not "the call is rejected" |

The list is a floor, not a ceiling: prose can avoid every entry and still be
robotic. When in doubt, reread the exemplar.

## Learned rules

Grown by the correction ratchet in AGENTS.md ("Writing standards"): every
time Hari corrects wording, tone, or structure in a session, the agent
appends one line here capturing the general rule behind the correction.
One line per rule, dated, newest last. Rules here carry the same weight as
the AGENTS.md rules above them.

- 2026-08-08: If Hari has to ask "explain what this says" or "simplify
  this", the document failed; fix the document, do not just answer in chat.
- 2026-08-10: If Hari says he doesn't understand and to treat him as new to
  the repo/session, that is not a request to compress further; drop jargon,
  define terms plainly, and rebuild the explanation from the ground up, even
  if it runs long.
- 2026-08-10: A document that has accumulated dated corrections over time
  (a live-state runbook, a demo record) should separate CURRENT STATE from
  HISTORICAL EVIDENCE into distinct sections, not interleave "note added on
  <date>" patches into the procedure a reader is meant to follow today;
  historical evidence stays dated and undisturbed in its own section.
