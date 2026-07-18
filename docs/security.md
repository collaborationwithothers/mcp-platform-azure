# Security posture (v1 tracer)

Honest, per-surface security notes for the v1 tracer bullet. Sections are added
by the ticket that lands the surface they describe. Everything here is the
public-demo profile; the demo data is synthetic and labelled synthetic.

## Registry (API Center) access

The API Center data-plane MCP registry endpoint is **Entra-protected by
default**: unauthenticated requests are rejected (401). Read access is not
configurable through the `Microsoft.ApiCenter` ARM/azapi surface in any
published API version as of 2026-07-12, so this posture is platform-determined,
not something the module sets. (Microsoft Learn documents Entra ID as the
recommended access method and anonymous access as an explicit opt-in; the exact
unauthenticated-response code is confirmed at the live gate, not asserted from a
doc page.)

Every consumer inside the Entra trust boundary reads the registry
**authenticated**:

- **Test harness (this tracer).** Ticket 5's bounded poll authenticates with an
  OIDC principal that holds the **Azure API Center Data Reader** role on the
  instance, granted by the `api-center-registry` module via
  `data_reader_principal_ids`.
- **Foundry tool-catalog integration.** A tool-catalog integration with API
  Center exists; its exact registry auth mechanics are to be verified at that
  phase, not assumed here.
- **Custom agents.** Read via their own managed identity holding Data Reader on
  the instance.

**Anonymous access is a portal-only opt-in this deployment does not use.** It is
toggled in the Azure portal (Consumption > Portal settings > Access tab); there
is no IaC surface for it. Its known consumer is **GitHub Copilot's registry
integration**, which reads the registry without an Entra token. The cost of
enabling it is **public enumerability of registered server and tool metadata**
(server names, endpoint URLs, transport types, tool descriptions). This
deployment keeps the authenticated default; the optional, Copilot-only
enablement steps are in `docs/runbooks/registry-anonymous-access.md`.

Regardless of read mode, **nothing sensitive is placed in registered metadata**:
the inventory carries service/tool descriptions and endpoint URLs for the
synthetic demo server only, no secrets, tokens, or tenant/subscription
identifiers.

## Gateway and backend auth (public-demo profile)

The `s1-entra-mcp-server` and `s2-apim-mcp-gateway` scenario compositions
wire two independent Entra token checks: the gateway's `validate-azure-ad-token`
policy (issuer, audience, allowed client application ids) in
`apim-mcp-server`, and the Functions built-in auth (Easy Auth) check in
`mcp-function-host`. Both must pass; APIM forwards the `Authorization` header
it already validated to the Functions backend, which independently
re-validates it (defense in depth, not the token-passthrough anti-pattern --
that anti-pattern is downstream reuse, out of the tracer's scope until the
OBO issue).

**Honest limitation of the public-demo profile:** the Functions endpoint is
still public in v1 (the private-network module and profile are v1.1, out of
this scenario's scope). A caller who has a valid Entra token for the server
app can reach the Functions backend directly, bypassing the gateway
entirely -- and with it, every governance control the gateway would
otherwise enforce (rate limiting, quotas, content safety on tool-call
arguments; all v1.1/S2-thickening features, not yet built). The Functions
built-in auth check is real and independent, so a direct-to-backend caller
is not unauthenticated -- but "authenticated" and "governed by the
gateway's policies" are not the same guarantee, and public-demo only
provides the former for a caller who bypasses APIM. This reframes to
belt-and-braces (a second, redundant check behind a gateway that is the only
reachable path) once the v1.1 private-network module closes the Functions
endpoint's public network access. Until then, Easy Auth on the backend is a
compensating control, not a substitute for the gateway's governance.

The shadow `mcp_extension` system-key access path is closed on the backend
(see `mcp-function-host`'s README, "mcp_extension key posture"); the live
gate's negative test (system key present, no Entra token, expect 401) proves
this against both the gateway and the backend host directly
(docs/specs/v1-tracer-bullet.md, Compute and the tool (S1)).

## OBO and downstream auth (issue 10)

The synthetic downstream Orders API (`src/DownstreamOrdersApi`) is a second
Function App instance with its OWN Entra built-in auth, `allowed_audiences`
scoped to ONLY the downstream app registration -- a separate audience
check from the MCP server's, not a shared one (docs/decisions/ADR-006,
"OBO exchange: confused deputy, audience validation, and the inbound-token
gap").

**Token passthrough is forbidden as a measured claim, not a README
sentence:** presenting the inbound (server-audience) token directly to the
downstream must be rejected with 401, because the platform's own audience
check on the downstream instance does not accept it. This is wired into the
live gate as `tests/integration/obo-passthrough-negative.ps1`, invoked from
`scripts/gate/invoke-and-assert.ps1`'s step [5] -- **not yet run against a
live deployment as of this PR** (docs/runbooks/live-test-gate.md); the
measured result lands with the first live-test run that includes it, not
this PR. This requires no application code to enforce; it follows from the
two Function App instances having disjoint `allowed_audiences`.

The sanctioned path is the OBO exchange, and `get_order_status` calls it in
its live/deployed path: `GetOrderStatus.Run` reads the caller's inbound
token via the MCP extension's `TryGetHttpTransport`/`HttpTransport.Headers`
(token-store header first, raw `Authorization` header fallback -- see
ADR-006, "OBO exchange: the inbound-token gap and its correction," for why
an earlier revision of this PR wrongly concluded this was unreachable, and
the correction chronology), then exchanges it for a downstream-audience
token via Entra, authenticating itself with NO stored client secret (a
federated identity credential trusting the server's Function App managed
identity, Terraform-managed and re-created every ephemeral run,
docs/runbooks/obo-app-registrations.md). The exchange logic
(`McpTools.Downstream.DownstreamOrdersClient`, `ManagedIdentityOboTokenAcquirer`)
is unit-tested, including an explicit test asserting the downstream call
never carries the inbound assertion, and `GetOrderStatus.Run`'s own
orchestration is unit-tested against a fake downstream client.

**Honest limitation, current as of this ticket:** the OBO HAPPY PATH (a
real delegated user token round-tripping through the downstream) is not
exercised by the automated live gate. This is a different constraint from
the inbound-token question above: no GA, non-interactive,
CLAUDE.md-compliant mechanism exists to acquire a genuine delegated user
token in CI (client-credentials tokens are app-only, ROPC is discouraged
and would need a stored password, device code needs a human) -- ADR-006,
"Testing strategy: the user-context token problem." The happy path is
validated manually in the live-test environment by a human with a real
interactive sign-in, not automated. The automated live gate covers the
negative test only.
