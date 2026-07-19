# Runbook: OBO app registrations and Graph permission bootstrap (issue 10)

Out-of-band procedure for issue 10 (OBO thickening): creating the downstream
Orders API's app registration, and granting the live-test OIDC principal the
Microsoft Graph application permissions it needs to manage the OBO
federated identity credential and consent grant itself, via Terraform. This
extends [entra-app-registrations.md](entra-app-registrations.md) (read that
runbook first for the server resource app and test client app, both of
which already exist before this ticket).

**What stays a manual, out-of-band, one-time step, and why:** creating an
app registration needs directory-write privilege the ephemeral CI principal
should not hold (docs/specs/v1-tracer-bullet.md, Identity provisioning) --
section 1 below. Granting the deploying principal ITS OWN new Graph
permissions is a bootstrap action no automated process can perform on
itself -- section 2 below.

**What is NOT a manual step, and why:** the OBO federated identity
credential and the OBO consent grant are BOTH Terraform-managed
(`infra/terraform/scenarios/s1-entra-mcp-server/main.tf`, the `azuread`
provider), applied and destroyed every live-test run alongside everything
else. This is a deliberate change from the naive design: the federated
credential's subject is the MCP server's Function App system-assigned
managed identity's principal id, which is DIFFERENT every ephemeral run (a
fresh identity in a fresh, ephemeral resource group) -- a one-time manual
credential would go stale on the very next run. See main.tf's block comment
above those resources for the full reasoning, and ADR-006, "OBO exchange:
the inbound-token gap and its correction," for why this runbook's earlier
revision (which described the federated credential as a manual step) was
wrong.

None of the values this runbook produces are committed to this repo. The
downstream app's client id and scope become the `downstream_app` Terraform
variable (via the `S1_TFVARS_JSON` live-test secret, same pattern as
`entra_auth`); the downstream app's own Easy Auth values become
`downstream_entra_auth`.

Steps below reference the Microsoft Entra admin center
(https://entra.microsoft.com); verified against Microsoft Learn on
2026-07-18 (azure-docs-verifier; citations per step; see COMPATIBILITY.md).

## 1. Downstream resource app (the Orders API's identity)

Same shape as the server resource app in entra-app-registrations.md section
1, but for `src/DownstreamOrdersApi`. This is a SEPARATE app registration
from the server app: the negative test
(`tests/integration/obo-passthrough-negative.ps1`) depends on the two apps
having different Application ID URIs, so a token minted for one is rejected
as the wrong audience on the other.

1. **App registrations > New registration.** Single tenant. No redirect URI
   (a web API, not an interactive client).
2. **Expose an API > Add** next to Application ID URI. Accept the default
   `api://<downstream-application-client-id>`. This is the value
   `downstream_entra_auth.allowed_audiences` must carry, and the prefix of
   `downstream_app.api_scope`.
3. **Expose an API > Add a scope**, name `user_impersonation`, "Who can
   consent" = Admins and users. This is `downstream_app.api_scope`
   (`api://<downstream-app-id>/user_impersonation`), the scope the
   Terraform-managed OBO consent grant (section 2 below) authorizes and the
   scope the OBO exchange requests.
4. Record the **Application (client) ID** and confirm the **Directory
   (tenant) ID** matches the server app's tenant (both apps must be in the
   same tenant for OBO). These become `downstream_app.client_id` and
   `downstream_entra_auth.server_app_client_id` /
   `downstream_entra_auth.tenant_id`.

## 2. Bootstrap the live-test OIDC principal's Graph permissions

This is the step that actually needs doing by a human before the first live
run that exercises OBO. Terraform manages the FIC and the consent grant
(main.tf), but the identity RUNNING Terraform -- the live-test workflow's
OIDC-federated service principal (the same one already granted ARM
`roleAssignments/write` per docs/runbooks/live-test-gate.md, "Role-assignment
write (RBAC bootstrap)") -- needs its OWN Microsoft Graph application
permissions to manage these Entra objects, and nothing can grant a
principal permissions on itself.

1. On the live-test OIDC principal's app registration (the same one whose
   client id is `ARM_CLIENT_ID`/`vars.AZURE_CLIENT_ID` in
   `.github/workflows/ephemeral-env.yml`) > **API permissions > Add a
   permission > Microsoft Graph > Application permissions**, add:
   - **`Application.ReadWrite.All`** -- required by
     `azuread_application_federated_identity_credential`
     ([resource docs](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/application_federated_identity_credential):
     "requires one of the following application roles:
     `Application.ReadWrite.OwnedBy` or `Application.ReadWrite.All`"; this
     runbook uses the broader `.All` role rather than making the CI
     principal an owner of the server app, to avoid a second manual
     ownership-assignment step).
   - **`Directory.ReadWrite.All`** -- required by
     `azuread_service_principal_delegated_permission_grant`
     ([resource docs](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/service_principal_delegated_permission_grant):
     "requires the following application role: `Directory.ReadWrite.All`").
2. **Grant admin consent for `<tenant>`.**

**This is a meaningful privilege increase for the CI/live-test principal,**
worth flagging plainly rather than downplaying: `Directory.ReadWrite.All`
is one of the broadest Microsoft Graph application permissions that exists,
short of directory-role-equivalent access. It is scoped to this single
principal (already OIDC-only, no stored credential, per CLAUDE.md), and its
blast radius is the same principal that already holds ARM
`roleAssignments/write` across this repo's ephemeral resources -- but it is
real, tenant-wide, directory-object write capability, not narrowly scoped
to this repo's own objects. If that trade-off is unacceptable, the
alternative is reverting the FIC and consent grant to manual, one-time
steps against a STABLE (non-rotating) credential source instead of the
per-run managed identity -- which would require a different design (e.g. a
long-lived user-assigned managed identity referenced by id, out of this
ticket's Now-column scope) and is not what this PR implements.

## 3. User-context token strategy (the OBO happy path)

The OBO exchange needs a delegated, user-context token as its `user_assertion`.
The live gate's existing caller acquires a **client-credentials** token, which
is app-only (no user), so it cannot drive a real OBO exchange (issue 10 amended
"Verified facts"; ADR-006, "Testing strategy: the user-context token problem").
This section records the decided strategy exactly. The honesty rule applies
throughout: nothing below is a measured result until the manual demo is run and
its evidence captured; do not write a claim you have not evidenced.

### Decision: no live user-context token in the PR-blocking gate

There is no GA, non-interactive, CLAUDE.md-compliant mechanism to acquire a
delegated user token in unattended CI (verifier 2026-07-18). So the OBO happy
path is **not** gated. It is covered at two levels instead:

1. **Unit / integration tests behind a token-broker abstraction (automated,
   PR-blocking).** The OBO exchange sits behind `IOboTokenAcquirer` and the
   downstream call behind `IDownstreamOrdersClient` (`src/McpTools/Downstream`).
   The tests (`tests/McpTools.Tests/DownstreamOrdersClientTests.cs`,
   `GetOrderStatusRunTests.cs`) fake the broker to assert, with no Azure
   dependency: the inbound assertion and downstream scope are passed to the
   exchange; the downstream call carries the OBO-exchanged token and **never**
   the inbound assertion; and the downstream's responses map to the frozen
   `get_order_status` shapes. This proves the code's OBO behaviour without any
   real token.
2. **Manual demo with a sandbox test user (evidenced, not gated).** A human
   acquires a genuine delegated token and exercises the delegated branch end to
   end, capturing the evidence below.

**Coverage split, stated plainly (issue-10 governance finding).** The automated
live gate authenticates with a client-credentials (app-only) token, so it
exercises ONLY the **app-context** branch and, with it, the resolver's
detection of the `roles` claim form inside `X-MS-CLIENT-PRINCIPAL`. The
**delegated `scp`** claim-type detection -- and whether that claim appears as
the short `scp` name or a mapped schema URI (UNVERIFIABLE on Learn;
COMPATIBILITY.md) -- is confirmed ONLY by this manual demo, never by the
automated gate. The resolver already matches both forms, so it is robust either
way, but the delegated form is a live-observed fact this manual run is the only
thing that closes. Capture the observed claim form in the evidence below.

### Manual demo procedure (device-code flow)

Use the **device-code flow** with a dedicated **sandbox test user** (a
cloud-only user in the same tenant, with no standing access to anything beyond
the demo scope). Device code is chosen over a full auth-code redirect because it
needs no registered reply URL and runs from a terminal, while still being a
genuine interactive user sign-in (MFA/Conditional Access apply normally).

1. Ensure the demo client app registration has the delegated
   `api://<server-app>/user_impersonation` scope and a
   `allowPublicClient`/native platform so device code is permitted; sign the
   sandbox user in once to consent (or admin-consent the scope).
2. Acquire a delegated token as the sandbox user, e.g.
   `az login --use-device-code --allow-no-subscriptions` then
   `az account get-access-token --scope api://<server-app>/user_impersonation`
   (or an equivalent MSAL device-code call). Confirm it is a **user** token:
   the decoded token has an `scp` claim and a user `oid`/`preferred_username`,
   not a `roles` claim.
3. Call `get_order_status` through the gateway with that token (McpTestClient or
   the MCP Inspector). Because the token carries `scp`, the server takes the
   **delegated** branch and sources the result from the downstream via OBO.

### Evidence to capture (label each as evidence, never fabricate)

- The decoded **inbound** token showing `scp` + a real user identity (redact
  the raw token; capture only the non-sensitive claim names/values that prove
  it is delegated).
- The `get_order_status` result for a known id (e.g. CONTOSO-1001) matching the
  frozen contract, and an unknown id returning the typed not-found shape.
- Evidence the downstream was reached via OBO, not passthrough: the downstream
  received a token whose **audience is the downstream app** (from the
  downstream Function App's auth logs / a gateway or app trace), distinct from
  the inbound server-audience token. Pair this with the automated negative test
  result (app-context passthrough rejected) so the delegated-passthrough-also-
  rejected claim in docs/security.md is backed by captured evidence.
- The date, the tenant, the sandbox user (by role, not by any secret), and the
  tool/version used. Record the run in `docs/demos`.

If any step cannot be completed, say so in the demo record rather than writing
an unverified success.

### Rejected alternatives (and why)

- **ROPC (resource-owner password credentials).** Rejected. Microsoft is
  deprecating ROPC in MSAL and removing it product by product; it is
  incompatible with MFA and Conditional Access; and it would require storing a
  real user's password as a CI credential -- itself the kind of secret CLAUDE.md
  forbids. It would defeat the point (a "user" token that bypasses the controls
  a real user is subject to).
- **Seeded refresh token in Key Vault.** Rejected for v1. A long-lived seeded
  refresh token carries lifetime, Conditional Access interaction, and rotation
  overhead that outweigh the benefit at this scale. Recorded as the least-bad
  automated option **only** if a future consumer genuinely requires
  PR-blocking live OBO; it is not implemented here.

## Values this runbook produces, and where they are consumed

| Value | Consumed by |
|---|---|
| Downstream app's App ID URI / scope (`api://<downstream-app-id>/user_impersonation`) | `downstream_app.api_scope` |
| Downstream app's client id | `downstream_app.client_id`; also used by `data "azuread_service_principal" "downstream"` in `s1-entra-mcp-server/main.tf` |
| Downstream app's client id and App ID URI | `downstream_entra_auth.server_app_client_id`, `downstream_entra_auth.allowed_audiences` |
| Shared tenant id | `downstream_entra_auth.tenant_id` |
| Live-test OIDC principal's Graph permissions (section 2) | Prerequisite for `s1-entra-mcp-server/main.tf`'s `azuread_application_federated_identity_credential` and `azuread_service_principal_delegated_permission_grant` to apply successfully; no Terraform variable, a Graph-side grant on the deploying principal itself |

## What this runbook does NOT need to resolve (already resolved)

An earlier revision of this PR treated the federated identity credential as
a manual runbook step and separately documented (wrongly) that
`GetOrderStatus.Run` had no path to the caller's inbound token at all. Both
are corrected: the FIC and consent grant are Terraform-managed (this
runbook only bootstraps the Graph permissions that makes possible), and
`GetOrderStatus.Run` does call the OBO exchange in its live path (ADR-006,
"OBO exchange: the inbound-token gap and its correction"). What remains
genuinely unautomated is the OBO HAPPY PATH in CI -- a different, unrelated
constraint (no non-interactive way to acquire a delegated user token; see
ADR-006, "Testing strategy: the user-context token problem") -- validated
manually, not by this runbook or by the automated live gate.
