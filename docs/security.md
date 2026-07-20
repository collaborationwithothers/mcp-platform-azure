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

- **Test harness (this tracer).** Ticket 5's registry step authenticates with an
  OIDC principal that holds the **Azure API Center Data Reader** role on the
  instance, granted by the `api-center-registry` module via
  `data_reader_principal_ids`. This step is **non-blocking evidence** in the
  blocking gate (Tier 1), which asserts only gateway and backend correctness and
  makes no API Center assertion (ADR-007). The read records the authenticated
  status -- a **401** (wrong data-plane audience `https://azure-apicenter.net`)
  or **403** (Data Reader role not propagated) is surfaced as a warning for the
  asynchronous Tier 2 monitor, not a gate failure -- and whether a specific
  server has converged into `/v0.1/servers`. Absence is expected inside an
  ephemeral gate: APIM auto-sync is documented at up to 24 h (Microsoft Learn),
  and there is no automatable way to register a server explicitly (verified
  2026-07-20; azapi, `az` CLI, and the data-plane API all lack the surface -- see
  COMPATIBILITY.md and ADR-007). The raw `/v0.1/servers` response is captured as
  a gate artifact. Registry convergence itself is a Tier 2 concern, monitored
  asynchronously (designed in ADR-007, not implemented on cost grounds).
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

**Token passthrough is forbidden, and the evidence for it comes at two
different confidence levels -- keep them distinct:**

- **Automated, measured (app-context token).** Presenting the inbound
  server-audience token directly to the downstream must be rejected with 401,
  because the downstream instance's own `allowed_audiences` check does not
  accept it. The automated negative test
  (`tests/integration/obo-passthrough-negative.ps1`, invoked from
  `scripts/gate/invoke-and-assert.ps1`'s step [6]) uses **the app-context
  client-credentials token the gate already holds** (audience = the MCP server
  app), so it needs no user context. **Measured 2026-07-19**: passed live in
  `ephemeral-env.yml` run
  [29681694550](https://github.com/collaborationwithothers/mcp-platform-azure/actions/runs/29681694550)
  (call stage green, which ran the then-current step [5]). That run used
  `skip_teardown=true`,
  so the destroy half of apply-call-destroy is not yet proven; a clean full run
  still validates teardown.
- **Manually evidenced (delegated token).** A *delegated* (user-context)
  inbound token, presented directly to the downstream, is **also** rejected on
  the same audience check. Exercising this needs a real user token, which the
  automated gate cannot acquire (see the "User-context token strategy" section
  of docs/runbooks/obo-app-registrations.md), so
  it is evidenced **manually** in the live-test environment with captured
  evidence per `docs/runbooks/obo-app-registrations.md`, not by the automated
  gate. It is the same enforcement mechanism as the app-context case; only the
  token's origin differs.

Both follow from the two Function App instances having disjoint
`allowed_audiences`; neither requires application code to enforce.

The downstream access path depends on the caller identity mode.
`get_order_status` branches on caller identity mode
(`McpTools.Identity.IdentityModeResolver`, decided from the
`X-MS-CLIENT-PRINCIPAL` claims Easy Auth injects):

- **Delegated (an `scp` claim):** `GetOrderStatus.Run` reads the caller's
  inbound token via the MCP extension's
  `TryGetHttpTransport`/`HttpTransport.Headers` and exchanges it for a
  downstream-audience token via Entra, authenticating itself with NO stored
  client secret (a federated identity credential trusting the server's Function
  App managed identity, Terraform-managed and re-created every ephemeral run,
  docs/runbooks/obo-app-registrations.md). The token-store header
  (`X-MS-TOKEN-AAD-ACCESS-TOKEN`) is expected **absent** in this topology (no
  token store), so the raw `Authorization` bearer is the operative OBO user
  assertion. See ADR-006, "OBO exchange: the inbound-token gap and its
  correction," for why an earlier revision wrongly concluded the inbound token
  was unreachable. The exchange logic
  (`McpTools.Downstream.DownstreamOrdersClient`, `ManagedIdentityOboTokenAcquirer`)
  is unit-tested, including an explicit test asserting the downstream call
  never carries the inbound assertion.
- **App-context (an `azp`/`appid` application identity, no `scp`):** the MCP
  layer requires `Orders.Read` in the `roles` claim. A missing role returns the deterministic tool
  error `403 Forbidden: get_order_status requires the application role
  'Orders.Read'.` The server then uses the same managed-identity-backed
  confidential client to acquire a downstream `/.default` token for its own
  application identity. The downstream's built-in auth independently
  allowlists only the MCP server app client id. The original caller's
  `azp`/`appid` and `oid` are structured-log fields and downstream correlation
  headers only. The downstream never authorizes from those headers.

`GetOrderStatus.Run`'s own branching is unit-tested against a fake downstream
client (delegated -> OBO downstream, authorized app-context -> app-only
downstream, missing role/principal -> rejected).

### Header trust chain (issue 10)

The server does **not** perform full in-code JWT signature validation. It
relies on a layered trust chain and asserts, rather than re-checks, the parts
upstream layers own:

1. **APIM validates** the inbound Entra token at the gateway
   (`validate-azure-ad-token`: issuer, audience, allowed client application
   ids) before forwarding it.
2. **Easy Auth (built-in auth) validates** the token again independently on the
   Function App (audience = the server app), and on success injects the decoded
   `X-MS-CLIENT-PRINCIPAL` header. Crucially, **when built-in auth is enabled it
   strips any client-supplied `X-MS-*` headers** before injecting its own, so a
   caller cannot forge a principal.
3. **The code asserts (does not re-validate).** It asserts Easy Auth is enabled
   (the startup `BuiltInAuthGuard`, below) and then does **claims-based
   authorization** on the trusted `X-MS-CLIENT-PRINCIPAL` (the delegated-vs-
   app-context decision).

**Startup fail-closed check.** `BuiltInAuthGuard` (run in `Program.cs` before
any tool is served) refuses to start in any non-`Development` environment
unless a built-in-auth signal is present. The ticket names
`WEBSITE_AUTH_ENABLED`; Microsoft Learn documents it as injected to indicate
auth is enabled but does not confirm its value form or its presence under
`auth_settings_v2` on Flex Consumption, so the guard **also** accepts the
documented v2-specific signal `WEBSITE_AUTH_V2_CONFIG_JSON` (platform-populated
from the v2 auth config). Either signal satisfies the guard; the live gate
confirms which the platform injects (verifier 2026-07-18; COMPATIBILITY.md).

**Per-request check.** `GetOrderStatus.Run` rejects any request whose
`X-MS-CLIENT-PRINCIPAL` is missing or malformed (the established error shape: a
thrown tool error, distinct from the typed not-found result). This per-request
check is **only sound in combination with the startup check**: it trusts the
header, and the header is only trustworthy because enabled Easy Auth strips
client-supplied `X-MS-*` headers -- which the startup check guarantees is the
case. Without the startup guarantee, a caller reaching a mis-configured host
with Easy Auth off could supply its own `X-MS-CLIENT-PRINCIPAL` and pick its
own identity mode.

**Trusted-subsystem trade-off and backstop asymmetry.** The delegated branch
keeps the original user's authority through OBO. The app-context branch cannot
do that because there is no user. It instead enforces per-caller policy at the
MCP layer and calls downstream as one server identity. The downstream therefore
cannot distinguish the original agents for authorization; compromising the
server identity affects every authorized app-only caller. The caller ids carried
in `X-Mcp-Caller-Azp` and `X-Mcp-Caller-Oid` preserve audit attribution but are
explicitly not trusted for authorization. The app-context branch also has no
OBO-exchange backstop for the inbound caller, so its fail-closed controls are
critical: APIM and built-in auth validate the inbound token, code requires
`Orders.Read`, and downstream built-in auth accepts only the server app. This is
the intentional trusted-subsystem trade-off, not token passthrough.

**Multi-tenant seam, documented but not wired in v1.** APIM product or
subscription membership and Entra application-role grants are independent
authorization systems in this tracer. A future multi-tenant design must align
the tenant-facing APIM product boundary with the principals granted
`Orders.Read`; issue 45 deliberately does not implement that binding. The
`X-Mcp-Caller-Azp` and `X-Mcp-Caller-Oid` audit headers must never be used to
infer tenant membership or replace that explicit authorization wiring.

**Trust-chain caveat flagged for live confirmation.** Whether Easy Auth fully
populates `X-MS-CLIENT-PRINCIPAL`'s claims mapping **without a token store
enabled** is a documented ambiguity (Microsoft Learn attaches a "token store
required for claims mapping" note whose scope is unclear; the official
`remote-mcp-functions-dotnet` sample decodes the header with no token store).
This is verified at the live gate, not asserted here (verifier 2026-07-18;
COMPATIBILITY.md).

**Honest limitation, current as of this ticket:** the OBO HAPPY PATH (a
real delegated user token round-tripping through the downstream) is not
exercised by the automated live gate. This is a different constraint from
the inbound-token question above: no GA, non-interactive,
CLAUDE.md-compliant mechanism exists to acquire a genuine delegated user
token in CI (client-credentials tokens are app-only, ROPC is discouraged
and would need a stored password, device code needs a human) -- ADR-006,
"Testing strategy: the user-context token problem." For the delegated path,
the automated live gate covers the passthrough negative test only. The
delegated happy path is validated manually:
**done 2026-07-19** -- a device-code delegated token drove the delegated
branch -> OBO -> downstream, returning both frozen contract shapes; captured
evidence in docs/demos/obo-happy-path.md (which also confirms the delegated
`scp` branch fires live, though the exact claim-type string form remains
inferred, not directly observed).
