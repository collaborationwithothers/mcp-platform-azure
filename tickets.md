# Tickets: v1 tracer bullet (S1 + S2 + S3)

Six tickets that build the v1 tracer bullet: one governed tool call end to end,
proven by a live apply-call-destroy gate, then the OBO successor. Source of truth
for rationale is docs/specs/v1-tracer-bullet.md; tickets link to its sections and
do not restate rationale.

Delivery shape and blocking edges are the spec's (see spec: Delivery shape). The
chain is linear: 1 -> 2 -> 3 -> 4 -> 5 -> 6(OBO). Work the frontier: the only
startable ticket at any time is the lowest-numbered open one.

Published to collaborationwithothers/mcp-platform-azure on 2026-07-11 (labels
applied except ready-for-agent, which is Hari-only and left for Hari to flip):
Ticket 1 -> #5, Ticket 2 -> #6, Ticket 3 -> #7, Ticket 4 -> #8, Ticket 5 -> #9,
Ticket 6 (OBO) -> #10.

Global rules that bind every ticket (from CLAUDE.md and the spec, not repeated in
each body):
- ASCII punctuation only. Metric units. Docs land in the same PR as the code they
  describe; no code-only PRs.
- No secret, key, connection string, or tenant/subscription id committed.
- No terraform apply or destroy anywhere except the gated live-test environment
  (only ticket 5 applies, and only there).
- Provider pins for any new Terraform: required_version >= 1.15.8, < 2.0.0;
  azurerm ~> 4.80; azapi ~> 2.10 (verified latest 2026-07-11: azurerm 4.80.0,
  azapi 2.10.0). Commit .terraform.lock.hcl per scenario composition.
- Every azapi pin adds a COMPATIBILITY.md row in the same PR with a last-verified
  date and doc link.
- Merge: none of these are auto-merge eligible. Open PR, post review summary
  (what changed, why, Microsoft Learn links justifying any azapi payload / ARM API
  version / APIM policy), request review from Hari, stop. Infra PRs that change
  deployed behaviour also carry needs-live-test.

---

## Ticket 1: mcp-function-host module (Flex Consumption + Entra built-in auth)

**What to build:** A reusable Terraform module that provisions the .NET
isolated-worker Functions host for the MCP server on Flex Consumption, with Entra
built-in auth enabled and the MCP extension key path closed, exposing a thick
interface the later gateway and scenario tickets consume. No deployment; the module
is proven by static validation only.

**Blocked by:** None - can start immediately.

**Files to create:**
- infra/terraform/modules/mcp-function-host/versions.tf (required_version, required_providers)
- infra/terraform/modules/mcp-function-host/variables.tf
- infra/terraform/modules/mcp-function-host/main.tf (wrapper over avm-res-web-site)
- infra/terraform/modules/mcp-function-host/outputs.tf
- infra/terraform/modules/mcp-function-host/README.md (module doc; includes the AVM-check outcome paragraph)

**Files to modify:**
- COMPATIBILITY.md (Pinned versions: add avm-res-web-site 0.22.0 row and the
  issue-1 AVM capability-check result)

**Module interface (thick - design for the full feature set now):**
- Inputs:
  - name_prefix (string), location (string), resource_group_name (string)
  - tags (map(string)) including an expiry tag
  - runtime = { stack = "dotnet-isolated", version } (default dotnet-isolated, .NET 10)
  - flex_consumption = { instance_memory_mb, maximum_instance_count } (sized small)
  - storage_account_name (string) or a create flag
  - entra_auth = { tenant_id, server_app_client_id, allowed_audiences (list, includes the server app id URI), unauthenticated_action = "Return401" }
  - prm_scope (string, e.g. api://<server-app-id>/user_impersonation) surfaced as the WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES app setting
  - app_settings (map(string)) for extension/config additions
- Outputs:
  - function_app_id, function_app_name
  - default_hostname (string)
  - mcp_backend_base_url (string) - the base URL the apim-mcp-server module points serviceUrl at (exact MCP endpoint path is confirmed against the current extension docs in ticket 3, not hard-coded here)
  - identity_principal_id (string) - system-assigned MI, for later RBAC; unused in the tracer but part of the thick interface

**Verified facts this ticket depends on (verify avm-res-web-site at issue start; see spec: Terraform and state, AVM risk retired at the top of each issue):**
- avm-res-web-site 0.22.0 exposes function_app_uses_fc1 (Flex Consumption) and an
  auth_settings_v2 block for Entra built-in auth (Easy Auth). Registry:
  https://registry.terraform.io/modules/Azure/avm-res-web-site/azurerm/0.22.0
  Issue-start check: confirm both are expressible on 0.22.0. Pre-declared fallback
  (spec-approved, no ADR): if either is not expressible, the wrapper uses a raw
  azurerm resource for that piece and documents it in a paragraph in README.md.
- Backend protected resource metadata is enabled by the app setting
  WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES = api://<app-id>/user_impersonation:
  https://learn.microsoft.com/azure/app-service/configure-authentication-mcp-server-vscode
- The MCP extension system key (mcp_extension) must not be a live access path;
  built-in auth requires authentication on the MCP endpoint with no excluded
  paths. The enforced proof is the ticket-5 negative test, not config here
  (see spec: Compute and the tool (S1)).

**Acceptance criteria:**
- [ ] Module wraps avm-res-web-site 0.22.0 (pinned exactly) for a Flex Consumption, dotnet-isolated function app.
- [ ] Entra built-in auth configured via auth_settings_v2: unauthenticated requests return 401, allowed audiences include the server app id URI, issuer is the configured tenant.
- [ ] WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES app setting is set from prm_scope.
- [ ] Module settings close the mcp_extension key path (no auth-excluded MCP path); a comment references that the behavioural proof is ticket 5's negative test.
- [ ] Thick interface implemented exactly as above (all listed inputs and outputs present, even those unused in the tracer).
- [ ] terraform fmt, init -backend=false, validate, tflint (root .tflint.hcl), and checkov all pass for the module directory (CI terraform-checks job goes live for this path).
- [ ] README.md documents the interface, the AVM-check outcome, and the mcp_extension-key posture.
- [ ] COMPATIBILITY.md has the avm-res-web-site 0.22.0 row with last-verified date and the issue-1 check result.

**Out of scope (must NOT do):**
- No terraform apply or destroy; static validation only.
- No APIM, API Center, scenario composition, backend config, or .NET code.
- No app registration creation (they are out-of-band inputs referenced by id).
- No private networking, no observability wiring, no App Insights beyond what the function host strictly requires.

**Spec section:** Compute and the tool (S1); Terraform and state.

---

## Ticket 2: McpTools server (get_order_status) and McpTestClient skeleton

**What to build:** The .NET isolated-worker MCP server exposing the single
synthetic tool get_order_status against a fixed in-memory fixture, plus the
skeleton of the hand-written .NET MCP test client, plus in-process unit tests for
the tool logic. Self-contained: the tool calls nothing downstream.

**Blocked by:** Ticket 1 as process sequencing (one issue at a time, spec delivery
order), not a technical dependency - nothing in this ticket consumes ticket 1's
outputs.

**Files to create:**
- src/McpTools/McpTools.csproj
- src/McpTools/Program.cs (isolated worker host + Functions MCP extension registration)
- src/McpTools/Tools/GetOrderStatus.cs (the tool)
- src/McpTools/Fixtures/SyntheticOrders.cs (CONTOSO-1001..CONTOSO-1005)
- src/McpTestClient/McpTestClient.csproj
- src/McpTestClient/Program.cs (skeleton: connect, initialize, tools/list, call - assertions filled in ticket 5)
- tests/McpTools.Tests/McpTools.Tests.csproj
- tests/McpTools.Tests/GetOrderStatusTests.cs
- README.md updates or src/README.md documenting the two projects (docs land with code)

**Files to modify:**
- A solution file at repo root or src/ (create if none) so dotnet build discovers the projects.

**Tool contract (frozen at v1; only the implementation may change later - from spec, decision shape):**
```
get_order_status(orderId: string)
  -> { orderId: string, status: string, updatedUtc: string }   // known id
  -> { orderId: string, found: false, message: string }        // unknown id
```
- Fixture ids: CONTOSO-1001 to CONTOSO-1005. Tool description states the data is synthetic.

**Verified facts this ticket depends on:**
- Hosting is the Azure Functions MCP extension, .NET isolated worker (ADR-002).
  Verify the current extension package name and version at issue start and pin it;
  record the pin in COMPATIBILITY.md. Overview:
  https://learn.microsoft.com/azure/azure-functions/functions-mcp-tutorial
- The test client uses the official ModelContextProtocol C# SDK. Verify current
  package version at issue start.

**Acceptance criteria:**
- [ ] get_order_status returns the typed success shape for each of CONTOSO-1001..1005 from the in-memory fixture.
- [ ] get_order_status returns the typed not-found shape (found:false) for any other id - a typed result, not a thrown/unhandled error.
- [ ] Tool description string states the data is synthetic.
- [ ] The tool calls nothing downstream: no HTTP client, no outbound call, no TODO referencing a downstream. (Grep-clean of outbound calls.)
- [ ] Unit tests cover the success path (all five ids) and the not-found path; they run in process with no Azure dependency.
- [ ] McpTestClient builds and has a runnable skeleton (connect/initialize/list/call structure) with assertion bodies stubbed for ticket 5.
- [ ] dotnet build and dotnet test pass (CI dotnet-build job goes live for these projects).
- [ ] Functions MCP extension package pin recorded in COMPATIBILITY.md with last-verified date.

**Out of scope (must NOT do):**
- No downstream calls of any kind; no OBO; no token exchange.
- No Azure deployment; no terraform; no APIM or API Center.
- No second tool; get_order_status only.
- No filling in of the live-gate assertions in McpTestClient (that is ticket 5).

**Spec section:** Compute and the tool (S1); Testing Decisions (unit seam).

---

## Ticket 3: apim-gateway and apim-mcp-server modules (passthrough + root PRM)

**What to build:** Two Terraform modules: apim-gateway (AVM wrapper provisioning
the APIM instance at Basic v2) and apim-mcp-server (hand-authored azapi passthrough
MCP server that fronts the Functions backend, validates the Entra token, owns the
401 + WWW-Authenticate + root PRM challenge, and applies the server-scope policy).
Static validation only.

**Blocked by:** Ticket 2.

**Files to create:**
- infra/terraform/modules/apim-gateway/{versions.tf,variables.tf,main.tf,outputs.tf,README.md}
- infra/terraform/modules/apim-mcp-server/{versions.tf,variables.tf,main.tf,outputs.tf,README.md}
- infra/terraform/modules/apim-mcp-server/policies/mcp-server.xml (validate-azure-ad-token + PRM challenge policy)
- infra/terraform/modules/apim-mcp-server/policies/prm-well-known.xml (root well-known PRM document response), if served via an APIM operation/policy

**Files to modify:**
- COMPATIBILITY.md (rows: apim-mcp-server ARM API 2025-09-01-preview; avm-res-apimanagement-service 0.9.0 with the issue-3 Basic v2 check result)

**apim-gateway interface (thick):**
- Inputs: name, location, resource_group_name, tags, sku_name (Basic_v2 for public-demo; driven by deployment_profile at the composition), publisher_name, publisher_email, identity = system-assigned, tenant_id
- Outputs: apim_id, apim_name, gateway_url (https://<name>.azure-api.net), identity_principal_id

**apim-mcp-server interface (thick):**
- Inputs:
  - apim_id (parent APIM id)
  - server_name, server_path
  - backend_service_url (from mcp-function-host output mcp_backend_base_url)
  - transport = { type = "streamable", endpoints = [{ name = "message", uri_template = "/mcp" }] }
  - subscription_required (bool, default false in tracer)
  - entra_validation = { tenant_id, audience (server app id URI), allowed_client_application_ids (list) }
  - prm = { issuer, resource, scopes } for the root PRM document
  - product_ids (list, default []) - additive binding surface, empty in tracer (see spec: subscriptionRequired is false)
- Outputs: mcp_server_api_id, mcp_server_url (https://<gateway>/<path>/mcp), prm_url (root well-known)

**Verified facts this ticket depends on:**
- azapi resource Microsoft.ApiManagement/service/apis at ARM API version
  2025-09-01-preview, properties.type = mcp, serviceUrl = backend, mcpProperties =
  { transportType = "streamable", endpoints = [{ name = "message", uriTemplate =
  "/mcp" }] }; for a passthrough server the backend owns the tool surface, so no
  tools child resources. Confirmed 2026-07-11 the azurerm provider has no native
  MCP resource. Doc:
  https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api
- APIM Basic v2 supports MCP servers. Doc:
  https://learn.microsoft.com/azure/api-management/mcp-server-overview (Availability)
- Inbound Entra auth uses validate-azure-ad-token (issuer, audience, allowed
  client-application-ids). Doc:
  https://learn.microsoft.com/azure/api-management/secure-mcp-servers
- Gateway owns 401 + WWW-Authenticate + PRM, served at the gateway root
  /.well-known/oauth-protected-resource (not under the API subpath); reference
  implementation: https://github.com/blackchoey/remote-mcp-apim-oauth-prm
- Root PRM is a gateway-level singleton: serve the root
  /.well-known/oauth-protected-resource once at the gateway (or plan the RFC 9728
  path-suffixed form) so a second MCP server added to the same gateway later does
  not collide over the root well-known path. Thick-interface consideration; only
  the single tracer server is served now.
- Do not read context.Response.Body in MCP policies (breaks streaming); the
  policy lint follows this. Doc:
  https://learn.microsoft.com/azure/api-management/mcp-server-overview
- avm-res-apimanagement-service 0.9.0 Basic v2 check at issue start. Registry:
  https://registry.terraform.io/modules/Azure/avm-res-apimanagement-service/azurerm/0.9.0
  Pre-declared fallback (spec-approved, no ADR): if 0.9.0 cannot express Basic_v2,
  the wrapper uses a raw azurerm_api_management for the instance and documents it
  in README.md.

**Acceptance criteria:**
- [ ] apim-gateway wraps avm-res-apimanagement-service 0.9.0 (pinned exactly) and provisions a Basic v2 instance with a system-assigned identity; outputs the thick interface above.
- [ ] apim-mcp-server creates the azapi passthrough MCP server at 2025-09-01-preview with type=mcp, serviceUrl=backend, streamable transport, single /mcp endpoint, subscriptionRequired=false, and NO tools child resources.
- [ ] product_ids input exists and is empty in the tracer; binding a product later is additive config that does not restructure the server resource.
- [ ] Server-scope policy applies validate-azure-ad-token (issuer, audience=server app id URI, allowed client-application-ids) and does not read context.Response.Body.
- [ ] The PRM document is served at the gateway root well-known path; prm_url output points at the root, not the API subpath.
- [ ] Root PRM is a gateway-level singleton (or the RFC 9728 path-suffixed form is planned in README) so a future second MCP server does not collide on the root well-known path.
- [ ] terraform fmt/init -backend=false/validate/tflint/checkov pass for both module directories.
- [ ] Each module README.md documents its interface; apim-mcp-server README links the Microsoft Learn ARM/policy docs justifying the azapi payload.
- [ ] COMPATIBILITY.md rows added: apim-mcp-server 2025-09-01-preview; avm-res-apimanagement-service 0.9.0 + issue-3 check result.

**Out of scope (must NOT do):**
- No terraform apply or destroy; static validation only.
- No products, subscriptions, rate-limit or quota policies, content safety, or 429 behaviour (S2 thickening).
- No REST-backed MCP server and no tool child resources (passthrough only).
- No scenario composition wiring or backend config (ticket 5).

**Spec section:** Gateway and authorization (S2); Terraform and state.

---

## Ticket 4: api-center-registry module (auto-sync + registry read access)

**What to build:** A hand-authored azapi Terraform module that provisions API
Center, wires APIM auto-sync so the MCP server appears in the inventory
automatically, configures the data-plane registry endpoint read-access mode, and
exposes the registry endpoint URL for the ticket-5 bounded poll. Static validation
only.

**Blocked by:** Ticket 3.

**Files to create:**
- infra/terraform/modules/api-center-registry/{versions.tf,variables.tf,main.tf,outputs.tf,README.md}

**Files to modify:**
- COMPATIBILITY.md (row: API Center ARM API version, verified at issue start)

**Module interface (thick):**
- Inputs:
  - name, location, resource_group_name, tags
  - apim_source_id (the APIM instance id to auto-sync from)
  - environment = { title, kind } and deployment metadata for the registered server
  - registry_read_access = { mode } - the read-access mode the ticket determines and configures (see spec: Registry (S3))
- Outputs:
  - api_center_name
  - registry_endpoint_url (data-plane, form https://<name>.data.<region>.azure-apicenter.ms/workspaces/default/v0.1/servers)
  - registry_read_access_mode (echoed for the poll to match)

**Verified facts this ticket depends on:**
- API Center maintains an MCP registry; data-plane endpoint form
  https://<name>.data.<region>.azure-apicenter.ms/workspaces/default/v0.1/servers.
  Doc: https://learn.microsoft.com/azure/api-center/register-discover-mcp-server
- Auto-sync from APIM keeps the inventory current (production-correct). Doc:
  https://learn.microsoft.com/azure/api-center/synchronize-api-management-apis
- No azurerm resource for API Center; azapi with a pinned ARM API version
  (2024-06-01-preview at research time - re-verify current version at issue start
  and pin). Record in COMPATIBILITY.md.
- The data-plane endpoint returns 401/404 unless the workspaces/default path
  segment is used and read access allows the caller; determine and configure the
  read-access mode, and document its security implication for a public registry
  endpoint in README.md (see spec: Registry (S3)).

**Acceptance criteria:**
- [ ] Module provisions API Center via azapi at a pinned, issue-start-verified ARM API version.
- [ ] APIM auto-sync configured so the MCP server populates the inventory automatically (production-correct path; explicit azapi registration is NOT the headline).
- [ ] Registry read-access mode determined, configured, and documented in README.md with its security implication for a public endpoint.
- [ ] registry_endpoint_url output uses the workspaces/default/v0.1/servers form; registry_read_access_mode output present for the poll to match.
- [ ] terraform fmt/init -backend=false/validate/tflint/checkov pass for the module directory.
- [ ] README.md documents the interface, auto-sync as production target, and (if later needed) explicit registration as the labelled demo-determinism fallback only.
- [ ] COMPATIBILITY.md row for the API Center ARM API version with last-verified date and doc link.

**Out of scope (must NOT do):**
- No terraform apply or destroy; static validation only.
- No bounded-poll assertion script (that is ticket 5); this ticket only outputs the endpoint and access mode.
- No API Center portal publishing flow, no Foundry tool-catalog wiring.
- No explicit azapi server registration as the primary mechanism (auto-sync is primary; explicit registration only as a documented fallback if ticket 5 finds the poll flaky).

**Spec section:** Registry (S3); Terraform and state.

---

## Ticket 5: Integration - compositions, live apply-call-destroy gate, discovery assertions, demo

**What to build:** The s1 and s2 scenario compositions that wire the four modules
with remote state and the public-demo profile, the gated live-test workflow that
runs apply-call-destroy, the two-part test harness (McpTestClient session/tool
assertions + raw HTTP discovery assertions including the shadow-key negative test),
the bounded registry poll, the demo script, and the docs that land with the slice.
This ticket owns the live end-to-end gate. This issue may land as a short PR series
under it (compositions plus workflow first, then harness plus docs), each PR
reviewed normally; do not split the issue itself.

**Blocked by:** Ticket 4.

**Files to create:**
- infra/terraform/scenarios/s1-entra-mcp-server/{versions.tf,backend.tf,main.tf,variables.tf,outputs.tf,.terraform.lock.hcl,README.md}
- infra/terraform/scenarios/s2-apim-mcp-gateway/{versions.tf,backend.tf,main.tf,variables.tf,outputs.tf,.terraform.lock.hcl,README.md}
- .github/workflows/ephemeral-env.yml (gated live-test workflow; runs-on: ubuntu-latest; OIDC; live-test environment)
- scripts/gate/invoke-and-assert.ps1 (drives McpTestClient + curl discovery assertions + bounded registry poll)
- scripts/demo/demo.ps1 (demo script; warms the endpoint, no latency claims)
- tests/integration/discovery-assertions.ps1 (raw HTTP: 401/WWW-Authenticate/PRM/wrong-audience/shadow-key)
- docs/demos/README.md (demo script index; interactive-discovery-in-VS-Code step recorded here)
- docs/runbooks/entra-app-registrations.md (out-of-band procedure for the server resource app - app id URI, user_impersonation scope, app role for the test client - and the test client app - client credentials, admin consent)

**Files to modify:**
- src/McpTestClient/Program.cs (fill in the session/tool assertions against the deployed endpoint)
- docs/decisions/ADR-001... or docs/tradeoffs.md (add the tracer-bullet reasoning - decision now lands)
- docs/security.md (public-demo governance-bypass honesty note; Easy Auth as v0 compensating control)
- README.md (scenario index, quickstart, cost-to-run estimate labelled and dated)
- COMPATIBILITY.md (MCP Inspector current version pinned + verified-once + last-verified date)

**Composition interface (consumes module outputs; produces the deployed endpoints):**
- s1 composition: instantiates mcp-function-host; wires Entra inputs from variables (app ids by reference, never committed); backend = azurerm, key-per-composition, OIDC + use_azuread_auth; profile-driven sizing.
- s2 composition: instantiates apim-gateway + apim-mcp-server + api-center-registry; consumes mcp-function-host mcp_backend_base_url; deployment_profile = public-demo selects Basic v2; outputs mcp_server_url, prm_url, registry_endpoint_url.

**Verified facts this ticket depends on:**
- validate-azure-ad-token / PRM discovery artifacts as in ticket 3 docs; PRM at
  gateway root. Reference: https://github.com/blackchoey/remote-mcp-apim-oauth-prm
  and https://github.com/Azure-Samples/AI-Gateway (mcp-prm-oauth lab).
- CI gate token is acquired non-interactively via client credentials on the
  dedicated test app registration (the SDK interactive auth-code flow cannot run
  in CI; see spec: Testing Decisions).
- API Center sync is asynchronous; the poll is bounded and matches the read-access
  mode from ticket 4 (see spec: Registry (S3)).
- Workflows run on runs-on: ubuntu-latest only; never the org VNet runner group;
  never pull_request_target with PR-head checkout (CLAUDE.md hard safety rules).

**Acceptance criteria:**
- [ ] s1 and s2 compositions wire the four modules with azurerm remote backend, key-per-composition state, OIDC + use_azuread_auth, no committed secrets/ids; .terraform.lock.hcl committed per composition.
- [ ] deployment_profile = public-demo selects Basic v2 and public endpoints from the same modules.
- [ ] docs/runbooks/entra-app-registrations.md exists and documents creating the server resource app (app id URI, user_impersonation scope, app role for the test client) and the test client app (client credentials, admin consent); it has been executed (both app registrations exist, outside any ephemeral resource group) before the first live run.
- [ ] ephemeral-env.yml runs apply -> call -> destroy in the live-test environment only, on ubuntu-latest, OIDC, with an expiry-tagged resource group; documented as cost-gated and manual.
- [ ] McpTestClient asserts against the deployed gateway endpoint: initialize succeeds; tools/list contains get_order_status; CONTOSO-1003 returns the typed status; an unknown id returns the typed not-found.
- [ ] Raw HTTP discovery assertions pass: no-token -> 401 with WWW-Authenticate whose resource_metadata points at the root PRM URL; PRM document content correct; wrong-audience token rejected.
- [ ] Shadow-key negative test passes: a request presenting only the mcp_extension system key and no Entra token is rejected with 401, run against the backend host as well as the gateway (proves the shadow auth path is closed - spec story 31).
- [ ] Bounded registry poll asserts the server appears at registry_endpoint_url within the timeout, authenticating (or not) per the configured read-access mode.
- [ ] The gate documents its split: it does NOT auto-exercise interactive discovery; interactive discovery is validated manually in VS Code and recorded in docs/demos.
- [ ] Live gate leaves nothing running (destroy verified; expiry-tag sweep is belt-and-braces).
- [ ] ADR-001 or docs/tradeoffs.md records the tracer-bullet reasoning; security.md carries the public-demo governance-bypass honesty note; README carries the scenario index and a labelled, dated cost estimate.
- [ ] COMPATIBILITY.md updated with the pinned, verified-once MCP Inspector version.

**Out of scope (must NOT do):**
- No terraform apply or destroy anywhere except the live-test environment.
- No products, subscriptions, quotas, 429 demo, or content safety.
- No OBO, no downstream call, no second app registration (that is ticket 6).
- No private networking, no observability workbook/alerts.
- No new runner group; ubuntu-latest only.

**Spec section:** Delivery shape (issue 5); Testing Decisions; Registry (S3); Verification and compatibility.

---

## Ticket 6: OBO thickening (on-behalf-of downstream + token-passthrough negative test)

**What to build:** Reimplement get_order_status behind its frozen contract to fetch
from a synthetic downstream Orders API using the Entra on-behalf-of exchange, add
the second (downstream) app registration as an out-of-band referenced input, and
add the negative test proving the inbound token is rejected when passed through
directly to the downstream. v1 scope, opened immediately on ticket 5 close.

**Blocked by:** Ticket 5 (blocking edge on the tracer; v1 label - "first
thickening" must not drift past the v1 line, spec story 30).

**Files to create:**
- src/DownstreamOrdersApi/ (synthetic downstream returning order status; audience = downstream app)
- tests/integration/obo-passthrough-negative.ps1 (inbound token passed directly to downstream -> rejected)
- docs/runbooks/obo-app-registrations.md (the out-of-band downstream app registration + admin consent steps)

**Files to modify:**
- src/McpTools/Tools/GetOrderStatus.cs (reimplement via OBO; contract unchanged)
- src/McpTools/ (add the OBO exchange; server never forwards the inbound token)
- infra/terraform/modules/mcp-function-host and/or scenario variables (downstream app id, downstream api scope as referenced inputs)
- docs/decisions/ADR-006... (expand: OBO vs token passthrough, audience validation at two layers, the confused-deputy reasoning)
- docs/security.md (token-passthrough-forbidden now a measured claim, backed by the negative test)
- COMPATIBILITY.md if any new pin is introduced

**Interface change (contract frozen; implementation only):**
- get_order_status keeps its exact v1 contract (success and not-found shapes). Only
  its data source changes: in-memory fixture -> synthetic downstream via OBO.

**Verified facts this ticket depends on:**
- OBO sits on GA Entra machinery; the server exchanges the inbound user token for a
  downstream token (on-behalf-of flow) and never forwards the inbound token.
- The CI client-credentials token is app-context with no user, so it cannot drive a
  user-context OBO exchange; this ticket needs its own user-context token strategy
  for the OBO happy-path test (spec: Testing Decisions knock-on). Determine and
  document that strategy at issue start.

**Acceptance criteria:**
- [ ] get_order_status returns the same typed success/not-found shapes as v1 (contract unchanged), now sourced from the synthetic downstream via OBO.
- [ ] The server performs the OBO exchange and never forwards the inbound client token downstream.
- [ ] Second (downstream) app registration exists out-of-band and is referenced by id; a runbook documents its creation and consent.
- [ ] Negative test passes: the inbound token, presented directly to the downstream, is rejected (proves token passthrough is forbidden as a measured claim, not a README sentence).
- [ ] ADR-006 expanded with the OBO vs passthrough and confused-deputy reasoning; security.md updated to cite the negative test.
- [ ] Unit/integration tests and the live gate (extended for the OBO path) pass; ticket carries the v1 label.

**Out of scope (must NOT do):**
- No change to the get_order_status contract shape.
- No multi-tenancy, products, quotas, content safety, private networking, or observability.
- No terraform apply/destroy outside the live-test environment.
- No real (non-synthetic) downstream data.

**Spec section:** Delivery shape (OBO successor); Testing Decisions (knock-on); Out of Scope (OBO is v1 but separate).
