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
downstream app's client id and scopes become the `downstream_app` Terraform
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
4. **App roles > Create app role**: display name and value both
   `Orders.Read`, **Allowed member types = Applications**. The s1 composition
   assigns this role to the MCP server service principal through
   `azuread_app_role_assignment`; do not assign it manually.
5. Record the **Application (client) ID** and confirm the **Directory
   (tenant) ID** matches the server app's tenant (both apps must be in the
   same tenant for OBO). These become `downstream_app.client_id` and
   `downstream_entra_auth.server_app_client_id` /
   `downstream_entra_auth.tenant_id`.
6. **Enterprise applications > `<downstream app>` > Properties >
   "Assignment required?" = Yes** (issue 53). This is the
   `appRoleAssignmentRequired` toggle on the downstream **service principal**
   (the Enterprise Application object), NOT on the app registration you created
   in steps 1-5 -- the property lives on the service principal, and for apps
   where the portal does not surface it the documented alternative is to set
   `appRoleAssignmentRequired` on the service principal via PowerShell/Graph
   ([howto-restrict-your-app-to-a-set-of-users](https://learn.microsoft.com/entra/identity-platform/howto-restrict-your-app-to-a-set-of-users#update-the-app-to-require-user-assignment)).
   It turns the Terraform-assigned `Orders.Read` grant (section on
   `azuread_app_role_assignment` in the composition README) from a bare grant
   into an enforced issuance-time gate: Entra refuses to mint the app-only
   downstream token for any principal that lacks the assignment
   ([client-credentials flow, Get direct authorization](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-client-creds-grant-flow#get-direct-authorization)).
   Low-churn path: this is set once, out of band, and is deliberately NOT managed
   in Terraform -- the composition reads the downstream service principal as a
   data source (`data.azuread_service_principal.downstream`), and managing the
   toggle would mean taking ownership of it as a resource for no per-run benefit.
   See ADR-006, "Downstream assignment-required issuance gate," and
   COMPATIBILITY.md.
7. **Assign the delegated demo user (or a group) to the downstream enterprise
   application** (issue 53). Assignment-required also applies to the signed-in
   user on the OBO path, so the sandbox/delegated test user used for the manual
   OBO happy path (section 3) must be assigned to THIS downstream app
   (**Enterprise applications > `<downstream app>` > Users and groups > Add
   user/group**), directly or via a group. Microsoft Learn documents the
   assignment requirement for interactive sign-in and app-only token acquisition;
   whether it ALSO gates the OBO token-exchange step for a delegated scope is NOT
   documented and is UNPROVEN in this repo (ADR-006, "Downstream
   assignment-required issuance gate"; docs/demos/obo-happy-path.md "Run
   2026-07-22"), so treat the delegated-user assignment as a required precondition
   for the happy path but do not assume an unassigned NON-admin user is refused
   until that negative test is run cleanly. Group-based assignment is valid but
   needs Entra ID P1/P2 and does not follow nested groups; a direct user
   assignment is sufficient for the single demo user
   ([assign-user-or-group-access-portal](https://learn.microsoft.com/entra/identity/enterprise-apps/assign-user-or-group-access-portal#prerequisites)).
   After enabling the toggle, **re-run the manual delegated happy path** (section
   3; docs/demos/obo-happy-path.md) to confirm OBO still succeeds.

   **Global Administrator bypass -- this bit us on 2026-07-22.** Global
   Administrators bypass `appRoleAssignmentRequired` entirely, so an admin's
   unassigned delegated call STILL succeeds and looks like the gate is broken when
   it is not. Any manual negative test of this gate (unassigned user expected to
   be refused with **AADSTS50105**, "The signed in user isn't assigned to a role
   for the ... app") MUST use a **non-admin sandbox user** and confirm the failure
   in BOTH the McpTestClient output (the call fails, not returns an order) and the
   MCP server Function App logs. This does NOT affect the server-side role-less
   negative test: that runs against the server app (entra-app-registrations.md
   section 3), whose service principal must stay assignment-NOT-required so
   role-less tokens can still be issued for the MCP-layer 403 arm.

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
   sandbox user in once to consent (or admin-consent the scope). **Since issue
   53 (assignment-required on the downstream app):** the sandbox user must ALSO
   be assigned to the downstream enterprise application (section 1 step 7),
   directly or via a group, or the OBO exchange for that user is refused with
   AADSTS50105. This run doubles as the post-toggle re-validation of the
   delegated happy path.
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

## Assembling the `S1_TFVARS_JSON` live-test Environment secret

The s1 composition's tfvars are stored as the `S1_TFVARS_JSON` GitHub
**Environment** secret (live-test), written to `s1.tfvars.json` and passed to
`terraform apply -var-file` by `.github/workflows/ephemeral-env.yml`. GitHub
secrets are replace-only (no patching), so the WHOLE object below is what you
set. Issue 10 adds the `downstream_*` block to the pre-existing top block.

`resource_group_name` and `location` are NOT in this secret: the workflow
injects them per run via `TF_VAR_resource_group_name` / `TF_VAR_location`
(and a `-var-file` entry would override the per-run resource group, which is
wrong). All ids below are the out-of-band app registrations from sections 1-2
and `entra-app-registrations.md`; no client secret goes in this object (the
OBO path is secretless via the federated credential; the gate's separate
`TEST_CLIENT_SECRET` is its own Environment secret).

```json
{
  "name_prefix": "mcp-tracer",
  "tags": { "expiry": "<ephemeral-expiry-tag-value>" },

  "storage_account_name": "<primary Flex deploy storage acct: 3-24 lowercase alnum>",
  "create_storage_account": false,

  "entra_auth": {
    "tenant_id": "<tenant GUID>",
    "server_app_client_id": "<MCP SERVER app client id>",
    "allowed_audiences": ["api://<server-app-id>"]
  },
  "prm_scope": "api://<server-app-id>/user_impersonation",

  "downstream_app": {
    "client_id": "<DOWNSTREAM Orders API app client id>",
    "api_scope": "api://<downstream-app-id>/user_impersonation",
    "application_scope": "api://<downstream-app-id>/.default"
  },
  "downstream_entra_auth": {
    "tenant_id": "<same tenant GUID>",
    "server_app_client_id": "<DOWNSTREAM app client id>",
    "allowed_audiences": ["api://<downstream-app-id>"]
  },
  "downstream_storage_account_name": "<SECOND Flex deploy storage acct: distinct, 3-24 lowercase alnum>",
  "downstream_create_storage_account": false
}
```

Watch-outs:

- **Two distinct storage accounts.** `storage_account_name` and
  `downstream_storage_account_name` back two separate Function App instances and
  cannot be the same account. Set both `create_*` flags to match your existing
  convention (`false` = must pre-exist; `true` = Terraform creates it).
- **Same tenant** for both apps (OBO requires it).
- **`downstream_app.api_scope` must be the specific delegated scope**
  (`.../user_impersonation`), never a `.default` app-only scope, or OBO's
  `AcquireTokenOnBehalfOf` cannot request the consented delegated permission.
- **`downstream_app.application_scope` must be the downstream `/.default`
  scope.** The app-only branch uses it with `AcquireTokenForClient`; Entra
  includes the Terraform-assigned `Orders.Read` application role in that
  downstream token.
- **`downstream_entra_auth.allowed_audiences` is scoped to ONLY the downstream
  app** (`api://<downstream-app-id>`) -- that disjointness from the MCP server's
  audience is what makes the passthrough negative test meaningful.
- The composition also sets the downstream Easy Auth authorization policy's
  `allowedApplications` to the MCP server app client id. The downstream API
  therefore trusts only the server identity, while the original caller's
  `azp`/`appid` and `oid` are carried only as audit correlation headers.
- Optional keys that default if omitted: `deployment_profile` (`"public-demo"`),
  `app_settings` (`{}` -- the OBO app settings are injected by `main.tf`, not
  here), and `unauthenticated_action` inside each auth object (`"Return401"`).

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
