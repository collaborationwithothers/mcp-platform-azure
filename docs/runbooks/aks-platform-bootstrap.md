# Runbook: AKS platform bootstrap and idle cycle

Out-of-band setup and operating procedure for `.github/workflows/deploy-aks-platform.yml`
(epic 108 child (b1), issue #110). Unlike `ephemeral-env.yml`, this workflow
manages a PERSISTENT platform: a stable resource group, cluster, and
registry that are stopped and started, never destroyed by this workflow.
Read [ADR-010](../decisions/ADR-010:%20Compute-plane%20re-platform%20to%20AKS.md)
first for why this platform's lifecycle differs from S1/S2's
apply-call-destroy pattern.

## 1. GitHub Environment variables this workflow needs

All on the existing `live-test` GitHub Environment (**Settings > Environments
> live-test > Environment variables**), alongside the variables
`ephemeral-env.yml` already reads (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`, `LIVE_TEST_LOCATION`, `TF_STATE_STORAGE_ACCOUNT`,
`TF_STATE_CONTAINER`). This workflow reuses that same environment and its
existing OIDC federated credential rather than a second one; see ADR-010 for
why.

| Variable | Value | Notes |
|---|---|---|
| `AKS_PLATFORM_RESOURCE_GROUP` | e.g. `rg-mcp-aks-platform` | Stable, non-ephemeral. Must NOT carry the `expires-after` tag the ephemeral cleanup sweep looks for, and must be a DIFFERENT group from any `rg-mcp-tracer-<run id>` group `ephemeral-env.yml` creates. |
| `AKS_PLATFORM_CLUSTER_NAME` | e.g. `aks-mcp-platform` | Passed to `mcp-aks-host` as `cluster_name`. |
| `AKS_PLATFORM_REGISTRY_NAME` | e.g. `acrmcpplatform` | Globally unique, alphanumeric only (ACR naming rule). |
| `AKS_PLATFORM_RUNNER_VNET_ID` | the existing GitHub Actions VNet runner network's ARM resource ID | Non-secret (a resource ID, not a credential) but never committed to this repo -- it embeds a real subscription ID, which AGENTS.md's hard safety rules forbid committing. Ask whoever manages that runner network for the exact value. |
| `AKS_PLATFORM_INGRESS_PRIVATE_IP` | an address inside the ingress subnet, see step 2 | Pinned once; changing it after the first bootstrap re-pins a live load balancer. |

## 2. Choosing the ingress gateway's private IP

`private-network`'s ingress subnet defaults to `10.20.2.0/28` (16 addresses;
see `infra/terraform/modules/private-network/README.md` for the full
address plan). Azure reserves the first four addresses in any subnet
(`.0`-`.3`), so the first usable address is `10.20.2.4`. Pick any address
from `10.20.2.4` through `10.20.2.14` (`.15` is the subnet's broadcast
address) that is not already in use; `10.20.2.4` is a reasonable default if
this is the first bootstrap. `terraform validate` and `terraform plan` both
reject a value outside the subnet -- see `private-network/variables.tf`'s
`ingress_gateway_private_ip` validation.

If you changed `ingress_gateway_subnet_cidr` from its default, recompute the
usable range accordingly before choosing an address.

## 3. Running bootstrap

From the repository's **Actions** tab, run **Deploy AKS platform**,
`action: bootstrap`, and type `bootstrap` into the confirmation input. This:

1. Ensures the platform resource group exists.
2. Runs `terraform apply` for `infra/terraform/scenarios/s1-aks-platform`
   (creates or updates the VNet, AKS cluster, registry, and the placeholder
   workload's user-assigned identity -- idempotent on re-run).
3. Pins the Istio internal ingress gateway's load balancer to the chosen
   private IP and the dedicated ingress subnet.
4. Installs the pinned `argo-cd` Helm chart and applies the app-of-apps
   (`infra/argocd/bootstrap-app-of-apps.yaml`), which points Argo CD at the
   separate `mcp-platform-kubernetes-manifests` repository.
5. Prints readiness: Argo CD `Application` sync status and the Istio
   ingress pods.

Argo CD then reconciles the placeholder workload asynchronously; check
`kubectl get applications -n argocd` (via `az aks get-credentials` +
`kubelogin`) if it does not show `Synced`/`Healthy` shortly after.

## 4. Pushing the placeholder image

Run **Build AKS placeholder image** (`.github/workflows/build-aks-placeholder-image.yml`)
separately -- it is not part of bootstrap. It pushes a small, pinned public
image into the registry this composition created, tagged by git commit SHA.
Update the manifests repository's Deployment with the printed image
reference if the tag is not resolved automatically.

## 5. Idling the cluster

`action: idle-stop` runs `az aks stop`. Wait 15 to 30 minutes (Microsoft
Learn's documented settle window; no tighter SLA is published) before
running `action: idle-start` (`az aks start`) -- this workflow does not wait
for you, deliberately: an automatic wait would turn a documented settle
requirement into something silently masked, not enforced. Running
`idle-start` too soon after `idle-stop` fails; if it does, wait longer and
retry.

## 6. Recording the first live measurement

Issue #110's acceptance criteria require the FIRST stop/start cycle's
measured behaviour recorded in COMPATIBILITY.md: whether the Istio add-on's
configuration survived, whether the pinned ingress IP survived, what
actually billed while stopped (Microsoft Learn's own pages disagree with
each other on this; do not repeat a blanket claim either way), the run ID,
and the date. Update the "AKS `az aks stop`/`az aks start` billing during
idle" row in COMPATIBILITY.md directly; do not leave it UNMEASURED once a
real cycle has run.

## Values this runbook produces, and where they are consumed

| Value | Consumed by |
|---|---|
| `AKS_PLATFORM_RESOURCE_GROUP`, `AKS_PLATFORM_CLUSTER_NAME`, `AKS_PLATFORM_REGISTRY_NAME` | `deploy-aks-platform.yml`'s `TF_VAR_*` env vars, `s1-aks-platform`'s `resource_group_name`/`cluster_name`/`registry_name` inputs |
| `AKS_PLATFORM_RUNNER_VNET_ID` | `TF_VAR_runner_vnet_id`, `private-network`'s spoke-to-runner peering link |
| `AKS_PLATFORM_INGRESS_PRIVATE_IP` | `TF_VAR_ingress_gateway_private_ip`, `private-network`'s subnet-containment validation and the Istio ingress gateway's Service annotation |

None of these values are secrets (no key, connection string, or credential
among them), but `AKS_PLATFORM_RUNNER_VNET_ID` is still never committed to
this repository, because it is an ARM resource ID and embeds a real
subscription ID.
