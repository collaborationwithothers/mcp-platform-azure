# Runbook: Entra app registrations for the v1 tracer

Out-of-band procedure for the Entra app registrations the s1/s2
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
4. **App roles > Create app role**: display name and value both
   `Orders.Read`, **Allowed member types = Applications** (this is what
   makes it usable by a non-interactive client-credentials caller, not a
   signed-in user). ([Add app roles to your
   app](https://learn.microsoft.com/entra/identity-platform/howto-add-app-roles-in-apps))
5. Record the **Application (client) ID** and **Directory (tenant) ID** from
   the Overview page. These become `entra_auth.server_app_client_id`,
   `entra_auth.tenant_id`, and `entra_validation.tenant_id`.

### 1a. Multi-server composition: per-server scopes and app roles (issue #17)

The multi-server composition puts a second passthrough MCP server behind the
same gateway at its own path, sharing this one server resource app and its
single Application ID URI (`api://<server-app-id>`), so both servers validate
against the same audience. To keep the two servers isolated the app exposes a
*per-server* delegated scope AND a *per-server* app role for each server, all
under that shared App ID URI. At runtime the APIM policy for each server admits
a caller only if the token's `scp` claim contains that server's scope OR its
`roles` claim contains that server's app role (OR semantics), so a caller
entitled to one server is rejected at the other. Each server's PRM advertises
only its own scope in `scopes_supported`.

Add the following on the same **Expose an API** and **App roles** blades used in
steps 3 and 4; these are additional entries, not replacements for
`user_impersonation` / `Orders.Read`.

> **A scope value and an app role value must be distinct strings within the same
> app registration, compared case-insensitively.** Entra stores both in the
> application's `value` fields (`oauth2PermissionScopes` for scopes, `appRoles`
> for roles) and rejects a new entry whose value duplicates any existing scope or
> role value ignoring case, with "contains a duplicate value". So a scope
> `orders.invoke` and a role `Orders.Invoke` collide. Use the Microsoft Graph
> convention that keeps them distinct: a delegated scope `X.Y` and an application
> role `X.Y.All`. `required_scope` and `required_role` are separate tfvars and
> are never required to match, so this costs nothing.

1. **Expose an API > Add a scope** for server 1. The scope's short name is the
   value the token carries in `scp`; choose a clear per-server name, e.g.
   `Orders.Invoke`. Record that string as `required_scope`. The
   full `api://<server-app-id>/Orders.Invoke` form is what server 1's PRM
   advertises: put it in `prm_scopes`, and only there (server 1's PRM
   `scopes_supported` lists server 1's scope only). ([Configure an application
   to expose a web
   API](https://learn.microsoft.com/entra/identity-platform/quickstart-configure-app-expose-web-apis))
2. **App roles > Create app role** for server 1: display name and value e.g.
   `Orders.Invoke.All` (the `.All` suffix keeps it distinct from the scope value
   above; see the note), **Allowed member types = Applications** (this is the
   app-only, client-credentials caller path; the value appears in the token's
   `roles` claim). Record the value as `required_role`. ([Add app roles
   to your
   app](https://learn.microsoft.com/entra/identity-platform/howto-add-app-roles-in-apps))
3. **Expose an API > Add a scope** for server 2, e.g. `Catalog.Invoke`.
   Record the string as `server_2_required_scope`; put
   `api://<server-app-id>/Catalog.Invoke` in `server_2_prm_scopes` and
   nowhere else (server 2's PRM advertises server 2's scope only).
4. **App roles > Create app role** for server 2, e.g. `Catalog.Invoke.All`,
   **Allowed member types = Applications**. Record the value as
   `server_2_required_role`.

The example strings above are illustrative; the actual scope and role strings
are the operator's choice, subject to the distinct-value rule in the note above.
Whatever you pick, the string registered here must match exactly the value
recorded in the corresponding tfvars key (`required_scope`, `required_role`,
`server_2_required_scope`, `server_2_required_role`) and the full
`api://.../<scope>` value in the matching `prm_scopes` / `server_2_prm_scopes`
list, because the policy compares the token claim against the tfvars value
literally. These variables have no defaults and are supplied out of band exactly
like `allowed_client_application_ids`.

### Migration note (issue #17): existing clients need each server's entitlement

The per-server check (`scp` contains the server's scope OR `roles` contains its
app role) runs in the APIM server-scope inbound policy, so it gates EVERY request
to that server, including the MCP `initialize` handshake, and it runs BEFORE the
request reaches the backend. It is a NEW layer in front of the backend McpTools
app-role check (`Orders.Read`, issue #45), not a replacement for it. Consequence:
every client that legitimately calls a server must now hold that server's
entitlement in addition to whatever the backend requires. A token that carries
only `Orders.Read` (the backend role) but not server 1's `Orders.Invoke.All`
(the gateway role) is rejected at the gateway with `403 insufficient_scope`
before it can connect. The client grants in sections 2, 3, and 4 below reflect
this: they were written for the single-server v1 and are updated here for the
two-layer model.

## 2. Test client app (the gate's non-interactive caller)

A dedicated app for `McpTestClient` and the discovery-assertion scripts to
authenticate as, via client credentials. Kept separate from any interactive
user identity because the SDK's interactive auth-code flow cannot run in CI
(docs/specs/v1-tracer-bullet.md, Testing Decisions).

1. **App registrations > New registration.** Single tenant. No redirect URI.
2. **Certificates & secrets > Client secrets > New client secret.** Record
   the secret value immediately (it is shown once). Store it only as the
   GitHub Environment secret **`TEST_CLIENT_SECRET`** on `live-test` (the name
   `.github/workflows/ephemeral-env.yml`'s call stage reads); never in this
   repo or in Terraform state.
   ([Service Principal and a Client
   Secret](https://learn.microsoft.com/entra/identity-platform/quickstart-configure-app-access-web-apis))
3. **API permissions > Add a permission > My APIs**, select the server
   resource app from step 1, choose **Application permissions**, and select
   BOTH:
   - `Orders.Read` (the backend McpTools role, issue #45), and
   - server 1's gateway role `Orders.Invoke.All` (`required_role`, issue #17) so
     the token passes the per-server gateway check and can even connect. Without
     it the gateway 403s `initialize` before the backend is reached (see the
     migration note above).
   **Add permissions.**
4. **Grant admin consent for `<tenant>`.** Required: application permissions
   (app roles) cannot be self-consented; a tenant administrator must grant
   consent once before the client-credentials flow can obtain a token
   carrying the roles.
5. Record the **Application (client) ID**. This is
   `entra_validation.allowed_client_application_ids[0]` and the identity the
   gate's non-interactive token acquisition (client credentials) uses.

## 3. Negative-test client app (valid caller without Orders.Read)

A second confidential client proves that a valid server-audience token without
the BACKEND role (`Orders.Read`) reaches the MCP tool and receives the
deterministic tool-level 403. Under issue #17 this client must hold server 1's
GATEWAY role but not the backend role: it needs `Orders.Invoke.All` so it passes
the gateway per-server check and actually reaches the backend, and it must NOT
have `Orders.Read` so the backend McpTools check is the thing that rejects it. If
it lacked `Orders.Invoke.All`, the gateway would 403 it first and the test would
no longer prove the backend layer (see the migration note above).

1. **App registrations > New registration.** Single tenant. No redirect URI.
2. **Certificates & secrets > Client secrets > New client secret.** Store the
   client id as the GitHub Environment secret
   **`TEST_CLIENT_WITHOUT_ROLE_ID`** and the secret value as
   **`TEST_CLIENT_WITHOUT_ROLE_SECRET`** on `live-test`.
3. **API permissions > Add a permission > My APIs**, select the server resource
   app, choose **Application permissions**, select server 1's gateway role
   `Orders.Invoke.All` (`required_role`), **Add permissions**, then **Grant admin
   consent for `<tenant>`**. Do NOT add `Orders.Read`: the backend role's absence
   is precisely what this client tests. (The gateway role lets it connect and
   call the tool; the backend then returns the deterministic 403 for the missing
   `Orders.Read`.)
4. Add this client id to `entra_validation.allowed_client_application_ids` so
   the APIM policy admits it to the backend. The positive test client remains
   the first entry because the workflow reads index 0 for its ordinary call.

## 3a. Cross-server negative-test client (entitled to server 1 only)

A confidential client that proves grant-level cross-server isolation for the
multi-server composition (issue #17): it is granted ONLY server 1's entitlement
and deliberately NOT server 2's, so a valid server-audience token it acquires is
ACCEPTED at server 1 and REJECTED at server 2 with `403 insufficient_scope`.
This mirrors section 3 (a deliberately under-entitled client) but for the
cross-server case: section 3 proves a valid-audience token carrying no role is
rejected; this proves a valid-audience token carrying one server's entitlement
is rejected at the other server.

1. **App registrations > New registration.** Single tenant. No redirect URI.
2. **Certificates & secrets > Client secrets > New client secret.** Store the
   client id as the GitHub Environment secret **`TEST_CLIENT_SERVER1_ONLY_ID`**
   and the secret value as **`TEST_CLIENT_SERVER1_ONLY_SECRET`** on `live-test`;
   never in this repo or in Terraform state.
3. **API permissions > Add a permission > My APIs**, select the server resource
   app from section 1, choose **Application permissions**, select server 1's app
   role (`required_role`, e.g. `Orders.Invoke.All`), **Add
   permissions**, then **Grant admin consent for `<tenant>`**. Do NOT add
   server 2's app role or scope. (Consenting server 1's delegated scope
   (`required_scope`) instead of, or in addition to, the app role also
   satisfies server 1's OR-semantics check; the invariant is that this client
   receives server 1's entitlement and nothing for server 2.)
4. Add this client id to `entra_validation.allowed_client_application_ids` so
   the APIM policy admits it to the backend on both server paths. Admission to
   the backend is the `azp`/audience gate only; the per-server scope-or-role
   check is what then accepts the token at server 1 and returns
   `403 insufficient_scope` at server 2. Without this entry the token is
   rejected at the gateway before the per-server check runs, which would not
   prove the grant-level isolation.

The gate asserts this isolation at the GATEWAY layer: server 2 returns the
gateway's own `insufficient_scope` 403 and server 1 does not (the gate
distinguishes the gateway 403 by its `insufficient_scope` challenge from any
downstream backend 403). So this client does not also need the backend
`Orders.Read` role for the isolation proof to hold; granting it as well simply
makes server 1 return a clean 200 rather than a backend 403, which reads more
clearly in the gate log.

## 4. Interactive client app (the demo's interactive caller)

A dedicated public client for the interactive discovery walkthrough
(`docs/demos/README.md`): a human signing in through the VS Code MCP client or
MCP Inspector via OAuth 2.1 auth-code + PKCE. Kept separate from the
client-credentials test app in section 2 (that app is confidential and holds an
application permission, not a delegated one). Entra does not support Dynamic
Client Registration, so this client is pre-registered here and its id is supplied
to the interactive host manually (ADR-006).

1. **App registrations > New registration.** Single tenant. Name e.g.
   `mcp-tracer-vscode-client`.
2. **Authentication > Add a platform > Mobile and desktop applications**, and add
   the redirect URIs the interactive host asks for. VS Code's MCP client uses a
   loopback URI plus the hosted redirect, e.g. `http://127.0.0.1:33418` and
   `https://vscode.dev/redirect` (VS Code prints the exact URIs to register in its
   sign-in prompt; the loopback port can vary by client/version, so copy them from
   the prompt). Set **Allow public client flows = Yes** (PKCE, no secret).
   ([Redirect URI restrictions](https://learn.microsoft.com/entra/identity-platform/reply-url))
3. **API permissions > Add a permission > My APIs**, select the server resource
   app from section 1, choose **Delegated permissions**, select
   `user_impersonation` and, to reach server 1 through the issue-#17 gateway
   check, server 1's delegated scope `Orders.Invoke` (`required_scope`; a
   delegated token carries it in `scp`, which satisfies the per-server check).
   **Add permissions**, then **Grant admin consent for `<tenant>`** (or let each
   user consent at first sign-in if the scope allows it). To reach server 2 as
   well, also add `Catalog.Invoke` (`server_2_required_scope`).
4. Record the **Application (client) ID**. This id MUST be added to
   `entra_validation.allowed_client_application_ids` (the `S2_TFVARS_JSON`
   live-test secret): the APIM `validate-azure-ad-token` policy checks the token's
   client app id (`azp`) against that list, so a token acquired by this client is
   rejected at the gateway until its id is present and the gate is re-applied. The
   id is what you paste into the interactive host's manual client-registration
   prompt.

## Values this runbook produces, and where they are consumed

| Value | Consumed by |
|---|---|
| Server app's App ID URI (`api://<server-app-id>`) | `entra_auth.allowed_audiences`, `entra_validation.audience`, `prm_scope`/`prm_scopes` prefix |
| Server app's client id | `entra_auth.server_app_client_id` |
| Server/test client shared tenant id | `entra_auth.tenant_id`, `entra_validation.tenant_id` |
| Server app's per-server delegated scopes (short names carried in `scp`) | `required_scope` (server 1), `server_2_required_scope`; the `api://<server-app-id>/<scope>` form of each goes in that server's `prm_scopes` / `server_2_prm_scopes` (each server's PRM `scopes_supported` advertises its own scope only) |
| Server app's per-server app roles (values carried in `roles`) | `required_role` (server 1), `server_2_required_role`; the app-only caller path for each server's OR-semantics policy check |
| Test client app's client id | `entra_validation.allowed_client_application_ids` (one entry in the list; the gate's non-interactive caller) |
| Test client app's client secret | The gate's non-interactive token acquisition (client credentials), stored as the GitHub Environment secret `TEST_CLIENT_SECRET` on `live-test`, never in Terraform state or this repo |
| Negative-test client app's client id | `entra_validation.allowed_client_application_ids` after the positive client; also stored as `TEST_CLIENT_WITHOUT_ROLE_ID` for its separate token acquisition |
| Negative-test client app's client secret | Stored as the GitHub Environment secret `TEST_CLIENT_WITHOUT_ROLE_SECRET` on `live-test`, never in Terraform state or this repo |
| Cross-server negative-test client id (server 1 only) | `entra_validation.allowed_client_application_ids` (an additional entry, admitted to the backend on both server paths); also stored as `TEST_CLIENT_SERVER1_ONLY_ID` for its separate token acquisition |
| Cross-server negative-test client secret | Stored as the GitHub Environment secret `TEST_CLIENT_SERVER1_ONLY_SECRET` on `live-test`, never in Terraform state or this repo |
| Interactive client app's client id | `entra_validation.allowed_client_application_ids` (an additional entry in the same list, so APIM accepts interactive-user tokens acquired by it); also pasted into the interactive host's manual client-registration prompt. The list already loops in the APIM policy, so adding it is a value change in `S2_TFVARS_JSON`, not a code change |

None of these values have a default in the s1/s2 composition variables; the
live-test workflow supplies them all as `TF_VAR_*` environment variables
sourced from the `live-test` GitHub Environment's variables/secrets.
