# Domain Docs

How the engineering skills consume this repo's domain documentation.

## Before exploring, read these

- CONTEXT-MAP.md at the repo root: it points at one CONTEXT.md per context.
  Read each one relevant to the topic.
- docs/decisions/ for ADRs that touch the area you are about to work in. This
  repo uses docs/decisions/ (named in CLAUDE.md governance), not docs/adr/.

If any of these files do not exist yet, proceed silently. Do not flag their
absence. The /domain-modeling skill creates them lazily when terms or decisions
actually get resolved.

## Contexts (multi-context repo)

Signalled by CONTEXT-MAP.md at the root.

- infra/CONTEXT.md: Terraform modules, azapi, APIM and API Center, Azure
  resource vocabulary (scenario S3).
- src/CONTEXT.md: the Entra-secured .NET Functions MCP server and the APIM MCP
  gateway application code (scenarios S1, S2).

System-wide ADRs live in docs/decisions/. Context-scoped ADRs, if any, may live
in infra/docs/decisions/ or src/docs/decisions/.

## Use the glossary's vocabulary

When your output names a domain concept, use the term as defined in the relevant
CONTEXT.md. Do not drift to synonyms the glossary avoids. A missing term is a
signal: either you are inventing language the project does not use, or there is
a real gap to note for /domain-modeling.

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly:

> Contradicts ADR-0007 (title) but worth reopening because...
