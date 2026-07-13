# Runbook: Entra app registrations for the v1 tracer

Out-of-band procedure for the two Entra app registrations the s1/s2
compositions reference by client id (`entra_auth`/`entra_validation`
variables), per
[Identity provisioning](../specs/v1-tracer-bullet.md#implementation-decisions):
app registrations are long-lived, provisioned out of band, and live outside
the ephemeral resource group so the live-test cleanup sweep never deletes
them. This runbook must be executed once, before the first live run of
`.github/workflows/ephemeral-env.yml`; creating an app registration and
granting admin consent needs directory-write privilege the ephemeral CI
principal does not hold.

Neither app's client id, tenant id, or any secret is committed to this repo.
Both are supplied to the workflow as GitHub Environment variables/secrets on
the `live-test` environment, then passed into Terraform as the
`entra_auth`/`entra_validation` variable values.

Steps below reference the Microsoft Entra admin center
(https://entra.microsoft.com); verified against Microsoft Learn on
2026-07-12 (citations per step).

## 1. Server resource app (the MCP server's identity)

This is the app the Functions host (`entra_auth.server_app_client_id`) and
the APIM gateway (`entra_validation.audience`) both validate tokens against.

1. **App registrations > New registration.** Single tenant. No redirect URI
   needed (it is a web API, not an interactive client). ([Register an
   application](https://learn.microsoft.com/entra/identity-platform/quickstart-register-app#register-an-application))
2. **Expose an API > Add** next to Application ID URI. Accept the default
   `api://<application-client-id>` (or a verified-domain URI). This is the
   value `entra_auth.allowed_audiences` and `entra_validation.audience` must
   both carry. ([Configure an application to expose a web
   API](https://learn.microsoft.com/entra/identity-platform/quickstart-configure-app-expose-web-apis))
3. **Expose an API > Add a scope**, name `user_impersonation`, "Who can
   consent" = Admins and users (or Admins only, if you want to force admin
   consent for every caller). This is the scope `prm_scope` and `prm_scopes`
   both reference (`api://<server-app-id>/user_impersonation`).
4. **App roles > Create app role**: display name and value both e.g.
   `McpTestClient`, **Allowed member types = Applications** (this is what
   makes it usable by a non-interactive client-credentials caller, not a
   signed-in user). ([Add app roles to your
   app](https://learn.microsoft.com/entra/identity-platform/howto-add-app-roles-in-apps))
5. Record the **Application (client) ID** and **Directory (tenant) ID** from
   the Overview page. These become `entra_auth.server_app_client_id`,
   `entra_auth.tenant_id`, and `entra_validation.tenant_id`.

## 2. Test client app (the gate's non-interactive caller)

A dedicated app for `McpTestClient` and the discovery-assertion scripts to
authenticate as, via client credentials. Kept separate from any interactive
user identity because the SDK's interactive auth-code flow cannot run in CI
(docs/specs/v1-tracer-bullet.md, Testing Decisions).

1. **App registrations > New registration.** Single tenant. No redirect URI.
2. **Certificates & secrets > Client secrets > New client secret.** Record
   the secret value immediately (it is shown once). This secret is stored
   only as a GitHub Environment secret on `live-test`, never in this repo.
   ([Service Principal and a Client
   Secret](https://learn.microsoft.com/entra/identity-platform/quickstart-configure-app-access-web-apis))
3. **API permissions > Add a permission > My APIs**, select the server
   resource app from step 1, choose **Application permissions**, select the
   `McpTestClient` app role, **Add permissions**.
4. **Grant admin consent for `<tenant>`.** Required: application permissions
   (app roles) cannot be self-consented; a tenant administrator must grant
   consent once before the client-credentials flow can obtain a token
   carrying the role.
5. Record the **Application (client) ID**. This is
   `entra_validation.allowed_client_application_ids[0]` and the identity the
   gate's non-interactive token acquisition (client credentials) uses.

## Values this runbook produces, and where they are consumed

| Value | Consumed by |
|---|---|
| Server app's App ID URI (`api://<server-app-id>`) | `entra_auth.allowed_audiences`, `entra_validation.audience`, `prm_scope`/`prm_scopes` prefix |
| Server app's client id | `entra_auth.server_app_client_id` |
| Server/test client shared tenant id | `entra_auth.tenant_id`, `entra_validation.tenant_id` |
| Test client app's client id | `entra_validation.allowed_client_application_ids` |
| Test client app's client secret | The gate's non-interactive token acquisition (client credentials), stored as a GitHub Environment secret on `live-test`, never in Terraform state or this repo |

None of these values have a default in the s1/s2 composition variables; the
live-test workflow supplies them all as `TF_VAR_*` environment variables
sourced from the `live-test` GitHub Environment's variables/secrets.
