# ADR-011: Public access to platform tooling (Argo CD) via a dedicated Istio external ingress gateway

Status: Proposed (2026-08-18; Terraform and config land in issue #121, live
proof is a later gated run, see Consequences). Amended 2026-08-18 during #121
implementation: the TLS challenge is DNS-01, not HTTP-01, because HTTP-01 is not
feasible on this cluster (see "TLS: the challenge type changed" below).
Date: 2026-08-18

## Context

Issue #110 built Argo CD inside the AKS cluster reachable only through the
Istio internal ingress gateway: no public IP, no DNS name, no single sign-on.
That was a deliberate boundary. The #110 carve-out opened only the private
APIM-to-backend path; it never opened public access to anything new.

Hari needs to show the Argo CD UI live in a demo, to a handful of named people,
on machines that hold no cluster credentials. That last constraint is the whole
decision. Port-forwarding and an overlay VPN both need credentials or client
software on the viewing device, so neither can serve a credential-less demo
machine. A real public entry point is required.

This forces a question ADR-001 does not answer. ADR-001's "all client traffic
terminates at APIM, the backend is never exposed directly" principle is scoped,
in its own Acceptance section, to MCP client traffic. Argo CD is neither MCP
traffic nor an MCP backend. It is platform tooling, and it is a GitOps control
plane: if compromised, it can push manifests the cluster applies automatically.
So its exposure needs its own decision and its own recorded security rationale,
not a silent extension of ADR-001.

## Decision

Argo CD is exposed through a dedicated public entry point, separate from the
APIM MCP path.

- **Path.** A dedicated public AKS Istio *external* ingress gateway
  (`aks-istio-ingressgateway-external`), the add-on-managed gateway component,
  not the Kubernetes Gateway API automated-deployment model that #110 rejected.
  It lives alongside the internal gateway #110 pinned.
- **Address.** `argocd.consultwithcloud.com`, a Cloudflare DNS-only (grey-cloud)
  A record, managed by the cloudflare Terraform provider, pointing at a pinned
  Standard static public IP. The IP is pinned with the
  `service.beta.kubernetes.io/azure-pip-name` annotation, the same annotation
  family #110 used to pin the internal gateway's private IP, so it survives the
  `az aks stop`/`start` idle cycle.
- **TLS.** cert-manager issuing a Let's Encrypt certificate, written into the
  Kubernetes TLS secret in namespace `aks-istio-ingress` that the Gateway
  references by `credentialName` (the add-on resolves credential secrets from the
  gateway proxy's own namespace). The ACME challenge is DNS-01 via Cloudflare,
  not the HTTP-01 this ADR first proposed; see "TLS: the challenge type changed"
  below.
- **Authentication client model.** Argo CD is configured as a public OIDC client
  using PKCE (`enablePKCEAuthentication`), so the login needs no client secret at
  all. This is deliberate: AGENTS.md permits exactly one non-OIDC credential in
  this repo (the Cloudflare token), so a static Entra client secret is not
  allowed. PKCE keeps the credential model clean.
- **Authentication.** A dedicated Entra app registration, separate from the MCP
  server's. Argo CD OIDC. The named people are invited as Entra B2B guests.
- **Authorization.** Every guest is pinned to read-only via `argocd-rbac-cm`.
  Hari is the only admin. Argo CD's local `admin` account is disabled; access is
  SSO-only.
- **Security posture.** Entra SSO plus read-only RBAC is the sole gate. No WAF,
  no IP allowlist. This is accepted because the audience is read-only and the
  login is a real identity provider.
- **Exposure surface.** Both the UI and the `argocd` CLI's gRPC API are served on
  the one 443 endpoint. They are not separated, because the server serves both on
  the same port and read-only RBAC bounds them equally.

ADR-001 is not extended. It stays scoped to MCP client traffic. Platform tooling
gets its own public ingress, governed by this ADR.

## TLS: the challenge type changed (2026-08-18)

This ADR first specified HTTP-01, arguing it needs no Cloudflare API token in the
cluster. Implementing #121 showed HTTP-01 is not feasible on this cluster, so the
challenge is DNS-01 via Cloudflare instead. The certificate, the issuer
(Let's Encrypt), cert-manager, and the TLS secret the Gateway consumes are all
unchanged; only the proof-of-control method changed.

Why HTTP-01 does not work here: cert-manager's HTTP-01 solver routes the ACME
challenge through either an ingress controller or the Kubernetes Gateway API.
This cluster has neither. Ingress is Istio's own Gateway/VirtualService API, and
ADR-010 deliberately disabled the Kubernetes Gateway API to avoid a second,
unpinned gateway. So an HTTP-01 solver has nothing to route the challenge
through. DNS-01 sidesteps routing entirely: cert-manager proves control by
writing a TXT record through the Cloudflare API.

The cost of the change: the Cloudflare token now also lives in the cluster, as a
cert-manager secret in the `cert-manager` namespace, not only as a Terraform
variable. It is the same token, from the same live-test environment secret, still
never committed. This widens where the one permitted non-OIDC credential is used,
which is a governance-sensitive point for Hari to weigh at review. The rejected
alternative that would have kept the token out of the cluster is the Terraform
`acme` provider (issue the certificate in Terraform, which already holds the
token, and write it to a Kubernetes secret): rejected because it drops
cert-manager, the component this ADR names, loses in-cluster auto-renewal, and
introduces Terraform management of Kubernetes objects, a precedent this repo
deliberately avoids. Keeping cert-manager with DNS-01 is the smaller deviation
from this ADR's actual decision, which centres on cert-manager, not on the
challenge type.

## Alternatives considered

- **APIM passthrough.** Route Argo CD through the APIM gateway that is already
  public. Rejected: APIM is built for API and MCP traffic, and fronting a full
  websocket and gRPC-Web dashboard through it muddies ADR-001's clean MCP story
  for no benefit here.
- **Cloudflare Tunnel (no Azure inbound at all).** Run `cloudflared` as an
  outbound-only pod, so no public IP or inbound port opens on Azure. This is
  operationally the smallest attack surface and the cheapest option, and it
  answers the GitOps-blast-radius worry by having no inbound door. Rejected as a
  deliberate trade: it hides the exposure behind a non-Azure component in a repo
  whose whole purpose is demonstrating Azure-native enterprise patterns. The
  portfolio narrative wins here over minimal surface.
- **Azure Front Door plus WAF.** Rejected: extra cost, and reaching the internal
  backend needs Front Door's pricier Private Link origin tier. Overkill for a
  handful of read-only guests.
- **Stay internal-only, remove the friction another way.** A scripted
  port-forward (`argocd login --port-forward`) or an overlay VPN such as
  Tailscale removes the friction of reaching Argo CD from Hari's own machine for
  free. Rejected as the answer to *this* ticket: neither can serve a
  credential-less demo machine, which is the actual requirement. They remain the
  right answer to the narrower "reach it from my own machine" problem.

## Consequences

- A new public attack surface on a GitOps control plane, reachable 24/7.
  Mitigated by read-only RBAC, SSO-only access, and a disabled local admin
  account. Residual risk: an Argo CD CVE or a phished guest session is
  internet-reachable. Accepted, given the read-only posture and that only Hari
  can write to the control plane.
- A new external dependency: Cloudflare DNS for `consultwithcloud.com`. Because
  the record is Terraform-managed, the cloudflare provider needs a Cloudflare API
  token. That token is not Azure OIDC; it is stored only as a live-test
  environment secret in GitHub Actions and injected as a Terraform variable at
  apply time, never committed. This is the repo's one permitted non-OIDC
  credential, recorded as a Hard-safety carve-out in AGENTS.md. The DNS-01 change
  above widens its use: the same token is also created as a cert-manager secret
  in the cluster's `cert-manager` namespace, still from the same live-test secret
  and never committed. The AGENTS.md carve-out text describes the token only as a
  Terraform variable; whether that wording should be broadened to name the
  cert-manager use is Hari's call, since the GOVERNANCE section is his to edit.
- Standing maintenance: an Istio minor revision upgrade creates a second external
  gateway deployment per revision, the same obligation #110 already recorded for
  the internal gateway.
- Cost: one Standard static public IP, a small hourly charge. This is an estimate
  until the first live run measures it; the Cloudflare record and the Let's
  Encrypt certificate are free.
- This ADR is Proposed until issue #121's live gate proves the path end to end,
  at which point it flips to Accepted in that PR, the pattern ADR-001 followed.
- The topology changes, so a target-state diagram showing the second public
  ingress lands with issue #121, not here. Per the repo Diagrams rule, that
  ticket is not complete until the human SVG export lands.

## References

Verified during #121 implementation (2026-08-18), not recalled from training data.

Azure (Microsoft Learn):
- Deploy ingress gateways for the Istio add-on (external gateway name, mode, and
  the `az aks mesh enable-ingress-gateway --ingress-gateway-type external`
  command; the Gateway `selector: istio: aks-istio-ingressgateway-external`):
  https://learn.microsoft.com/azure/aks/istio-deploy-ingress
- Secure ingress gateway for the Istio add-on (TLS Gateway `credentialName`
  resolves from the `aks-istio-ingress` namespace):
  https://learn.microsoft.com/azure/aks/istio-secure-gateway
- Static IP pinning via `service.beta.kubernetes.io/azure-pip-name` and
  `-load-balancer-resource-group`:
  https://learn.microsoft.com/azure/aks/static-ip
- `serviceMeshProfile` ingress gateways ARM shape (expressed here through the
  `avm-res-containerservice-managedcluster` module, so no azapi pin is added):
  https://learn.microsoft.com/azure/templates/microsoft.containerservice/managedclusters

Argo CD (stable docs):
- Microsoft Entra OIDC and PKCE (`enablePKCEAuthentication`, redirect URIs,
  the SPA/public-client registration):
  https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/microsoft/
- RBAC (`policy.default: role:readonly`, the built-in roles, `scopes`):
  https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/
- Disabling the local admin account (`admin.enabled: "false"`):
  https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/

cert-manager:
- DNS-01 Cloudflare solver (`apiTokenSecretRef`):
  https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/
- HTTP-01 solver requirements (ingress controller or Gateway API), the reason
  DNS-01 was chosen: https://cert-manager.io/docs/configuration/acme/http01/

## Live proof and the flip to Accepted

This ADR stays Proposed until the first successful `bootstrap` run of
`deploy-aks-platform.yml` from `main` proves the path end to end: the Cloudflare
record resolves, cert-manager issues the certificate, and
`https://argocd.consultwithcloud.com/healthz` returns 200 over the pinned public
IP. That run cannot happen from the #121 branch: the workflow's guard requires
`refs/heads/main`, and this repo forbids apply from an unmerged branch. So the
flip to Accepted is a post-merge step, recorded the way the #110 idle-cycle
measurement was (a dated COMPATIBILITY.md update citing the run id), not asserted
here.
