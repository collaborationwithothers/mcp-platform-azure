# Spec: v1 tracer bullet (S1 + S2 + S3)

Status: ready-for-agent (spec only; tickets created separately)
Date: 2026-07-11
Scope: v1 only (S1, S2, S3). Gated and later-phase scenarios are out of scope.
Source: grill-with-docs session over docs/blueprint.md, verified against Microsoft
Learn and the Terraform registry on 2026-07-11.
Revision 2, 2026-07-11: review changes applied (shadow key auth path closed and
tested; AVM verification anchored to issue starts with pre-declared fallback;
registry endpoint read-access mode decision added; Inspector drift tracking moved
to COMPATIBILITY.md instead of new automation).

This spec describes the first vertical slice of the platform: a single tool call
that travels the full governed path (MCP client -> APIM MCP gateway -> Functions
MCP server -> synthetic tool result) and is discoverable through the API Center
registry, provisioned end to end by Terraform and proven by a live
apply-call-destroy gate. It is a tracer bullet: thin implementation behind
production-shaped interfaces, built to retire preview-surface risk early.

## Problem Statement

A platform engineer standing up "MCP servers as a governed service" on Azure has
no reference showing the risky, newest-surface parts working together end to end.
The pieces that carry the most uncertainty are all at the seams: Entra built-in
auth (Easy Auth) on a Functions-hosted MCP server, the APIM MCP server resource
(GA feature exposed only through a preview ARM API version, with no native
azurerm resource), and API Center registration and discovery. Existing public
samples are azd/Bicep, mostly Python, mostly public-endpoint, and demonstrate one
scenario at a time. None show a Terraform-first, .NET-first, multi-tenant-capable
platform proving these seams in one reproducible slice. Until those seams are
proven together, every downstream design decision (multi-tenancy, OBO, private
networking, observability) rests on unverified assumptions.

## Solution

Build the narrowest end-to-end path through all four v1 Terraform modules and
prove it with a real MCP client and a live deployment:

- A .NET isolated-worker Functions MCP server on Flex Consumption exposes one
  synthetic tool, get_order_status, secured by Entra built-in auth.
- An APIM instance (Basic v2, public-demo profile) fronts the server as a
  passthrough ("existing MCP server") MCP server, validates the Entra token, and
  owns the OAuth 2.1 challenge (401 plus protected resource metadata).
- API Center registers the server (via APIM auto-sync) and exposes it on the
  data-plane MCP registry endpoint for discovery.
- Terraform provisions all of it from module wrappers over Azure Verified
  Modules (for the azurerm surface) and azapi (for the APIM MCP server and API
  Center surface), with durable remote state and per-composition isolation.
- A two-part test harness proves the slice: a hand-written .NET MCP client
  asserts the MCP session and tool contracts; raw HTTP assertions cover the
  discovery artifacts. A live apply-call-destroy run in the gated live-test
  environment is the slice's acceptance gate.

The tracer establishes the thick interface contracts that later thickening PRs
(OBO, multi-tenant products and quotas, content safety, private networking,
observability) extend without restructuring.

## User Stories

1. As a platform engineer evaluating this reference, I want one tool call to
   travel the full governed path in a single deploy, so that I can see the whole
   architecture working rather than isolated modules.
2. As a platform engineer, I want the APIM MCP server modelled as Terraform via
   azapi against a pinned preview ARM API version, so that I can adopt a GA
   feature that the azurerm provider does not yet model.
3. As a platform engineer, I want the Functions MCP server secured by Entra
   built-in auth, so that no tool is reachable without a valid Entra token.
4. As an MCP client, I want a 401 with a WWW-Authenticate header pointing at
   protected resource metadata when I call without a token, so that I can
   discover how to authenticate per the MCP authorization spec.
5. As an MCP client, I want the protected resource metadata served at the gateway
   root well-known path, so that my host resolves it against the root host as
   current clients require.
6. As an MCP client, I want to complete an OAuth 2.1 flow against Entra and call
   the tool with a bearer token whose audience is the server app, so that I reach
   the tool through the gateway securely.
7. As a platform operator, I want the gateway to validate the Entra token
   (issuer, audience, allowed client application id) before forwarding, so that
   invalid callers are rejected at the chokepoint.
8. As a platform operator, I want the Functions server to independently re-check
   the token audience, so that a caller who bypasses the gateway and reaches the
   still-public backend directly is at least rejected unless authenticated.
9. As an MCP client, I want to list tools and see get_order_status with a typed
   schema, so that I know how to call it.
10. As an MCP client, I want get_order_status for a known id (CONTOSO-1001 to
    CONTOSO-1005) to return a typed order status from synthetic data, so that I
    can exercise the success contract.
11. As an MCP client, I want get_order_status for an unknown id to return a typed
    not-found result, so that I can exercise the failure contract deterministically.
12. As a user reading tool output, I want the tool description to state the data
    is synthetic, so that I never mistake demo data for real data.
13. As a developer, I want the server to call nothing downstream in the tracer, so
    that the repo never ships the token-passthrough anti-pattern, even in embryonic
    form.
14. As a platform stakeholder, I want the server discoverable through the API
    Center data-plane MCP registry endpoint, so that clients find approved servers
    through the registry rather than direct URLs.
15. As a platform operator, I want API Center kept current by APIM auto-sync, so
    that the inventory maintains itself the way a production registry would.
16. As a CI gate, I want to poll the registry endpoint with a bounded timeout and
    assert the server appears, so that the asynchronous sync can be verified inside
    a short-lived deployment.
17. As a platform engineer, I want every Azure resource provisioned by Terraform
    modules that wrap Azure Verified Modules where azurerm applies, so that the
    repo demonstrates current ecosystem practice while keeping a stable local
    interface.
18. As a platform engineer, I want the APIM MCP server and API Center provisioned
    by azapi against pinned ARM API versions, so that preview surfaces are explicit
    and tracked.
19. As a platform engineer, I want durable remote Terraform state with
    per-composition state keys and OIDC-only auth, so that state is reproducible
    and no secret is committed.
20. As a platform operator, I want deployment gated so that apply and destroy run
    only in the live-test environment, so that the hard safety rules hold.
21. As a reviewer, I want each module to land with its own docs and static
    validation, so that no code-only PR reaches main and each review stays
    tractable.
22. As a QA engineer, I want a hand-written .NET MCP client that drives a real MCP
    session against the deployed gateway endpoint, so that discovery and tool
    contracts are validated by a real client, not just curl.
23. As a QA engineer, I want the CI gate to acquire its token non-interactively
    via client credentials on a dedicated test app registration, so that the gate
    runs unattended without an interactive OAuth redirect.
24. As a QA engineer, I want raw HTTP assertions for the 401, WWW-Authenticate
    shape, protected resource metadata content, and wrong-audience rejection, so
    that discovery artifacts are measured, not narrated.
25. As a platform engineer running the demo, I want interactive discovery
    validated manually in VS Code and recorded in the demo script, so that the
    human path is shown even though the gate does not automate it.
26. As a platform operator, I want the whole slice to apply, be called, and be
    destroyed in one gated run, so that the slice is ephemeral by design and leaves
    nothing running.
27. As a maintainer, I want every azapi pin recorded in COMPATIBILITY.md in the
    same PR, so that preview exposure is tracked with last-verified dates.
28. As a maintainer, I want the MCP Inspector version pinned to a current release,
    verified once against the deployed tracer, and recorded in COMPATIBILITY.md
    with its last-verified date, so that a stale tool version is visible and
    re-checkable without introducing new automation in this slice.
29. As a hiring reviewer, I want the reasoning for building a tracer through the
    preview surfaces first captured as a decision record, so that the trade-off is
    visible, not just the code.
30. As a platform engineer planning the next step, I want OBO scoped as the very
    next issue with a blocking edge on the tracer and a v1 label, so that "first
    thickening" cannot silently drift past the v1 line.
31. As a platform operator, I want the Functions MCP extension system key
    (mcp_extension) closed as an access path and a negative test proving that a
    request presenting only that key and no Entra token is rejected with 401, so
    that no shadow auth path exists beside Entra (the blueprint's shadow-auth
    failure mode).

## Implementation Decisions

### Delivery shape

- The tracer is a vertical thin-slice, not a horizontal module library. v1 module
  scope is exactly four modules: mcp-function-host, apim-gateway, apim-mcp-server,
  api-center-registry. The private-network and observability modules are out of v1.
- Thin implementation, thick interface. Each module input and output contract is
  designed for its full (thickened) version so that later PRs extend behaviour
  without restructuring the interface the scenario compositions depend on.
- The slice is an epic of five sequential issues; the live end-to-end gate is the
  acceptance criterion of the final integration issue only. Module issues gate on
  static validation, unit tests, and docs.
  1. mcp-function-host module plus docs.
  2. McpTools server (get_order_status) and McpTestClient skeleton plus unit tests.
  3. apim-gateway and apim-mcp-server (passthrough, root PRM, policy) plus docs.
  4. api-center-registry (auto-sync plus bounded-poll assertion) plus docs.
  5. Integration: s1 and s2 compositions, live apply-call-destroy gate, discovery
     assertions, demo script.
- OBO is v1 scope, deferred within v1. It opens as the next issue the moment issue
  5 closes, with a blocking edge on the tracer and a v1 label.

### Terraform and state

- Providers pinned: required_version >= 1.15.8, < 2.0.0; azurerm ~> 4.80; azapi
  ~> 2.10. A .terraform.lock.hcl is committed per scenario composition.
- Remote state on an azurerm backend. Auth is OIDC with use_azuread_auth; no
  storage access keys, no client secrets, no subscription or tenant ids committed.
  Locking uses the native blob lease. The state storage account is bootstrapped
  out of band in a resource group separate from any scenario, so the ephemeral
  expiry-tag cleanup can never delete the backend.
- State isolation is key-per-composition (for example a distinct state key per
  scenario and profile). Terraform workspaces are not used for isolation.
- PR CI continues to run init with -backend=false; only the gated live-test
  workflow touches real state.
- The two azurerm-surface modules (mcp-function-host, apim-gateway) are local
  wrapper modules over Azure Verified Modules. The wrapper is the stable thick
  interface; the AVM module is a swappable implementation detail. AVM modules are
  pinned exactly (pre-1.0 minors are breaking): avm-res-web-site 0.22.0 and
  avm-res-apimanagement-service 0.9.0 at the time of writing.
- AVM risk is retired at the top of each issue, not mid-build. Issue 1 opens by
  verifying that avm-res-web-site 0.22.0 expresses Flex Consumption
  (function_app_uses_fc1) plus Entra built-in auth (auth_settings_v2) as
  documented. Issue 3 opens by verifying that avm-res-apimanagement-service 0.9.0
  can express the Basic v2 SKU. Each check has a pre-declared outcome on failure:
  the wrapper uses raw azurerm for that resource, documented in a paragraph in the
  module doc; no ADR, no schedule slip. These two pre-approved fallbacks are exempt
  from the ADR-moment rule below because the decision is being made here.
- General fallback policy when AVM cannot express something the slice needs: the
  wrapper supplements with a raw azurerm or azapi resource alongside the AVM call,
  so the fallback never ripples into the compositions. Outside the two pre-declared
  checks above, dropping AVM from a whole module is a documented ADR moment, not a
  default reflex.
- The two preview-surface modules (apim-mcp-server, api-center-registry) are
  hand-authored azapi. Confirmed on 2026-07-11 that the azurerm provider still has
  no native APIM MCP resource.

### Compute and the tool (S1)

- Hosting is the Azure Functions MCP extension on Flex Consumption, .NET isolated
  worker (per ADR-002). The AVM web-site module exposes function_app_uses_fc1 for
  Flex Consumption and auth_settings_v2 for Entra built-in auth, so the wrapper can
  express both.
- One synthetic tool in the tracer: get_order_status. The contract is frozen at
  v1; only its implementation may change later (the OBO PR reimplements it to fetch
  from a synthetic downstream on behalf of the user, without changing the contract).
- The tool is self-contained: it serves from a fixed in-memory fixture with ids
  CONTOSO-1001 to CONTOSO-1005, calls nothing downstream, and its description marks
  the data synthetic. Shipping a downstream call with a TODO is forbidden; downstream
  calls arrive only with the OBO issue.
- The MCP extension's key-based access path is closed. Built-in auth requires
  authentication on the MCP endpoint with no excluded paths, and the extension
  system key (mcp_extension) is not a supported access path; the mcp-function-host
  module encodes whatever combination of settings achieves this on the current
  extension version. The enforced truth is behavioural, not configurational: the
  negative test in the live gate (system key present, no Entra token, expect 401)
  is what proves the shadow path is closed.
- Tool contract (decision shape; the not-found path is a typed result, not an
  unhandled error):

  ```
  get_order_status(orderId: string)
    -> { orderId: string, status: string, updatedUtc: string }   // known id
    -> { orderId: string, found: false, message: string }        // unknown id
  ```

### Gateway and authorization (S2)

- APIM tier is Basic v2 in the public-demo profile. Confirmed on 2026-07-11 that
  Basic v2 supports MCP servers.
- The Functions server is exposed as a passthrough ("existing MCP server") MCP
  server. For a passthrough server the external backend owns the tool surface, so
  the tracer does not manage tool child resources in APIM. The azapi resource is
  Microsoft.ApiManagement/service/apis at API version 2025-09-01-preview with
  properties.type = mcp, serviceUrl set to the Functions endpoint, and
  mcpProperties.transportType = streamable with a single endpoint
  { name = message, uriTemplate = /mcp }.
- subscriptionRequired is false in the tracer. There are no products or
  subscriptions. Metering, quotas, and the 429 demo arrive in the S2 thickening,
  and that diff must show product association as additive config, not restructuring.
- Inbound auth at the gateway uses validate-azure-ad-token (issuer, audience equal
  to the server app id URI, and an allowed client-application-ids list). The gateway
  owns the 401 plus WWW-Authenticate plus protected resource metadata challenge,
  following the remote-mcp-apim-oauth-prm pattern. The protected resource metadata
  document is served at the gateway root well-known path
  /.well-known/oauth-protected-resource, not under the API subpath.
- The Functions built-in auth performs a second, independent audience check
  (defense in depth). In v0, with the Functions endpoint still public, this second
  check is also the compensating control against a direct-to-backend bypass; it
  reframes to plain belt-and-braces once v1.1 private networking closes the public
  endpoint. security.md must state honestly that in public-demo the governance
  controls (rate, quota, content safety) are bypassable by going direct to the
  backend until v1.1; Easy Auth only guarantees the bypasser is still authenticated.
- APIM forwarding the Authorization header to the Functions backend is legitimate
  (the token audience is the server app). This is not the token-passthrough
  anti-pattern; the anti-pattern is downstream reuse, addressed by the OBO issue.

### Registry (S3)

- API Center is populated by APIM auto-sync as the production-correct architecture.
  The server is discoverable on the data-plane MCP registry endpoint of the form
  https://<api-center-name>.data.<region>.azure-apicenter.ms/workspaces/default/v0.1/servers.
- To make the asynchronous sync verifiable inside a short-lived deployment, the gate
  polls the registry endpoint with a bounded timeout and asserts the server appears.
- Issue 4 determines and configures the registry endpoint's read access mode before
  wiring the poll. Research indicates the data-plane endpoint returns 401/404 unless
  the workspaces/default path segment is used and read access is configured to allow
  the caller (anonymous read was the working mode at research time). The poll
  authenticates, or not, to match the configured mode, and the chosen mode plus its
  security implication for a public registry endpoint is documented in the module
  doc.
- Explicit azapi registration is retained only as a labelled demo-determinism
  fallback if the bounded poll proves too flaky, never as the headline. If used, docs
  name auto-sync as the production target and explicit registration as the compromise.

### Identity provisioning

- Entra app registrations are long-lived and provisioned out of band, then
  referenced by client id as Terraform variables. At least two exist: the server
  resource app (app id URI, user_impersonation scope, an app role for the test
  client) and a dedicated test client app used with client credentials. App
  registrations live outside the ephemeral resource group so the cleanup sweep never
  deletes them. Rationale: creating app registrations and granting admin consent
  needs directory-write privilege that the ephemeral CI principal should not hold,
  and pre-registration is the blueprint's stated model (no Dynamic Client
  Registration).

### Verification and compatibility

- Every azapi pin adds a row to COMPATIBILITY.md in the same PR. Items to re-verify
  at build or pin time and record: the API Center ARM API version (was
  2024-06-01-preview at research time), the two issue-anchored AVM checks
  (avm-res-web-site: Flex Consumption plus auth_settings_v2, at issue 1 start;
  avm-res-apimanagement-service: Basic v2 SKU, at issue 3 start), the current MCP
  Inspector version, and continued stability of the 2025-09-01-preview APIM ARM
  API.
- The tracer-bullet reasoning ("why we built a tracer through the preview surfaces
  first") is recorded in ADR-001 or a docs/tradeoffs.md entry when the slice lands.

## Testing Decisions

A good test asserts external behaviour at the highest available seam and does not
couple to implementation detail. The tracer uses one behavioural seam plus a unit
seam and the existing static Terraform seam. No new seams are invented.

- Primary behavioural seam: the deployed APIM MCP endpoint. A hand-written .NET MCP
  client (McpTestClient, using the official ModelContextProtocol C# SDK) drives a
  real MCP session against the gateway endpoint and asserts the session and tool
  contracts: initialize succeeds, tools/list contains get_order_status, a known id
  returns a typed status, an unknown id returns the typed not-found result. The gate
  acquires its token non-interactively via client credentials on the dedicated test
  app registration; the SDK's interactive auth-code flow cannot run in CI.
- Discovery-artifact assertions at the same host, raw (PowerShell and curl): a
  no-token call returns 401 with a WWW-Authenticate header whose resource_metadata
  points at the root protected resource metadata URL; the protected resource metadata
  document content is correct; a wrong-audience token is rejected; a request
  presenting only the mcp_extension system key and no Entra token is rejected with
  401 (shadow auth path closed, run against the backend host as well as the
  gateway); and the API Center registry endpoint lists the server within the
  bounded poll. Raw HTTP is used
  because a client library hides the challenge being asserted.
- The gate must state its split explicitly and not overclaim: it validates
  non-interactive session and discovery artifacts, but it does not automatically
  exercise client-driven interactive discovery. Interactive discovery is validated
  manually in VS Code and recorded in the demo script.
- Unit seam: the tool logic (get_order_status success and not-found) is tested in
  process with no Azure dependency, as part of the McpTools issue. This is the .NET
  build-plus-test job that CLAUDE.md already defines as a required check.
- Static seam: each module gates on terraform fmt, per-directory init with
  -backend=false plus validate, tflint with the root config, and checkov, as the CI
  already defines. Module issues rely on this seam plus unit tests plus docs; they do
  not run the live gate.
- The live apply-call-destroy run in the gated live-test environment is the
  acceptance gate of the integration issue. It is documented as cost-gated and runs
  in the live-test environment only, never in PR CI.
- Prior art: the CI jobs terraform-checks and dotnet-build already exist as the
  static and unit seams. The behavioural seam and the live gate are new to this
  slice; the remote-mcp-apim-oauth-prm sample and the Azure-Samples AI-Gateway MCP
  labs are reference implementations for the PRM and client-authorization assertions.

## Out of Scope

- OBO and the downstream call. This is v1 scope but a separate issue with a blocking
  edge on the tracer; the tracer's tool calls nothing downstream.
- Multi-tenancy: products, subscriptions, per-tenant rate limits and quotas, and the
  429 demo (S2 thickening).
- Content safety policy on tool-call arguments (S2 thickening).
- REST-to-MCP export path and external MCP proxy path (S6, post-v1).
- The private-network module and the private profile (v1.1).
- The observability module: Log Analytics workbook, alerts, KQL dashboards (v1.2).
- Any gated or later-phase scenario: Python self-hosted SDK variant, Foundry agent,
  Container Apps private ingress, eval harness, EMA. Never create issues, branches,
  or code for these.
- terraform apply or destroy outside the gated live-test environment.
- Any secret, key, connection string, or tenant or subscription id committed to the
  repo.

## Further Notes

- ADR alignment: this slice implements ADR-001 (gateway-fronted, all traffic
  terminates at APIM), ADR-002 (Functions MCP extension on Flex Consumption),
  ADR-006 (OAuth 2.1 plus protected resource metadata on Entra; OBO not
  token-passthrough, though OBO itself lands in the next issue). ADR-001 or
  docs/tradeoffs.md gains the tracer-bullet reasoning when the slice lands. ADR-005's
  ephemeral apply-demo-destroy posture is honoured by the live gate.
- Honesty rules: all demo data is synthetic and labelled; no benchmark, latency, or
  cost figure is written that was not measured; preview features are pinned and dated
  in COMPATIBILITY.md.
- Doc-verified facts as of 2026-07-11: azurerm 4.80.0 and azapi 2.10.0 are the latest
  provider releases; APIM Basic v2 supports MCP servers; the azurerm provider has no
  native APIM MCP resource so azapi is required; validate-azure-ad-token secures MCP
  inbound access independently of subscription keys; backend protected resource
  metadata is enabled through the WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES app setting;
  the AVM web-site module exposes Flex Consumption and Entra built-in auth.
- Merge governance: everything in this slice touches infra, src, .github, or docs
  beyond formatting, so no PR here is auto-merge eligible. Each opens with a review
  summary and a request for review from Hari, and infra PRs that change deployed
  behaviour also carry the needs-live-test label.