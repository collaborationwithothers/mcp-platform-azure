# ADR-011: Public access to platform tooling (Argo CD) via a dedicated Istio external ingress gateway

Status: Proposed (2026-08-18; Terraform and config land in issue #121, live
proof is a later gated run, see Consequences)
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
- **TLS.** cert-manager issuing a Let's Encrypt certificate over HTTP-01, written
  into the Kubernetes TLS secret the Gateway references by `credentialName`.
  HTTP-01 needs no Cloudflare API token in the cluster.
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
  credential, recorded as a Hard-safety carve-out in AGENTS.md.
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

To add during issue #121 implementation: the Microsoft Learn links used
(istio-deploy-ingress and its ingress service customizations section are the
load-bearing ones), and the Argo CD OIDC and RBAC documentation.
