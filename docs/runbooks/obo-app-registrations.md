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
