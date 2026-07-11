# Repo: mcp-platform-azure

Blueprint version: 1.0, 2026-07-08. Author: AI Portfolio Architect session with Hari Praghash.
Status: P0. This is the only active repo until v1 is public, documented, and demoable.

NOTE FOR ANY MODEL ITERATING ON THIS DOCUMENT: all Azure service capabilities and status flags below were verified against Microsoft Learn and official blogs on 2026-07-08. Several features are preview and change fast. Before changing any claim about a service capability, SKU, or price, re-verify against current Microsoft documentation. Do not add benchmark numbers, latency figures, or cost figures that were not measured; estimates must be labelled as estimates with their basis. ASCII punctuation only.

## 1. Elevator pitch and who this impresses

An enterprise-grade reference implementation for hosting, governing, and observing Model Context Protocol (MCP) servers on Azure. Terraform-first. It answers the question every platform team is being asked in 2026: "our developers and agents want MCP tools; how do we run them without creating a security and cost mess?"

Who this impresses: hiring managers and principal engineers evaluating AI platform / AI architect candidates. It signals: this person does not just call an LLM API; they can design the identity, networking, gateway, registry, and observability layers that make agent tooling production-safe. Independent scans in late 2025 found roughly a third of production MCP servers had critical security flaws and only single-digit percentages used OAuth; the market problem is governance, not hosting.

Differentiators vs existing public samples (aka.ms/remote-mcp templates, Azure-Samples/AI-Gateway labs): those are azd/Bicep, mostly Python, mostly public-endpoint, one-scenario-at-a-time. This repo is Terraform (with azapi where the provider lags), .NET-first, multi-tenant, private-network capable, and observability-complete.

## 2. Problem statement and core scenario

Problem: enterprises adopting MCP face fragmented authentication, no central inventory of tool servers, no per-team cost or rate controls, and no telemetry on which agents call which tools. Each team hand-rolls a server with an API key and exposes it publicly.

Core scenario: a platform team offers "MCP servers as a governed service". Product teams bring tools (as .NET functions or existing REST APIs); the platform provides: a gateway (Entra-validated, per-tenant rate limits and quotas, content safety), a private registry (discovery for approved servers only), private networking (no public endpoints in the strict variant), and dashboards (who called what, how often, at what cost).

The repo implements that platform end to end with synthetic demo tools, and documents every design decision.

## 3. Architecture goals and non-goals

Goals
- Secure by default: Entra ID everywhere, managed identity between services, no secrets in code, least privilege.
- Governed: every tool call passes through APIM policies; per-tenant limits; central registry as the only discovery path.
- Reproducible: one terraform apply per scenario; ephemeral by design (apply, demo, destroy).
- Observable: every tool call traceable; KQL workbook shipped as code.
- Honest: all demo data synthetic and labelled as such; no fabricated performance claims.

Non-goals
- Not a production SaaS; it is a reference implementation with demo tools.
- Not multi-region or HA-hardened (documented as "what would change for production").
- Not an MCP client or agent framework; clients used are VS Code, MCP Inspector, and (gated phase) a Foundry agent.
- No fine-tuning, no RAG (other repos cover retrieval).

## 4. Architecture

### System context

Actors: MCP clients (VS Code / GitHub Copilot, MCP Inspector, later a Foundry agent), tenant admins (Entra), platform operators (Terraform + GitHub Actions).

Planes:
- Identity plane: Microsoft Entra ID. App registrations for the MCP server (resource) and clients; managed identities for service-to-service; OBO for user-context downstream calls.
- Gateway plane: Azure API Management (AI gateway). Three tool paths through one gateway: (a) REST API exported as MCP server, (b) passthrough to the Functions-hosted MCP server, (c) proxy to an external MCP server.
- Compute plane: Azure Functions (Flex Consumption) hosting a .NET MCP server via the Functions MCP extension. Gated phase adds a Python SDK self-hosted variant and a Container Apps internal-ingress variant for Foundry.
- Registry plane: Azure API Center; APIM auto-sync; data plane MCP registry endpoint for client discovery.
- Observability plane: Application Insights + Log Analytics; APIM diagnostics; Azure Monitor workbook (KQL) shipped in /observability.
- Network plane (private variant): VNet with subnets for APIM outbound integration and Function app; inbound private endpoint on APIM Standard v2; private DNS zones; public network access disabled.

### Mermaid diagram description

Diagram 1 (system context, flowchart LR): MCP Client -> [Entra ID: token acquisition] -> APIM Gateway. APIM -> three backends: Functions MCP server (private endpoint), REST API export (internal), external MCP server (proxied). APIM -> API Center (sync). All components -> App Insights / Log Analytics. Dashed box around VNet contents in the private variant.

Diagram 2 (auth sequence, sequenceDiagram): Client -> MCP server: request without token. Server -> Client: 401 + WWW-Authenticate pointing to protected resource metadata. Client -> /.well-known/oauth-protected-resource. Client -> Entra: OAuth 2.1 + PKCE. Entra -> Client: access token (audience = server app ID URI). Client -> APIM -> Server with bearer token. Server -> Entra: OBO exchange for downstream token. Server -> Downstream API.

Diagram 3 (private network, flowchart TB): client VM or peered network -> private endpoint (APIM gateway) -> APIM Standard v2 (public network access disabled) -> VNet integration subnet -> Function app private endpoint -> Function app (public access disabled). Private DNS zones: privatelink.azure-api.net, privatelink.azurewebsites.net.

### Verified capability notes (2026-07-08)

- Functions MCP extension: announced generally available Nov 2025 (tool triggers; .NET isolated worker, Java, JS, Python, TS; streamable HTTP). Newer primitives vary: resource triggers GA, prompt triggers and MCP Apps and one-click built-in auth are preview-grade. There is conflicting versioning evidence (.NET worker package observed at a -preview version after the GA announcement); re-verify the exact package status at build time and pin versions.
- Self-hosted MCP SDK servers on Functions (custom handlers, stateless, streamable HTTP): public preview.
- APIM MCP: GA. Tiers: classic Developer/Basic/Standard/Premium and Basic v2/Standard v2/Premium v2. Not Consumption, not workspaces. REST-export servers support tools only (no resources or prompts). Policies apply per server, not per tool. Do not read context.Response.Body in MCP policies (breaks streaming). If global App Insights logging is on, set frontend response payload bytes to 0. External passthrough servers must speak MCP spec 2025-06-18 or later.
- APIM v2 networking: Standard v2 and Premium v2 support outbound VNet integration and inbound private endpoints; public network access can be disabled after a private endpoint exists, giving end-to-end isolation on Standard v2. Premium v2 adds full VNet injection. Classic Developer/Premium support injection (Developer has no SLA).
- API Center: data plane MCP registry endpoint GA; APIM MCP server sync supported. No azurerm resource for API Center (provider issue #26200 open since 2024); use azapi.
- APIM MCP server as IaC: no dedicated azurerm resource; model as Microsoft.ApiManagement/service/apis with apiType "mcp" via azapi (API version 2025-09-01-preview at time of writing; the feature is GA but the ARM API version is preview; pin and document).
- Entra: implements the MCP auth pattern via built-in auth on Functions/App Service (401 + protected resource metadata). No Dynamic Client Registration; CIMD support is on Microsoft's roadmap (unverified timing). Clients must be pre-registered.
- Foundry (gated phase): MCP tool connections support key, project managed identity, and OAuth identity passthrough. Functions-hosted servers currently support project managed identity only (not agent identity). Private MCP for Foundry is only tested via Container Apps internal-only ingress on a delegated subnet. Non-streaming MCP tool calls time out at 100 seconds.
- EMA (Enterprise-Managed Authorization) MCP extension: stable 2026-06-18; ID-JAG based; Okta is the first spec-level IdP; VS Code supports Entra/Okta/Auth0 client-side (preview). Native Entra spec-level support unverified. In this repo EMA is an ADR and a parked scenario, not a build item.

## 5. Key design decisions and trade-offs

1. Gateway-fronted, never direct. All client traffic terminates at APIM. Trade-off: added hop and cost vs uniform policy, audit, and the ability to swap backends. Rejected alternative: per-server built-in auth only (no central rate limits, no per-tenant view).
2. Functions MCP extension for the .NET server, not self-hosted SDK mode. Extension is the GA path, supports stateful sessions, and keeps focus on platform not protocol plumbing. Rejected: self-hosted SDK on Functions (preview, stateless only) kept as a gated variant; Container Apps standalone (kept for the Foundry private variant).
3. APIM Standard v2 for the private variant (inbound private endpoint + outbound VNet integration + public access disabled). Rejected: Premium v2 injection (cost, region availability), classic Developer injection (no SLA, slow provisioning, wrong signal for a reference architecture) but documented as the budget option in the cost ADR.
4. Terraform with azurerm as baseline and azapi for MCP-specific resources (APIM MCP servers, API Center). Trade-off: azapi means raw ARM payloads and preview API version pinning; documented openly, with a migration note for when azurerm catches up. This gap is itself portfolio content.
5. Multi-tenancy via APIM products + subscriptions plus Entra app roles, not separate gateways per tenant. Trade-off: shared blast radius vs cost and simplicity; documented threshold at which per-tenant instances win.
6. Token audience validation at both gateway and server (defense in depth); explicit rejection of the token passthrough anti-pattern: the server never forwards the client token downstream, it exchanges via OBO.
7. Registry-as-source-of-truth: clients discover servers via API Center only; direct server URLs are treated as bypass and blocked at the network layer in the private variant.

## 6. Security model

- Identity: Entra app registration per MCP server (resource, with app ID URI and scopes); pre-registered client apps (no DCR); managed identity for APIM to call backends and for the Function app to reach Key Vault/Storage; OBO for user-context downstream calls.
- AuthZ layers: APIM validate-azure-ad-token policy (issuer, audience, optional app role or group claim per tenant) -> Functions built-in auth (second audience check) -> tool-level checks in code where a tool is sensitive.
- Network (private variant): no public endpoints; APIM inbound via private endpoint, outbound via VNet integration; Function app public access disabled with private endpoint; NSGs on both subnets; private DNS zones resolved from a jump/demo VM or peered network.
- Secrets: none in code or tfvars committed; Key Vault + managed identity; the mcp_extension system key disabled in favour of Entra built-in auth (documented explicitly because the default is key-based).
- MCP-specific threats addressed and documented: tool poisoning (registry approval workflow, immutable tool descriptions in code review), confused deputy (audience validation, no shared static client IDs), token passthrough (forbidden, OBO instead), session hijack (sessions never used for authn), prompt injection at tool boundary (APIM content safety policy on tool call arguments, GA capability).
- Compliance-aware logging: request metadata logged, tool arguments logged only when content safety inspection requires, payload logging bounded (and set to 0 at frontend response globally per APIM MCP guidance).

## 7. Cost model (all figures are estimates)

Basis: Azure public list prices as reflected on the Azure pricing page and third-party trackers, checked 2026-07-08, USD, single unit, before regional variation (Hari deploys to UK South; verify with the Azure pricing calculator before publishing any figure in the README).

- APIM Basic v2: est. ~150 USD/month/unit (includes ~10M requests). Public cookbook variant.
- APIM Standard v2: est. ~700 USD/month/unit (includes ~50M requests). Required for the private variant (VNet integration + private endpoint).
- APIM Developer (classic): est. ~50 USD/month, no SLA, supports VNet injection; documented budget alternative for private experimentation only.
- Functions Flex Consumption: pay per execution and GB-s; demo traffic est. under 5 USD/month.
- Log Analytics: per-GB ingestion; demo est. under 10 USD/month with sampling.
- API Center: free tier exists; Standard included with linked APIM Standard/Premium per pricing page; verify tier mapping for v2 at build time.

Cost control design (this is portfolio content, not just budgeting):
- Ephemeral by default: every scenario is apply -> demo -> destroy; CI includes a nightly destroy safety net tagged by expiry.
- deployment_profile Terraform variable: "public-demo" (Basic v2, public endpoints, cheapest) vs "private" (Standard v2, full isolation). Same modules, different composition.
- APIM token metrics and quotas demonstrate per-tenant cost attribution even though demo tools are not LLM-backed; the LLM token budgeting policy is shown against a mock backend to avoid model spend.
- README carries a "cost to run this demo" table labelled as estimates with the date checked.

## 8. Observability model

- APIM diagnostics to Log Analytics: per-operation (per-tool) request logs, subscription (tenant) dimension, backend latency, response codes.
- App Insights on the Function app: distributed tracing with operation IDs correlated to APIM via correlation headers.
- Shipped as code in /observability: an Azure Monitor workbook (JSON, deployed by Terraform) with panels: tool call volume by tenant, top tools, error rate by tool, backend latency distribution, 429s by tenant (quota pressure), auth failures by client app.
- Alert rules as code: sustained 401 spike (possible probing), 429 saturation per tenant, backend 5xx rate.
- Honesty rule: dashboards show live demo data only; screenshots in docs labelled "synthetic demo traffic".

## 9. Failure modes

- APIM policy reads response body -> streaming breaks silently. Mitigation: policy lint checklist in docs; never use context.Response.Body in MCP policies.
- Global payload logging left on -> MCP responses malfunction. Mitigation: Terraform sets frontend response payload bytes to 0.
- Preview churn: Functions MCP extension or the 2025-09-01-preview ARM API changes shape. Mitigation: pinned versions, a COMPATIBILITY.md with last-verified dates, CI plan job that fails loudly on schema drift.
- mcp_extension key left enabled alongside Entra auth -> shadow auth path. Mitigation: module disables key auth explicitly; test asserts 401 on keyed request.
- Private DNS misconfiguration -> clients resolve public IPs and fail opaquely. Mitigation: runbook with nslookup checks; Terraform outputs a verification script.
- Flex Consumption cold start inflates first-call latency in demos. Mitigation: demo script warms the endpoint; no latency claims made anywhere.
- Rate limit policy counts MCP session initialization messages -> false 429s. Mitigation: scope limits to tools/call where policy expressions allow; document the limitation if not.
- Foundry 100 second timeout on non-streaming tool calls (gated phase). Mitigation: demo tools respond fast; documented constraint.

## 10. Testing and eval strategy

- Static: terraform fmt/validate, tflint, checkov (or trivy config) in CI on every PR; .NET build + unit tests for tool logic.
- Integration (scripted, PowerShell + a .NET MCP test client or MCP Inspector CLI): initialize session, list tools, call one tool, assert schema; negative tests: no token -> 401 with correct WWW-Authenticate; wrong audience -> 401; tenant B exceeding quota -> 429; keyed request -> 401.
- Policy tests: APIM policy fragments applied to a mock backend; assertions on injected headers and rejections.
- Ephemeral environment workflow: GitHub Actions job that applies the public-demo profile to a sandbox subscription, runs integration tests, destroys. Documented as optional due to cost; can run manually.
- Evals (gated): once the Foundry agent scenario lands, a small golden set of agent tasks asserting correct tool selection and argument construction; regression gate in CI. Do not build before the evals skill item is in progress.

## 11. Buildable today (capability gating)

Now (current strengths: Terraform, Bicep, APIM, networking, Entra, .NET, PowerShell, Azure DevOps/GitHub Actions):
- All Terraform/azapi modules and compositions (S3, S4 infra).
- .NET Functions MCP server with Entra built-in auth and OBO (S1).
- APIM gateway, policies, products/subscriptions, multi-tenant limits, token metrics, content safety policy (S2).
- REST-to-MCP export scenario (S6).
- KQL workbook, alerts, runbooks (S5).
- API Center registry wiring via azapi (part of S3/S4).
- CI pipelines, integration test scripts in PowerShell/.NET.

Gated (mapped to skill-matrix items):
- Python self-hosted MCP SDK server variant -> skill: hands-on Python.
- Foundry agent consuming the platform, Container Apps private variant driven end to end -> skill: agents.
- Eval harness and regression gates -> skill: AI evaluation.
- EMA (ID-JAG) implementation -> gated on ecosystem, not skills: requires spec-level IdP support (Okta today; Entra unverified). Parked; ADR-006 documents it now.

v1 scope = S1 + S2 + S3 + docs + demo. Estimated Now share of v1: ~90 percent (estimate, basis: task list above; the only non-Now item in v1 is none; gated items are all post-v1). Passes the 70 percent P0 bar.

## 12. Repository structure

```
mcp-platform-azure/
  README.md
  COMPATIBILITY.md            # last-verified dates for preview features
  docs/
    architecture.md           # diagrams + narrative (mermaid)
    decisions/                # ADRs, see list below
    tradeoffs.md
    security.md               # threat model incl MCP-specific threats
    cost.md                   # estimates, labelled, dated
    observability.md
    runbooks/                 # private DNS verification, key rotation, teardown
    demos/                    # demo scripts and recordings index
  infra/terraform/
    modules/
      mcp-function-host/      # Flex Consumption, VNet, built-in auth (azurerm)
      apim-gateway/           # APIM instance + policies (azurerm)
      apim-mcp-server/        # apiType=mcp via azapi (the signature module)
      api-center-registry/    # azapi
      private-network/        # vnet, subnets, PEs, private DNS
      observability/          # LA workspace, workbook, alerts
    scenarios/
      s1-entra-mcp-server/
      s2-apim-mcp-gateway/
      s4-private-platform/
      s6-rest-to-mcp/
  src/
    McpTools/                 # .NET isolated worker, MCP tool triggers
    McpTestClient/            # .NET integration test client
  tests/
  evals/                      # empty placeholder + README until gated phase
  scripts/                    # PowerShell: demo, verify-dns, warm, teardown
  .github/workflows/          # ci.yml (fmt/validate/lint/scan/build/test), ephemeral-env.yml
```

## 13. Implementation phases

Phase 0 (skeleton, days): repo, README stub, ADR stubs, CI with terraform fmt/validate + tflint + checkov + dotnet build. Public from day one.
Phase 1 (v1): S3 modules -> S1 server -> S2 gateway (public-demo profile) -> integration tests -> docs (README, ADR-001/002/006, security.md core) -> demo script + short recording. v1 tag when all are public and the demo runs clean from a fresh clone.
Phase 2 (v1.1): S4 private platform + runbooks + ADR-003. Phase 3 (v1.2): S5 observability workbook + alerts + ADR-004, S6 REST export, ADR-005.
Phase 4 (gated): Python variant, Foundry agent + Container Apps private ingress, evals, EMA when unblocked.

Document-first rule: each scenario lands with its docs in the same PR; no code-only merges to main.

ADR list: ADR-001 gateway-fronted platform architecture (vs direct exposure); ADR-002 MCP server hosting selection (Functions extension vs SDK self-host vs Container Apps); ADR-003 private networking tier choice (Standard v2 PE+integration vs Premium v2 injection vs Developer classic); ADR-004 observability design; ADR-005 cost control and multi-tenant limits; ADR-006 authorization model: OAuth 2.1 + PRM on Entra today, EMA/ID-JAG posture and adoption trigger.

## 14. README outline

1. What this is (one paragraph) and what problem it solves.
2. Why it is architecturally significant (governance gap, security stats with citations).
3. Architecture diagram + planes.
4. Scenario index (table: scenario, what it proves, cost estimate to run, status).
5. Quickstart (public-demo profile): prerequisites, terraform apply, connect VS Code, call a tool.
6. Security model summary, link to threat model.
7. Observability: workbook screenshot (labelled synthetic).
8. Cost to run (estimates, dated).
9. Failure behaviour and known limitations (incl preview flags).
10. Testing.
11. What would change for production.
12. Honesty note: all metrics on synthetic demo traffic; preview features pinned; last verified date.

## 15. Demo script (target: under 10 minutes)

1. terraform apply scenarios/s2-apim-mcp-gateway (public-demo profile). Show outputs: gateway MCP endpoint, registry endpoint.
2. VS Code: add MCP server via the APIM endpoint; Entra sign-in flow; list tools.
3. Call a tool; show the result.
4. curl without a token: 401 with WWW-Authenticate and PRM URL; curl with the disabled function key: 401.
5. Loop 20 calls on tenant B subscription: 429 with rate limit headers.
6. Portal or workbook: tool call volume by tenant, the 429s just generated.
7. API Center: show the registered server in the registry endpoint.
8. terraform destroy. State the monthly cost estimate if left running.

## 16. Interview talking points

- Why MCP needs a gateway: the authorization spec secures the connection; it does nothing about rate, cost, tenancy, or tool-call content. EMA vs gateway responsibilities (ADR-006).
- Why token passthrough is forbidden and how OBO fixes it; audience validation at two layers.
- The azurerm gap and how azapi bridges GA features exposed only via preview ARM API versions; what that implies for platform teams adopting bleeding-edge Azure.
- Standard v2 end-to-end isolation pattern (PE inbound + VNet integration outbound + public access off) vs Premium v2 injection: when each wins.
- Multi-tenant limits with products/subscriptions and where that model breaks.
- The three MCP tool paths through one gateway and why REST export accelerates enterprises with legacy APIs.
- Preview risk management as an engineering discipline (COMPATIBILITY.md, pinning, drift-detecting CI).

## 17. Where this fails

Key assumptions:
- The Functions MCP extension GA status and the preview ARM API versions remain stable enough that pinning holds for months. If Microsoft breaks the 2025-09-01-preview APIM schema, the signature azapi module needs rework.
- APIM Standard v2 remains the cheapest end-to-end-private path; if Premium v2 pricing or region coverage shifts, ADR-003 needs revisiting.
- Hiring panels value governance-layer work. If a target role is model-centric (RAG, evals, fine-tuning), this repo shows platform skill but not model skill; the gated phases and the other planned repos cover that, and this must not become an excuse to defer them.

Failure modes of the plan:
- Scope creep: six cookbook scenarios plus gated phases is a lot. The cut line if shipping slips: v1 = S1 + S2 + S3 only. Anything less than a tagged, documented v1 within a bounded period means the repo is failing its purpose.
- Preview churn invalidating docs faster than they are maintained; a stale public repo about fast-moving services damages credibility. Mitigation is COMPATIBILITY.md plus a visible last-verified badge, but the honest answer is this repo carries ongoing maintenance cost.
- Demo friction: Entra client pre-registration (no DCR) makes the quickstart heavier than samples that use keys. If early users bounce off the auth setup, add a keyed "insecure-demo" toggle that is loudly labelled.

Strongest counterargument: Microsoft's own samples and labs will keep absorbing these scenarios; in 12 months an official Terraform module set for MCP could make this repo redundant. Response: the window is now, the multi-tenant + private + observability combination is not covered today, and the ADRs (the reasoning) retain value even after the code is commoditized. Ship fast or do not bother.