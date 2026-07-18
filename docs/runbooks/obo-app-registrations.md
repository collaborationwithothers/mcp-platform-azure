# Runbook: OBO app registrations and federated credential (issue 10)

Out-of-band procedure for issue 10 (OBO thickening): the downstream Orders
API's app registration, the OBO consent grant on the server resource app,
and the federated identity credential that lets the server's OBO exchange
authenticate with NO stored client secret. This extends
[entra-app-registrations.md](entra-app-registrations.md) (read that runbook
first for the server resource app and test client app, both of which
already exist before this ticket); the same rationale applies here: creating
app registrations, granting consent, and adding federated credentials needs
directory-write privilege the ephemeral CI principal does not hold, so this
is a human, out-of-band step, executed once before the first live run that
exercises OBO.

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
   (`api://<downstream-app-id>/user_impersonation`), the scope the OBO
   exchange requests.
4. Record the **Application (client) ID** and confirm the **Directory
   (tenant) ID** matches the server app's tenant (both apps must be in the
   same tenant for OBO). These become `downstream_app.client_id` and
   `downstream_entra_auth.server_app_client_id` /
   `downstream_entra_auth.tenant_id`.

## 2. Grant the server app consent to call the downstream app via OBO

Standard OBO consent model, unchanged for the lifetime of the v2.0 endpoint
([On-behalf-of flow: gaining consent for the middle-tier
application](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-on-behalf-of-flow#gaining-consent-for-the-middle-tier-application)):
the middle-tier app (the server app) needs an API permission entry for the
downstream app's scope, admin-consented, before `AcquireTokenOnBehalfOf` can
succeed. Without this step the OBO exchange fails at the token endpoint
regardless of the federated credential in step 3.

1. On the **server** resource app (entra-app-registrations.md section 1) >
   **API permissions > Add a permission > My APIs**, select the downstream
   app from section 1 above, choose **Delegated permissions**, select
   `user_impersonation`, **Add permissions**.
2. **Grant admin consent for `<tenant>`.**

## 3. Federated identity credential: no stored secret for the OBO exchange

The server app authenticates itself to the Microsoft identity platform (as
a confidential client, for the OBO token request) with NO client secret and
NO certificate: it presents a client assertion signed by the MCP server's
Function App's SYSTEM-assigned managed identity, which the server app
trusts via a federated identity credential. This is GA Microsoft Entra
workload identity federation with a managed identity as the credential
source, not preview (azure-docs-verifier, 2026-07-18:
[Configure an application to trust a managed
identity](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity)).
CLAUDE.md forbids committing secrets to this repo; this is how the OBO
exchange complies with that rule without a Key Vault module (out of v1
module scope).

Prerequisite: the MCP server's Function App must already exist (its
system-assigned identity's principal id, `identity_principal_id`, is an
`s1-entra-mcp-server` output), so this step runs AFTER the first `terraform
apply` of `s1-entra-mcp-server` with the downstream inputs wired in, not
before.

1. Get the Function App's system-assigned identity's **Object (principal)
   ID**: `terraform -chdir=infra/terraform/scenarios/s1-entra-mcp-server
   output -raw identity_principal_id`, or from the Function App's
   **Identity** blade in the portal (System assigned tab).
2. On the **server** resource app > **Certificates & secrets > Federated
   credentials > Add a credential**. The admin center's guided scenario
   picker only lists user-assigned managed identities as of 2026-07-18
   (azure-docs-verifier); a system-assigned identity's object id works
   identically at the validation layer but must be entered directly, so use
   **Other issuer** (or the Azure CLI / Graph API below) rather than the
   picker:
   - **Issuer**: `https://login.microsoftonline.com/<tenant-id>/v2.0`
   - **Subject identifier**: the Object ID from step 1
   - **Audience**: `api://AzureADTokenExchange`
   - **Name**: e.g. `mcp-server-obo-managed-identity`

   Equivalent Azure CLI (if the portal's "Other issuer" flow proves
   awkward for a managed-identity subject):
   ```bash
   az ad app federated-credential create \
     --id <server-app-client-id> \
     --parameters '{
       "name": "mcp-server-obo-managed-identity",
       "issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0",
       "subject": "<function-app-system-assigned-principal-id>",
       "audiences": ["api://AzureADTokenExchange"]
     }'
   ```
   ([Configure an application to trust a managed
   identity](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity),
   `az ad app federated-credential create` reference)

No secret or certificate is ever generated for the server app by this step.
`McpTools.Downstream.ManagedIdentityOboTokenAcquirer` (via
`Microsoft.Identity.Web.Certificateless`'s `ManagedIdentityClientAssertion`)
is the code that consumes this federated credential at runtime.

## Values this runbook produces, and where they are consumed

| Value | Consumed by |
|---|---|
| Downstream app's App ID URI / scope (`api://<downstream-app-id>/user_impersonation`) | `downstream_app.api_scope` |
| Downstream app's client id | `downstream_app.client_id` |
| Downstream app's client id and App ID URI | `downstream_entra_auth.server_app_client_id`, `downstream_entra_auth.allowed_audiences` |
| Shared tenant id | `downstream_entra_auth.tenant_id` |
| Server app's OBO consent (step 2) | Prerequisite for `AcquireTokenOnBehalfOf` to succeed at all; no Terraform variable, an Entra-side grant only |
| Federated identity credential (step 3) | Prerequisite for `ManagedIdentityOboTokenAcquirer` to authenticate the confidential client with no stored secret; no Terraform variable, an Entra-side credential only |

## What this runbook does NOT resolve

This runbook makes the OBO exchange runnable end to end from the server
app's identity/credential perspective. It does NOT resolve the separate,
verified platform gap that currently keeps `GetOrderStatus.Run` from
invoking that exchange: the Azure Functions MCP extension's McpToolTrigger
binding has no documented path to the caller's inbound bearer token (see
`src/McpTools/Tools/GetOrderStatus.cs`'s doc comment and
`docs/decisions/ADR-006`, "OBO exchange: the inbound-token gap"). Completing
this runbook is necessary but not sufficient for the OBO happy path to run
live; it is what makes `McpTools.Downstream.DownstreamOrdersClient`
deployable and ready the moment that gap closes.
