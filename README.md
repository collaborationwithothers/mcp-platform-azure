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
[docs/blueprint.md](docs/blueprint.md); the v1 slice, shipped and tagged
v1.0.0 (2026-07-22, ephemeral live gate green):
[docs/specs/v1-tracer-bullet.md](docs/specs/v1-tracer-bullet.md).

## Architecture at a glance

![v1 architecture: an MCP client calls Azure API Management (the MCP gateway),
which forwards validated requests to the Functions-hosted MCP server; the server
calls a downstream Orders API. Microsoft Entra ID issues tokens, API Center holds
the inventory, and storage backs deployment. Public-demo profile.](docs/diagrams/v1-architecture.drawio.svg)

The topology deployed at tag v1.0.0, public-demo profile (public endpoints only).
Private networking is deferred to v1.1 (ADR-003) and is deliberately absent here
because it is not deployed. The identity flows (app-only and delegated OBO) and
the per-request outcome model (HTTP status vs MCP tool errors) are in ADR-006.

### Phase 3.5 thickening: multi-server composition (issue #17)

![Multi-server composition: two MCP server APIs (/orders and /catalog) behind one
API Management gateway. Each server has its own RFC 9728 path-inserted
protected-resource-metadata document, its own per-server 401 challenge that leads
to its own metadata, and its own scope-or-role entitlement check that returns 403
insufficient_scope otherwise. A retained root PRM document is the s3.3 fail-closed
guard. A shared Microsoft Entra ID registration carries a per-server scope and
role, and both servers forward to one shared backend Function App.](docs/diagrams/multi-server-composition.drawio.svg)

A post-v1.0.0 thickening ([docs/specs/thickening.md](docs/specs/thickening.md)):
a second passthrough MCP server behind the same gateway, proving per-server
discovery and per-server entitlement (a token entitled to one server is rejected
at the other with 403 insufficient_scope). This extends the v1.0.0 topology
above; it is not part of the v1.0.0 tag.

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

Private networking, full application observability, multi-tenancy thickening,
the Python variant, and Foundry integration remain out of scope for this repo's
current milestone; see
[docs/specs/v1-tracer-bullet.md, Out of Scope](docs/specs/v1-tracer-bullet.md#out-of-scope).

### Resource-level platform diagnostics (issue 75)

S1 and S2 route selected Azure Monitor resource logs and exportable platform
metrics to the Log Analytics workspace behind one durable, workspace-based
Application Insights resource. The resource-level configuration covers 16
supported targets: 14 Function-host targets, the APIM service, and the Event
Hubs namespace. It discovers each target's categories at apply time. API Center
remains the APIM-linked registry, but Azure Monitor diagnostic settings are
unsupported there, as gated run 31162622718 proved. The shared
input is `shared_observability_application_insights_id`, supplied only as the
`live-test` Environment variable
`TF_VAR_shared_observability_application_insights_id`.

This does not make observability complete. It does not add request and
dependency correlation, workbooks, or alerts. Issue 18's separate per-tool deny
audit path is unchanged. See [the observability guide](docs/observability.md),
[ADR-004](docs/decisions/ADR-004:%20Observability%20design.md), and [the
bootstrap runbook](docs/runbooks/observability-bootstrap.md).

## Quickstart (reading the compositions, not deploying them)

Nothing in this repo is deployed by cloning it. To actually run a live
apply-call-destroy pass:

1. Complete [`docs/runbooks/entra-app-registrations.md`](docs/runbooks/entra-app-registrations.md)
   once (out-of-band Entra app registrations; not automated, needs
   directory-write privilege the CI principal does not hold).
2. Configure the `live-test` GitHub Environment's variables and secrets that
   `.github/workflows/ephemeral-env.yml` reads (state backend location, the
   two compositions' `tfvars.json` secrets built from step 1's values).
3. Complete [the observability bootstrap](docs/runbooks/observability-bootstrap.md)
   and create `TF_VAR_shared_observability_application_insights_id` before the
   first issue 75 live test.
4. Run the workflow manually from the Actions tab, typing `apply` into the
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

Resource-level diagnostic ingestion has no published workload estimate. Measure
billable volume after a representative gated deployment before making a cost
claim. The dated procedure is in [docs/cost.md](docs/cost.md).
