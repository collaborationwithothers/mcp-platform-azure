# Runbook: AKS platform bootstrap and idle cycle

Out-of-band setup and operating procedure for `.github/workflows/deploy-aks-platform.yml`
(epic 108 platform bootstrap, issues #110, #121, and #149). Unlike
`ephemeral-env.yml`, this workflow
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

The workflow also reads the existing `S1_TFVARS_JSON` Environment secret. It
selects only `entra_auth.server_app_client_id` so Terraform can find the
existing MCP server application. Terraform reads that application's single App
ID URI for the resource-audience output. Do not create a second application
registration or derive the resource audience from the client ID.

## 2. GitHub App setup for image promotion

The image workflow sends a promotion request to the public manifests
repository. A GitHub App is a GitHub-managed automation identity with access
to selected repositories. It is needed because `GITHUB_TOKEN`, the temporary
token GitHub gives a workflow, cannot act outside the repository that created
it.

Hari creates and owns this App. Install it for only
`collaborationwithothers/mcp-platform-kubernetes-manifests`. Grant repository
Metadata read and Contents write. Contents write is enough to create the
`repository_dispatch` event, which starts a workflow in another repository.
The manifests workflow uses its own `GITHUB_TOKEN` to create the branch and
draft PR.

Add these values to the existing `live-test` GitHub Environment in this
repository:

| Setting | Value | Notes |
|---|---|---|
| Variable `GITOPS_PROMOTION_APP_CLIENT_ID` | The App Client ID | Identifier only. It is not a credential. |
| Secret `GITOPS_PROMOTION_APP_PRIVATE_KEY` | The App private key PEM | Keep it only in the GitHub Environment. Never commit it or copy it into a workflow input. |

The App is not installed in this repository. Its private key is available to
the protected image workflow solely so that workflow can request a short-lived
token for the selected manifests repository. The token is limited to the
repository and permission above, and the action revokes it when the job ends.

## 3. Choosing the ingress gateway's private IP

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

## 4. Running the read-only plan and bootstrap

From the repository's **Actions** tab, first run **Deploy AKS platform** with
`action: plan`, and type `plan` into the confirmation input. The workflow reads
the persistent S1 AKS state and fails if Terraform proposes any delete or
replacement action. The workflow does not upload the plan file because a plan
can contain sensitive values.

The S1 AKS state owns the placeholder and Argo CD platform resources, so this
plan proves their preservation. Functions and APIM use separate Terraform
states. Confirm their compositions are absent from the diff; this plan cannot
make a state assertion about them.

From the repository's **Actions** tab, run **Deploy AKS platform**,
`action: bootstrap`, and type `bootstrap` into the confirmation input. This:

1. Ensures the platform resource group exists.
2. Runs `terraform apply` for `infra/terraform/scenarios/s1-aks-platform`.
   Terraform adds the MCP workload identity and both federation targets. It
   grants Monitoring Metrics Publisher only on shared Application Insights.
   It also adds the private zone, A record, and both VNet links. Existing
   placeholder and Argo CD resources remain separately owned.
3. Pins the Istio internal ingress gateway's load balancer to the chosen
   private IP and the dedicated ingress subnet. The workflow waits up to 15
   minutes for AKS to create the fixed-name Service
   `aks-istio-ingressgateway-internal` and for it to report that exact IP. If
   AKS replaces that Service while the add-on is reconciling, the workflow
   detects its new Kubernetes UID and reapplies the internal, subnet, and
   static-IP annotations. It requires three healthy checks, 10 seconds apart,
   before proceeding. A timeout prints the Service, gateway pods, deployments,
   and recent events. Terraform creates the Network Contributor assignment the
   AKS cluster identity needs on the platform VNet before this step. The
   cluster identity manages the load balancer. It is not the kubelet identity
   that pulls images.
4. Installs the pinned cert-manager chart. The workflow creates the existing
   Cloudflare token secret in the `cert-manager` namespace and applies separate
   Argo CD and MCP ClusterIssuers. It does not create an MCP Certificate.
5. Installs the pinned `argo-cd` Helm chart and applies the app-of-apps
   (`infra/argocd/bootstrap-app-of-apps.yaml`), which points Argo CD at the
   separate `mcp-platform-kubernetes-manifests` repository.
6. Prints readiness: Argo CD `Application` sync status and the Istio
   ingress pods.

Argo CD then reconciles the placeholder workload asynchronously; check
`kubectl get applications -n argocd` (via `az aks get-credentials` +
`kubelogin`) if it does not show `Synced`/`Healthy` shortly after.

## 5. Pushing the placeholder image

Run **Build AKS placeholder image** (`.github/workflows/build-aks-placeholder-image.yml`)
separately -- it is not part of bootstrap. It pushes a small, pinned public
image into the registry this composition created, tagged by git commit SHA.
The workflow reads the workload identity client ID from Terraform state and
sends both values to the manifests repository. That repository validates them
and opens a draft promotion PR. Review and merge that PR. Do not copy either
value or edit a manifest by hand.

## 6. Publishing the MCP server image

Issue #151 adds **Publish MCP server image**
(`.github/workflows/publish-mcp-server-image.yml`) in an implementation PR.
Merging that implementation PR installs the workflow only. It does not publish
an image or open a deployment PR.

Issue #152 runs the workflow and produces the later deployment PR. Use this
order:

1. Hari runs **Deploy AKS platform** with `action: plan` at the selected source
   ref.
2. Hari reviews the plan for every forbidden replacement or deletion in issue
   #152.
3. If the plan contains a forbidden replacement or deletion, Hari stops.
4. Hari runs **Deploy AKS platform** with `action: bootstrap` at the selected
   source ref.
5. If the gated foundation apply succeeds, Hari runs **Publish MCP server
   image** at the same selected source ref.
6. The publisher pushes the MCP server image with the selected source commit
   as its tag.
7. The publisher sends the validated, non-secret deployment values to the
   companion manifests repository.
8. The companion workflow writes those values into the manifests.
9. The companion workflow opens issue #152's generated deployment PR.
10. Hari reviews the generated deployment PR before merge.

The generated deployment PR is not issue #151's implementation PR. The
implementation PR adds the publishing mechanism. The generated deployment PR
contains the image and runtime values that Argo CD will deploy.

## 7. Idling the cluster

`action: idle-stop` runs `az aks stop`. Wait 15 to 30 minutes (Microsoft
Learn's documented settle window; no tighter SLA is published) before
running `action: idle-start` (`az aks start`) -- this workflow does not wait
for you, deliberately: an automatic wait would turn a documented settle
requirement into something silently masked, not enforced. Running
`idle-start` too soon after `idle-stop` fails; if it does, wait longer and
retry.

## 8. Recording the first live measurement

Issue #110's acceptance criteria require the FIRST stop/start cycle's
measured behaviour recorded in COMPATIBILITY.md: whether the Istio add-on's
configuration survived, whether the pinned ingress IP survived, what
actually billed while stopped (Microsoft Learn's own pages disagree with
each other on this; do not repeat a blanket claim either way), the run ID,
and the date.

The first cycle ran on 2026-08-18: idle-stop run 32088912839, idle-start run
32090392364. The Istio add-on and the pinned ingress IP `10.20.2.4` both
survived, measured by direct read-only ARM and kubectl reads and recorded in
the "AKS `az aks stop`/`az aks start` behaviour across an idle cycle" row in
COMPATIBILITY.md. Idle billing was left UNMEASURED deliberately, because
Azure cost data lags the run by 8 to 24 hours.

For any later cycle, re-measure the same way and update that row; do not
treat the 2026-08-18 result as standing proof after an AKS Istio add-on
revision rollout or a documented stop/start behaviour change.

## Values this runbook produces, and where they are consumed

| Value | Consumed by |
|---|---|
| `AKS_PLATFORM_RESOURCE_GROUP`, `AKS_PLATFORM_CLUSTER_NAME`, `AKS_PLATFORM_REGISTRY_NAME` | `deploy-aks-platform.yml`'s `TF_VAR_*` env vars, `s1-aks-platform`'s `resource_group_name`/`cluster_name`/`registry_name` inputs |
| `AKS_PLATFORM_RUNNER_VNET_ID` | `TF_VAR_runner_vnet_id`, `private-network`'s spoke-to-runner peering link |
| `AKS_PLATFORM_INGRESS_PRIVATE_IP` | `TF_VAR_ingress_gateway_private_ip`, `private-network`'s subnet-containment validation and the Istio ingress gateway's Service annotation |
| Existing `S1_TFVARS_JSON` `entra_auth.server_app_client_id` | `TF_VAR_mcp_server_application_client_id`, the existing MCP server app lookup and federation target |
| Existing MCP server application's App ID URI | `mcp_resource_audience` output, read from `azuread_application.identifier_uris` |
| Terraform outputs `mcp_workload_client_id`, `mcp_namespace`, `mcp_service_account_name` | Companion ServiceAccount annotation and workload placement |
| Terraform outputs `mcp_private_hostname`, `mcp_resource_audience` | Companion Gateway and MCP authentication settings |
| Terraform output `istio_revision` | Companion namespace label after the later live-gate step confirms that revision is installed |

None of these values are secrets (no key, connection string, or credential
among them), but `AKS_PLATFORM_RUNNER_VNET_ID` is still never committed to
this repository, because it is an ARM resource ID and embeds a real
subscription ID.
