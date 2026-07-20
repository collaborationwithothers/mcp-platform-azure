# ADR-007: Registry conformance is a two-tier concern - synchronous gateway gate, asynchronous registry monitor

Status: Proposed
Date: 2026-07-20

## Context

Scenario S3 exposes the MCP server through the Azure API Center data-plane MCP
registry endpoint (`/workspaces/default/v0.1/servers`). The v1 tracer's live
gate (`.github/workflows/ephemeral-env.yml` + `scripts/gate/invoke-and-assert.ps1`)
runs apply -> call -> destroy against an ephemeral environment. Step `[5]`
originally asserted, with a 300 s bounded poll, that the deployed server appears
in that registry list, and failed the run if it did not.

That assertion couples a synchronous required check to an asynchronous,
eventually-consistent property. Three facts, verified against current Microsoft
Learn on 2026-07-20 with the documentation-verification agent (three passes),
establish why that is the wrong shape:

1. **Auto-sync is unbounded relative to the gate.** API Center is populated the
   production-correct way, by one-way APIM -> API Center auto-sync. Learn states
   the sync "typically synchronize[s] ... within minutes, but ... can take up to
   24 hours." The linked integration IS documented to include "MCP servers and
   A2A agent APIs" with `kind` "determined in integrated API source", so an MCP
   server is expected to converge on the production path -- but eventually, on a
   timescale an ephemeral gate cannot wait out.

2. **Explicit registration is not automatable.** The obvious fix -- register the
   server so it is present at apply time -- has no automatable surface:
   - azapi / ARM: `Microsoft.ApiCenter/services/workspaces/apis` has a `kind`
     enum of `graphql/grpc/rest/soap/webhook/websocket` with no `mcp` value in
     any documented api-version, and no Learn page documents an MCP-kind payload.
   - `az apic` CLI: no MCP command group; `--type` has no `mcp`; `az apic api
     register` is OpenAPI-spec only.
   - `az rest` against the data plane: the data-plane API (2024-02-01-preview)
     has no write operation at all (the `Apis` group is Get/List/List All).

   An on-demand import path exists (`az apic import-from-apim`), pinned from the
   installed apic-extension 1.1.0 (current stable; the rename to `az apic import
   apim` is only in the 1.2.0b3 beta). It is a long-running operation that blocks
   to completion by default (`--no-wait` to opt out), so the CLI is synchronous.
   But the behavioral questions remain live-only and UNVERIFIABLE: whether it
   preserves MCP kind and surfaces at `/v0.1/servers`, whether it coexists with
   an active linked apiSources source, and whether the data-plane registry
   projection is immediate once the control-plane LRO returns. It is a possible
   future escape hatch that needs a live spike, not a usable mechanism today.

3. **A synchronous assertion of an eventual property is a flaky required check.**
   One slow sync day turns the gate red for reasons unrelated to the diff. The
   real damage is second-order: a required check that goes red without a code
   cause trains the team to ignore red, eroding the signal of every legitimate
   failure. Gateway correctness (does the request route and authorize) is a true
   synchronous invariant; registry membership is not.

## Decision

Treat registry conformance as an eventual-consistency concern and split it into
two tiers.

- **Tier 1 - the blocking gate - asserts gateway and backend correctness
  synchronously and makes NO API Center assertion.** Steps 1-4 and 6 of
  `invoke-and-assert.ps1` (MCP session and tool contracts, app-role negative
  path, raw-HTTP discovery/PRM, OBO passthrough negative) are unchanged and
  remain the required check. Step `[5]` becomes **non-blocking registry
  evidence**: it records the anonymous posture, the authenticated read status
  (a 401 = wrong data-plane audience, a 403 = Data Reader role not propagated,
  each surfaced as a `::warning::`), and whether the server has converged, and
  captures the full `/v0.1/servers` body to the `gate-evidence` artifact. Nothing
  in step `[5]` can fail the run. The poll window drops 300 s -> 90 s (a brief
  evidence look, not a wait).

- **Tier 2 - registry convergence - is monitored asynchronously.** The intended
  shape is a scheduled nightly workflow (or a post-gate, non-required check) that
  polls `/v0.1/servers` for the expected Contoso orders entry with a wider
  bounded window (order of 10-15 minutes, sized to the "typically minutes"
  behavior) and fails loudly on the nightly run if the entry never converges.
  This is the realistic enterprise pattern: assert synchronous invariants in the
  PR gate, reconcile eventually-consistent inventory on a schedule.

- **Tier 2 is designed here but deliberately NOT implemented,** on cost grounds
  (a nightly live environment spin-up bills real money). Its captured Tier-1
  evidence artifact is the seed a future implementation reuses. Do not implement
  Tier 2 as a synchronous addition to Tier 1 to avoid the cost; that reintroduces
  the exact flaky required check this ADR removes.

- **No guessed code ships.** No azapi resource, `az` command, or match field is
  written against an unverified shape.

## Consequences

- The blocking gate is deterministically green on a correct deployment: it never
  fails on an async (auto-sync) or a doc gap (registration shape) it cannot
  control. What it asserts -- gateway routing and authorization -- is the part
  that genuinely proves the S3 request path.
- The blocking gate's synchronous claim is narrower than "the server is
  discoverable in the registry." That end-to-end property is a Tier 2 concern
  (unimplemented) plus the manual portal/Copilot discovery walkthrough in the
  demo. This is stated in the module README, `docs/security.md`, and
  `docs/runbooks/live-test-gate.md`.
- Registry regressions are not caught synchronously while Tier 2 is
  unimplemented. This is an accepted, documented gap: the Tier-1 evidence
  artifact still records each run's registry state for manual inspection, and the
  production auto-sync path is documented to converge.
- A future PR can implement Tier 2, or restore a harder assertion, if the
  economics change or Microsoft ships an automatable registration/import surface.
  All are recorded as re-check triggers in COMPATIBILITY.md.

## Alternatives considered

- **Synchronous registry assertion in the blocking gate** (the original step [5],
  and my first reframe that kept a deterministic authenticated-read fail).
  Rejected: registry membership is eventual (auto-sync up to 24 h), so any
  synchronous fail on it is flaky, and a flaky required check trains the team to
  ignore red. Even the narrower "authenticated read must succeed" fail was folded
  into Tier 2 as a warning, so that Tier 1 makes no API Center assertion at all.
- **Explicit azapi registration as a determinism fallback** (an earlier plan).
  Rejected: refuted by verification -- no azapi/ARM MCP-registration payload
  exists; the `apis kind` enum has no `mcp`. A plain `apis` resource would apply
  green while never appearing at `/v0.1/servers`.
- **Imperative `az apic` / `az rest` registration in the gate.** Rejected: no
  `az apic` MCP command exists and the data-plane API has no write operation.
- **On-demand import escape hatch (`az apic import-from-apim`) to force a
  synchronous import.** Not adopted, and not built on. The command shape is
  pinned from the installed apic-extension 1.1.0 (`az apic import-from-apim
  --apim-apis <* | [name,...]> --apim-name <n> --service-name <apic> -g <rg>
  [--no-wait]`) and it is an LRO that blocks by default, so CLI synchronicity is
  fine. What blocks adoption is behavioral and live-only: whether the import
  preserves MCP kind and surfaces at `/v0.1/servers`, whether it coexists with the
  active linked apiSources source without conflict, and whether the data-plane
  projection is immediate. The live spike is: apply s2, run `import-from-apim`
  for the MCP server API, then GET `/v0.1/servers` and check (a) the entry
  appears, (b) it is recognizably an MCP server, (c) the pre-existing apiSources
  link did not error or duplicate. Kept as a re-check trigger with that recipe --
  never a dependency until the spike passes.
- **Long or looping poll on auto-sync.** Rejected for the blocking gate: the
  worst case is 24 h, unbounded; a finite poll is a coin flip on sync latency.
  Adopted instead as the shape of the async Tier 2 monitor, where a wider bounded
  window and a loud nightly failure are appropriate.
- **Portal-oracle capture** (register once in the portal with browser devtools
  open, pin the real ARM request the way `mcpProperties`/backend wiring were
  pinned). Deferred, not rejected: it is the route to a harder assertion later,
  but needs a manual capture and likely a long-lived API Center.
- **Manual portal registration into a long-lived API Center.** Rejected for the
  ephemeral gate: the service is created and destroyed each run under a
  unique-per-run name (soft-delete tombstone avoidance, COMPATIBILITY.md), so a
  one-time registration would not survive; moving API Center out of the ephemeral
  group is a larger change out of scope here.

## References

- APIM -> API Center sync latency (up to 24 h) and MCP-server inclusion on the
  linked path:
  https://learn.microsoft.com/azure/api-center/synchronize-api-management-apis
- On-demand import from APIM (tutorial; command deprecated/churning):
  https://learn.microsoft.com/azure/api-center/import-api-management-apis
- Register and discover MCP servers (portal-only registration; endpoint form):
  https://learn.microsoft.com/azure/api-center/register-discover-mcp-server
- `Microsoft.ApiCenter/services/workspaces/apis` (kind enum, api-versions):
  https://learn.microsoft.com/azure/templates/microsoft.apicenter/services/workspaces/apis
- COMPATIBILITY.md rows: "Explicit MCP-server registration into API Center",
  "API Center on-demand import from APIM", "API Center `/v0.1/servers` data-plane
  response schema + match field", "APIM -> API Center auto-sync latency".
