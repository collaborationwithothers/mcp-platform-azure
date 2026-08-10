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

## Display names (2026-08-09)

Every app registration below gets a fixed display name: `mcp-tracer-` plus a
suffix derived from the secret name it corresponds to. The point is to make
the Entra admin center's app-registration list self-explanatory during
troubleshooting -- no translation needed between "which secret" and "which
row in the portal". Each section's step 1 below states its display name; this
table is the single-page lookup.

| Section | Purpose | Corresponding secret(s) | Display name |
|---|---|---|---|
| 1 | Server resource app | `entra_auth.server_app_client_id` | `mcp-tracer-server` |
| 2 | Positive test client (entitled) | `TEST_CLIENT_SECRET` | `mcp-tracer-test-client` |
| 3 | Negative-test client (no `Orders.Read`) | `TEST_CLIENT_WITHOUT_ROLE_ID`/`_SECRET` | `mcp-tracer-test-client-without-role` |
| 3a | Cross-server negative-test client | `TEST_CLIENT_SERVER1_ONLY_ID`/`_SECRET` | `mcp-tracer-test-client-server1-only` |
| 3b | Cross-tool differentiation client | `TEST_CLIENT_MCP_SERVICE_TOOL_ID`/`_SECRET` | `mcp-tracer-test-client-service-tool` |
| 4 | Interactive demo client | manual, pasted into host | `mcp-tracer-vscode-client` |
| 4a | Delegated negative-test client (issue #83) | manual, pasted into host | `mcp-tracer-test-client-delegated-without-scope` |
| ([obo-app-registrations.md](obo-app-registrations.md) section 1) | Downstream Orders API identity | `downstream_app`/`downstream_entra_auth` | `mcp-tracer-downstream-orders-api` |

**Existing registrations predate this convention and need a manual rename.**
The server resource app (section 1) is currently named `mscp-server-app`;
rename it to `mcp-tracer-server` in the Entra admin center (Branding &
properties > Name). The other pre-existing registrations (sections 2, 3, 3a)
were never given a documented name at all; check their current display names
against this table and rename any that do not match. This runbook cannot
verify or perform the rename itself -- it needs directory-write privilege the
same as every other step here.

## 1. Server resource app (the MCP server's identity)

This is the app the Functions host (`entra_auth.server_app_client_id`) and
the APIM gateway (`entra_validation.audience`) both validate tokens against.

1. **App registrations > New registration.** Name `mcp-tracer-server`. Single
   tenant. No redirect URI needed (it is a web API, not an interactive
   client). ([Register an
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

1. **App registrations > New registration.** Name `mcp-tracer-test-client`.
   Single tenant. No redirect URI.
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
   **Add permissions.** Do NOT add `ServiceInfo.Read` (issue #79/#80). Section
   3b's check (e) asserts this client is DENIED `get_service_info`. Granting it
   `ServiceInfo.Read` inverts that check silently: a per-tool ALLOW and a
   per-tool DENY look identical in the app-registration UI, and only the deny
   assertion would catch the mistake.
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

1. **App registrations > New registration.** Name
   `mcp-tracer-test-client-without-role`. Single tenant. No redirect URI.
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

### Since issue #18: the gateway denies this client before the backend does

The Entra configuration above is CORRECT and UNCHANGED. What has changed since
issue #18 is which layer denies this client first, and therefore which endpoint
the live gate has to call to prove the backend layer.

The gateway's `tool_authorization_map` now gates `get_order_status` on the same
`Orders.Read` role the backend's `AppRoleAuthorization` check requires. That
sameness is deliberate (ADR-009, "Two enforcement layers must be kept in step
conceptually, not mechanically"), but it means this client is now under-entitled
at BOTH layers. When it calls through APIM it is denied at the GATEWAY, as a
JSON-RPC protocol error (`-32001`), one layer earlier than the backend check it
was created to exercise. The backend never sees the call.

So the introductory paragraph of this section, which explains that this client
holds `Orders.Invoke.All` because otherwise "the gateway would 403 it first and
the test would no longer prove the backend layer", and step 3's parenthetical
that "the gateway role lets it connect and call the tool", both now describe
only the pre-issue-18 path through the gateway. The gateway denies this client
first regardless of the `Orders.Invoke.All` grant, at the per-tool check rather
than the per-server one.

The live gate handles that by proving each layer through the path that actually
exercises it, and the two proofs are separate:

- **Backend layer** (`AppRoleAuthorization`, issue #45): `scripts/gate/invoke-and-assert.ps1`
  step [3] sets `$env:MCP_SERVER_ENDPOINT = $BackendMcpUrl` and calls the
  Functions host DIRECTLY, bypassing APIM, so the backend's own check is the
  thing that returns the deterministic tool-level 403. The same server-audience
  token is accepted by the backend regardless of the path it arrived by, which
  was checked on 2026-07-16 by probing the backend hostname directly and getting
  a 405, not a 401 (see the comment on step [3] and `mcp-server.xml`).
- **Gateway layer** (per-tool `tool_authorization_map`, issue #18):
  `tests/integration/discovery-assertions.ps1` check [9]-d
  (`Assert-ToolAuthorization`, the `UnderEntitledToken` branch) calls the tool
  through APIM with this same client's token and asserts the `-32001` denial.

**Do not remove the `Orders.Invoke.All` grant.** It is still required, for a
different reason than the one the introductory paragraph gives. Check [9]-d
needs this client to CLEAR the gateway's per-server check and then be denied at
the per-TOOL check. Without `Orders.Invoke.All` it would be denied at the
per-server check instead, and the per-tool layer would go unproven. The client
must still NOT have `Orders.Read`; that absence is what both proofs turn on.

**Since issue #82 the same grant is load-bearing a second time, in the opposite
direction.** Check [9]-h needs this client to clear the same per-server check
and then be ALLOWED by the per-tool check, because `get_access_guidance` is
mapped `unrestricted` rather than to a role. One grant, two checks, opposite
expected outcomes. That pairing is what makes the per-tool layer's behaviour
legible: in one run, against the same server and with the same token, this
client must be refused `get_order_status` and served `get_access_guidance`. A
layer that
denied both, or allowed both, would look the same as a broken one.

**Issue #82 required no new Entra object of any kind:** no app registration, no
client secret, no app role, no grant, and no new entry in
`entra_validation.allowed_client_application_ids`. It reuses this client exactly
as it already stands.

## 3a. Cross-server negative-test client (entitled to server 1 only)

A confidential client that proves grant-level cross-server isolation for the
multi-server composition (issue #17): it is granted ONLY server 1's entitlement
and deliberately NOT server 2's, so a valid server-audience token it acquires is
ACCEPTED at server 1 and REJECTED at server 2 with `403 insufficient_scope`.
This mirrors section 3 (a deliberately under-entitled client) but for the
cross-server case: section 3 proves a valid-audience token carrying no role is
rejected; this proves a valid-audience token carrying one server's entitlement
is rejected at the other server.

1. **App registrations > New registration.** Name
   `mcp-tracer-test-client-server1-only`. Single tenant. No redirect URI.
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

## 3b. Cross-tool differentiation client (entitled to get_service_info only)

A confidential client that proves per-tool authorization actually
differentiates between two tools on the SAME server, not merely between "has a
role" and "has no role" (issue #76's stated gap, closed by issue #80). It is
granted `ServiceInfo.Read`, the role `get_service_info` requires (issue #79),
and deliberately NOT `Orders.Read`, the role `get_order_status` requires. A
valid server-audience token from this client must then be ACCEPTED on
`get_service_info` and REJECTED on `get_order_status`, proving entitlement for
one tool does not carry over to the other. Section 3 proves the inverse
direction (a caller entitled for `get_order_status` is denied
`get_service_info`); together they close the matrix in both directions.

1. **App registrations > New registration.** Name
   `mcp-tracer-test-client-service-tool`. Single tenant. No redirect URI.
2. **Certificates & secrets > Client secrets > New client secret.** Store the
   client id as the GitHub Environment secret
   **`TEST_CLIENT_MCP_SERVICE_TOOL_ID`** and the secret value as
   **`TEST_CLIENT_MCP_SERVICE_TOOL_SECRET`** on `live-test`; never in this repo
   or in Terraform state.
3. **API permissions > Add a permission > My APIs**, select the server
   resource app from section 1, choose **Application permissions**, and select
   ALL THREE:
   - `Orders.Invoke.All` (server 1's `required_role`), so the token clears
     server 1's per-server entitlement check and reaches the per-tool gate at
     all.
   - `Catalog.Invoke.All` (server 2's `server_2_required_role`; the app role
     actually registered on the server app for server 2, confirmed against
     the live app registration -- see the correction note below), so the
     token also clears server 2's per-server check. Without this grant,
     server 2's per-tool checks (e)/(f)/(g) return UNDETERMINED rather than
     proving anything, because `Assert-ToolAuthorization` early-returns on a
     per-server rejection before any per-tool check runs.
   - `ServiceInfo.Read` (the backend McpTools role for `get_service_info`,
     issue #79).
   **Add permissions**, then **Grant admin consent for `<tenant>`**. Do NOT add
   `Orders.Read`. Its absence is what check (g) proves.
4. Add this client id to `entra_validation.allowed_client_application_ids` so
   the APIM policy admits it to the backend on both server paths (same reason
   as section 3a step 4: admission is the `azp`/audience gate only, and the
   per-server and per-tool checks then run on top of it).

**Correction (2026-08-09, issue #80):** an earlier draft of this section, and
of `docs/runbooks/live-test-tfvars-reference.md`'s `S2_TFVARS_JSON` example,
named server 2's app role as `Mcp.Orders2.Invoke` and its scope as
`mcp.orders2.invoke`. Neither string exists on the live server app
registration. Direct review of that app registration (App roles and Expose an
API blades, 2026-08-09) shows the role actually registered for server 2 is
`Catalog.Invoke.All`, matching this runbook's own section 1a illustrative
example almost verbatim -- the operator used the illustrative name as the real
one, and the stale draft never caught up. Both docs are corrected here to the
real value.

The gate asserts this at the PER-TOOL layer, in
`tests/integration/discovery-assertions.ps1`'s `Assert-ToolAuthorization`,
checks (e)/(f)/(g): (e) the entitled `get_order_status` caller (section 2's
client) is denied `get_service_info`; (f) this client succeeds on
`get_service_info`; (g) this client is denied `get_order_status`. All three
are skipped with a warning, never failed, when
`TEST_CLIENT_MCP_SERVICE_TOOL_ID`/`_SECRET` are unset.

## 4. Interactive client app (the demo's interactive caller)

A dedicated public client for the interactive discovery walkthrough
(`docs/demos/README.md`): a human signing in through the VS Code MCP client or
MCP Inspector via OAuth 2.1 auth-code + PKCE. Kept separate from the
client-credentials test app in section 2 (that app is confidential and holds an
application permission, not a delegated one). Entra does not support Dynamic
Client Registration, so this client is pre-registered here and its id is supplied
to the interactive host manually (ADR-006).

1. **App registrations > New registration.** Name `mcp-tracer-vscode-client`.
   Single tenant.
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

**Addition (issue #83): a per-tool delegated scope for `get_order_status`.**
`tool_authorization_map`'s `get_order_status` entry now also carries a delegated
scope, `Orders.Read.AsUser`, alongside its existing `Orders.Read` role (ADR-009,
"Widening `get_order_status`"). This client is the intended **positive-arm**
holder: on **Expose an API**, add a scope named `Orders.Read.AsUser` on the
server app (same blade as `Orders.Invoke`; note the naming trap below), then on
this client's **API permissions**, add it as a fourth delegated permission
alongside `user_impersonation`, `Orders.Invoke`, and `Catalog.Invoke`, and grant
admin consent. A token from this client, carrying both `Orders.Invoke` (clears
the per-server check) and `Orders.Read.AsUser` (clears the per-tool check),
should now succeed on `get_order_status` via the delegated branch.

**Naming trap, live-confirmed 2026-08-10.** The new scope's value cannot be
`Orders.Read`: attempting to add a scope literally named `Orders.Read` on this
same application, which already carries the app role `Orders.Read` (section 2
above; `AppRoleAuthorization.RequiredRole`), was refused by Entra with "Failed
to update undefined application property. Error detail: It contains duplicate
value. Please Provide unique value." (Expose an API blade, Add a scope). Not
documented on Microsoft Learn (governance review, 2026-08-10, UNVERIFIABLE via
two independent search passes) but directly observed against this
application, which this repo treats as sufficient evidence on its own terms --
see COMPATIBILITY.md. `Orders.Read.AsUser` therefore inverts this runbook's
usual `X.Y` scope / `X.Y.All` role convention, confirmed necessary rather than
merely deliberate. The convention-clean fix would be renaming the role
instead, which ADR-009 records as rejected for this ticket (too much surface
for what it buys here).

## 4a. Delegated negative-test client (holds Orders.Invoke only, issue #83)

A second public client, deliberately **not** given `Orders.Read.AsUser`, so the
issue-83 evidence is a matched pair rather than a single "it worked" anecdote: a
token from THIS client clears the per-server check (it holds `Orders.Invoke`)
and is refused `get_order_status` at the per-tool check; a token from section
4's client, holding both scopes, is accepted. Two tokens, one difference, one
outcome each.

A second app registration is required here, not a second delegated permission
on section 4's client. Verified against Microsoft Learn
(`resources-and-scopes`, "Consent lifetime"; `scopes-oidc`, "the `.default`
scope"; docs-verifier, 2026-08-10): once a client holds consent for two
delegated scopes on the same resource, Entra returns BOTH in `scp` on every
token for that resource, regardless of what the `scope=` request parameter
names. So a single client cannot produce a token that omits a scope it has
been consented for -- the only way to get an `Orders.Invoke`-only token is a
client that has never been granted `Orders.Read.AsUser` at all.

1. **App registrations > New registration.** Name
   `mcp-tracer-test-client-delegated-without-scope`. Single tenant.
2. **Authentication > Add a platform > Mobile and desktop applications**, add a
   loopback redirect URI (e.g. `http://localhost`; this client only ever runs
   the raw device-code flow below, never a browser redirect, but Entra
   requires a public-client platform to be present to allow public client
   flows). Set **Allow public client flows = Yes**.
3. **API permissions > Add a permission > My APIs**, select the server resource
   app from section 1, choose **Delegated permissions**, select ONLY server 1's
   delegated scope `Orders.Invoke` (`required_scope`). **Add permissions**, then
   **Grant admin consent for `<tenant>`**. Do NOT add `Orders.Read.AsUser`, and
   do not add `user_impersonation` or `Catalog.Invoke` either -- this client's
   entire purpose is holding the minimum needed to clear the per-server check
   and nothing more, so its absence at the per-tool check is unambiguous.
4. Record the **Application (client) ID** and add it to
   `entra_validation.allowed_client_application_ids` (the `S2_TFVARS_JSON`
   live-test secret), same reason as section 4 step 4: without it, the token is
   rejected at the gateway's client-id check before the per-server check this
   client exists to clear ever runs.

No GitHub Environment secret is created for this client, the same as section
4: it is never invoked by the automated gate, only by a human running the
device-code procedure in `docs/demos/obo-happy-path.md`.

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
| Cross-tool differentiation client id (`ServiceInfo.Read` only) | `entra_validation.allowed_client_application_ids` (an additional entry, admitted to the backend on both server paths); also stored as `TEST_CLIENT_MCP_SERVICE_TOOL_ID` for its separate token acquisition |
| Cross-tool differentiation client secret | Stored as the GitHub Environment secret `TEST_CLIENT_MCP_SERVICE_TOOL_SECRET` on `live-test`, never in Terraform state or this repo |
| Interactive client app's client id | `entra_validation.allowed_client_application_ids` (an additional entry in the same list, so APIM accepts interactive-user tokens acquired by it); also pasted into the interactive host's manual client-registration prompt. The list already loops in the APIM policy, so adding it is a value change in `S2_TFVARS_JSON`, not a code change |

None of these values have a default in the s1/s2 composition variables; the
live-test workflow supplies them all as `TF_VAR_*` environment variables
sourced from the `live-test` GitHub Environment's variables/secrets.
