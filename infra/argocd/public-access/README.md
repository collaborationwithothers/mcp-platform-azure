# Argo CD public access manifests (issue 121, ADR-011)

These files make Argo CD reachable at `argocd.consultwithcloud.com` over the
AKS Istio **external** ingress gateway, authenticated by Microsoft Entra SSO
with every invited guest pinned read-only. They are the Kubernetes half of
issue 121; the Azure half (the pinned public IP and the Cloudflare A record)
lives in Terraform under `infra/terraform/scenarios/s1-aks-platform`.

## Why these live here and not in Terraform

This repo draws a hard line: Terraform stops at the Azure boundary, and
Kubernetes objects are applied by the deploy workflow. The internal gateway
already follows this split (Terraform enables the gateway; the workflow pins its
IP). These manifests keep to the same rule. They sit next to
`bootstrap-app-of-apps.yaml` because both are platform-bootstrap manifests the
`deploy-aks-platform.yml` workflow applies directly, distinct from the
application workloads Argo CD reconciles from the separate manifests repo.

## Files

- `cluster-issuer.yaml` - a cert-manager ClusterIssuer that gets a Let's Encrypt
  certificate by proving domain control through a DNS-01 challenge, using the
  Cloudflare API token. DNS-01, not the HTTP-01 that ADR-011 first proposed:
  this cluster has no ingress controller and no Kubernetes Gateway API (ADR-010
  disabled it), so cert-manager's HTTP-01 solver has nothing to route the
  challenge through. DNS-01 needs no routing. See ADR-011's TLS section for the
  full reasoning and the token-in-cluster consequence.
- `certificate.yaml` - the Certificate resource. cert-manager writes the issued
  cert into the `argocd-tls` secret in the `aks-istio-ingress` namespace, which
  is where the Istio external gateway reads its `credentialName` secrets from.
- `gateway.yaml` - the Istio Gateway. Terminates TLS on port 443 with the
  `argocd-tls` secret and redirects port 80 to 443. Its selector targets the
  external gateway pods (`istio: aks-istio-ingressgateway-external`).
- `virtualservice.yaml` - routes the hostname to the `argocd-server` Service.
- `argocd-server-values.yaml` - Helm values layered onto the existing Argo CD
  chart install: Entra OIDC authenticated by Azure workload identity (a federated
  managed identity, so no client secret), read-only-by-default RBAC with admin
  granted by membership of one Entra group, the local admin account disabled, and
  `server.insecure` so Argo CD serves plain HTTP behind the TLS-terminating
  gateway. It also labels the argocd-server pod and annotates its ServiceAccount
  for the AKS workload-identity webhook; the matching federated identity
  credential on the Entra app is Terraform-managed in s1-aks-platform.

## Placeholders

Every file is an `envsubst` template. The deploy workflow renders it with these
variables before `kubectl apply` / `helm upgrade`, so no tenant id, account
email, or secret is ever committed:

| Placeholder | Source | Secret? |
| --- | --- | --- |
| `${ARGOCD_HOSTNAME}` | `vars.ARGOCD_HOSTNAME` (argocd.consultwithcloud.com) | no |
| `${ACME_EMAIL}` | `vars.ARGOCD_ACME_EMAIL` (Let's Encrypt account email) | no |
| `${AZURE_TENANT_ID}` | `vars.AZURE_TENANT_ID` | no (but account-specific; never committed) |
| `${ARGOCD_OIDC_CLIENT_ID}` | `vars.ARGOCD_OIDC_CLIENT_ID` (the Argo CD Entra app) | no |
| `${ARGOCD_ADMIN_GROUP}` | `vars.ARGOCD_ADMIN_GROUP` (Entra admin group object id; its members get admin) | no |

The one secret in the path, the Cloudflare API token, never appears in these
files: the workflow creates it as a Kubernetes secret directly from
`secrets.CLOUDFLARE_API_TOKEN`. See `docs/runbooks/argocd-public-access.md` for
what Hari provisions out of band.
