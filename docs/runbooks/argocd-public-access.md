# Runbook: Argo CD public access setup

Out-of-band setup for the public Argo CD entry point (issue #121, ADR-011). The
deploy workflow builds the Azure and Kubernetes pieces; this runbook covers the
things a workflow cannot create for itself: a Cloudflare zone and token, an Entra
app registration, guest invites, and the GitHub Environment variables that feed
them in. Read [ADR-011](../decisions/ADR-011:%20Public%20access%20to%20platform%20tooling%20via%20a%20dedicated%20Istio%20external%20ingress%20gateway.md)
first for why Argo CD gets its own public gateway separate from the MCP path.

Everything here is Hari's to do once, before the first `bootstrap` run that
includes the #121 change. The deploy workflow (`deploy-aks-platform.yml`) reads
these values from the existing `live-test` GitHub Environment.

## What gets built, in one paragraph

Argo CD is reachable at `https://argocd.consultwithcloud.com`. A Cloudflare
DNS-only A record points that name at a pinned Azure Standard public IP. That IP
fronts a dedicated AKS Istio external ingress gateway, which terminates TLS with
a Let's Encrypt certificate cert-manager obtains over a DNS-01 challenge. Behind
the gateway, Argo CD authenticates every visitor with Microsoft Entra SSO and
pins each one to read-only; only Hari is admin, and the local admin password is
disabled.

## 1. Cloudflare: token and zone id

Hari owns `consultwithcloud.com` on Cloudflare. The cloudflare Terraform provider
and cert-manager both need a token scoped to edit DNS in that zone.

1. In the Cloudflare dashboard, open **My Profile > API Tokens > Create Token**.
2. Use the **Edit zone DNS** template.
3. Scope **Zone Resources** to the single zone `consultwithcloud.com`.
4. Create the token and copy its value once; Cloudflare shows it only at creation.
5. On the Cloudflare **Overview** page for `consultwithcloud.com`, copy the
   **Zone ID**.

The token is a secret. The zone id is not a secret, but it is account-specific,
so it is never committed to the repo either.

## 2. Entra: the Argo CD app registration

Argo CD logs users in as a **public OIDC client using PKCE**, so this app
registration has **no client secret**. That is deliberate: the repo permits
exactly one non-OIDC credential (the Cloudflare token), so a static client
secret is not allowed.

1. In the Microsoft Entra admin center, open **App registrations > New
   registration**.
2. Name it, for example, `argocd-mcp-platform`.
3. Under **Redirect URI**, choose platform **Single-page application (SPA)** and
   enter `https://argocd.consultwithcloud.com/auth/callback`. The SPA platform is
   what makes Entra enforce PKCE without a client secret.
4. Register the app, then copy the **Application (client) ID**.
5. To let the `argocd` CLI log in too, open **Authentication > Add a platform >
   Mobile and desktop applications** and add the redirect URI
   `http://localhost:8085/auth/callback`. This URI is fixed; do not change it.
6. Open **API permissions**, add **Microsoft Graph > Delegated > User.Read**, and
   grant it.
7. Optional, only if you later switch RBAC from email to group mapping: open
   **Token configuration > Add groups claim** and include groups in the ID token.
   The default RBAC in this repo maps admin by email, so this is not required now.

Do not create a client secret. If one exists from an earlier attempt, delete it;
PKCE does not use it, and leaving it around invites the wrong login mode.

## 3. Entra: invite the guests

The audience is a handful of named people, invited as B2B guests. Each one logs
in and lands read-only automatically; no per-guest Argo CD config is needed.

1. In the Entra admin center, open **Users > New user > Invite external user**.
2. Enter each guest's email and send the invitation.
3. Tell each guest to accept the invitation before the demo; first-time consent
   otherwise happens live.

Only Hari is admin. His login email is mapped to `role:admin` through the
`ARGOCD_ADMIN_EMAIL` variable below; everyone else falls to the read-only
default.

## 4. GitHub Environment: variables and the one secret

All on the existing `live-test` Environment (**Settings > Environments >
live-test**), alongside the variables the AKS bootstrap already reads
(`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, and the rest in
[aks-platform-bootstrap.md](./aks-platform-bootstrap.md)).

Add these **Environment variables** (not secrets; none is a credential):

| Variable | Value | Notes |
|---|---|---|
| `ARGOCD_HOSTNAME` | `argocd.consultwithcloud.com` | The public name. ADR-011 fixes it; a variable so the workflow reads it in one place. |
| `CLOUDFLARE_ZONE_ID` | the zone id from step 1 | Account-specific, never committed. |
| `ARGOCD_ACME_EMAIL` | Hari's email for the Let's Encrypt account | Where expiry warnings go. |
| `ARGOCD_OIDC_CLIENT_ID` | the app client id from step 2 | A client id is a public identifier, not a secret. |
| `ARGOCD_ADMIN_EMAIL` | Hari's login email | Mapped to `role:admin`; everyone else is read-only. |

Add this **Environment secret** (masked in logs):

| Secret | Value |
|---|---|
| `CLOUDFLARE_API_TOKEN` | the token from step 1 |

This token is the repo's one permitted non-OIDC credential (AGENTS.md
Hard-safety carve-out). The workflow passes it to Terraform for the DNS record
and creates it as a cert-manager Kubernetes secret for the DNS-01 challenge. It
is never committed.

## 5. Run the bootstrap and check the result

1. Confirm every value in step 4 is set on the `live-test` Environment.
2. Trigger **Deploy AKS platform** with `action = bootstrap` and `confirm =
   bootstrap`, from `main` (the workflow's guard requires `main`).
3. Watch the run. The "Verify the public Argo CD endpoint" step is the gate: it
   waits for cert-manager to issue the certificate, then checks that
   `https://argocd.consultwithcloud.com/healthz` returns 200 over the public path.
4. If the certificate step times out, read its diagnostics in the log
   (`kubectl describe certificate/argocd-tls -n aks-istio-ingress` and the
   challenges/orders dump). The usual cause is a Cloudflare token that lacks DNS
   edit on the zone, or a wrong zone id.
5. When the run is green, open `https://argocd.consultwithcloud.com` in a browser
   with no cluster credentials, confirm it redirects to Microsoft sign-in, log in
   as a guest, and confirm the UI is read-only.
6. Record the successful run id in COMPATIBILITY.md and flip ADR-011 from
   Proposed to Accepted, the same way the #110 idle-cycle measurement was
   recorded.

## Rollback

To remove the public entry point, revert the #121 change and re-run `bootstrap`:
Terraform deletes the Cloudflare record and the public IP, and the external
gateway is dropped from the mesh profile. The Entra app registration and the
guest invitations are Entra objects this workflow never created, so delete them
by hand in the Entra admin center if you want them gone.
