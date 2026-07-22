# mcp-platform-azure

## Author

Designed and built by [Hari Praghash](https://github.com/haripraghash)
([LinkedIn](https://www.linkedin.com/in/haripraghash/)): Principal-level Azure
platform engineer, London. Implementation is agent-assisted (Claude Code /
Codex under a machine account) with human-owned architecture, review gates,
and sign-off; the governance model for that is itself documented in AGENTS.md.

Public portfolio reference implementation: enterprise hosting and governance
of MCP (Model Context Protocol) servers on Azure, built Terraform-first with
azapi where the AzureRM provider lags. Full design reasoning:
[docs/blueprint.md](docs/blueprint.md); the v1 slice being built now:
[docs/specs/v1-tracer-bullet.md](docs/specs/v1-tracer-bullet.md).

## Scenario index (v1)

| Scenario | What it is | Composition |
|---|---|---|
| **S1** | Entra-secured .NET Azure Functions MCP server, standing alone (no gateway). | [`infra/terraform/scenarios/s1-entra-mcp-server`](infra/terraform/scenarios/s1-entra-mcp-server) |
| **S2** | Multi-tenant APIM MCP gateway (public-demo profile) fronting the S1 backend, with an API Center registry entry synced automatically. | [`infra/terraform/scenarios/s2-apim-mcp-gateway`](infra/terraform/scenarios/s2-apim-mcp-gateway) |

Both compositions are proven by static validation only in PR CI
(`terraform fmt`/`init -backend=false`/`validate`/`tflint`/`checkov`). The
live apply-call-destroy proof runs in
[`.github/workflows/ephemeral-env.yml`](.github/workflows/ephemeral-env.yml),
gated to a `live-test` GitHub Environment, manual (`workflow_dispatch`) only,
never triggered by a pull request or push to `main`.

S3 (the Terraform modules themselves: `mcp-function-host`, `apim-gateway`,
`apim-mcp-server`, `api-center-registry`) is not a standalone scenario; it is
the module layer both compositions above call. See each module's own README
under [`infra/terraform/modules`](infra/terraform/modules).

Everything past v1 (private networking, observability, multi-tenancy
thickening, OBO, the Python variant, Foundry integration) is out of scope for
this repo's current milestone; see
[docs/specs/v1-tracer-bullet.md, Out of Scope](docs/specs/v1-tracer-bullet.md#out-of-scope).

## Quickstart (reading the compositions, not deploying them)

Nothing in this repo is deployed by cloning it. To actually run a live
apply-call-destroy pass:

1. Complete [`docs/runbooks/entra-app-registrations.md`](docs/runbooks/entra-app-registrations.md)
   once (out-of-band Entra app registrations; not automated, needs
   directory-write privilege the CI principal does not hold).
2. Configure the `live-test` GitHub Environment's variables and secrets that
   `.github/workflows/ephemeral-env.yml` reads (state backend location, the
   two compositions' `tfvars.json` secrets built from step 1's values).
3. Run the workflow manually from the Actions tab, typing `apply` into the
   cost-confirmation input.

See [`docs/runbooks/live-test-gate.md`](docs/runbooks/live-test-gate.md) for
the deploying principal's role-assignment prerequisites.

## Cost to run this demo (estimate, not measured)

Public list prices, single unit, before regional variation; basis and date
carried from [docs/blueprint.md](docs/blueprint.md#7-cost-model-all-figures-are-estimates)
(checked 2026-07-08 against the Azure pricing page and third-party trackers;
not re-measured since). Verify with the Azure pricing calculator before
quoting these figures anywhere else.

| Component | Estimated cost |
|---|---|
| APIM Basic v2 (S2, public-demo profile) | ~150 USD/month/unit (includes ~10M requests) |
| Azure Functions Flex Consumption (S1) | under 5 USD/month at demo traffic (pay per execution and GB-s) |
| API Center | free tier exists at the tracer's scale; verify tier mapping at build time |

The tracer is ephemeral by design (apply -> call -> destroy in the gated
live-test run only); nothing here runs continuously, so these are per-run
figures, not a standing monthly bill.
