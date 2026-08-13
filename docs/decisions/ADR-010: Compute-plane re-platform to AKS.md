# ADR-010: Compute-plane re-platform to AKS

Status: Proposed (Terraform lands in this PR; live proof is a later gated
run, see Consequences)
Date: 2026-08-13
Supersedes: ADR-002 (MCP server hosting selection)

## Context

Issue #106 checked whether this platform's Azure services could serve MCP
protocol revision 2026-07-28 and found the Azure Functions MCP extension
UNVERIFIED for that revision: Microsoft names no supported MCP revision
newer than 2025-06-18 for the extension, and the platform's own S1 server
runs on it (ADR-002). That is a forcing function, not a preference: the v1
server has to move off the Functions extension before this repo can ever
adopt a newer MCP revision, independent of whether anything else about
Functions is wrong.

Epic #108 splits that move into four children. This ADR covers child (b1),
issue #110: the platform the re-platformed server will run on. It ships no
application code. `src/McpTools` and the Functions-hosted backend stay
deployed and serving exactly as ADR-002 describes until child (b4) (issue
#117) repoints APIM at the new backend. The proof this child's platform
actually works is a placeholder container, not the real MCP server; the
real server rewrite is child (b2), issue #115.

![This child's provisioned platform: a spoke VNet (10.20.0.0/16) with
separate subnets for the APIM outbound integration, the AKS node pool, and
the Istio internal ingress gateway; the AKS cluster with its Istio add-on,
Argo CD, and container registry; and the one-sided peering to the existing
GitHub Actions VNet runner network. APIM does not yet route MCP client
traffic here -- the Functions-hosted server stays the live backend until
child (b4), issue #117, cuts over.](../diagrams/aks-platform.drawio.svg)

## Decision

**Host is AKS, not Container Apps.** Container Apps was tested first,
because ADR-002's own Alternatives list names it as the tested pattern for
private MCP. It fails on one finding, not a preference: its built-in
authentication (`Microsoft.App/containerApps/authConfigs`) serves no RFC
9728 Protected Resource Metadata document at any checked ARM api-version
from `2022-03-01` through `2026-01-01` -- the `properties` bag has no PRM
field. AKS has no such constraint, because this platform serves PRM itself
rather than relying on any compute plane's built-in auth to do it (ADR-006).
https://learn.microsoft.com/azure/templates/microsoft.app/2026-01-01/containerapps/authconfigs
https://learn.microsoft.com/azure/container-apps/mcp-authentication

**The cluster persists; it is idled with `az aks stop`, not destroyed.**
Every other v1 scenario composition (S1, S2) is apply-call-destroy,
ephemeral by design. This platform breaks that pattern deliberately: an AKS
system node pool needs at least two nodes and cannot idle to zero the way a
user pool can, so the cost-control mechanism is stopping the whole cluster,
not destroying and recreating it. `.github/workflows/deploy-aks-platform.yml`
is a new class of workflow in this repo as a result -- `bootstrap` /
`idle-stop` / `idle-start`, not `apply-call-destroy`. It targets a stable,
non-ephemeral resource group (`vars.AKS_PLATFORM_RESOURCE_GROUP`), distinct
from `ephemeral-env.yml`'s per-run `rg-mcp-tracer-<run id>` groups, so the
two workflows and their cleanup sweeps never collide.
https://learn.microsoft.com/azure/aks/use-system-pools#system-and-user-node-pools
https://learn.microsoft.com/azure/aks/start-stop-cluster

**Ingress is the AKS Istio add-on, internal gateway, driven by Gateway
API.** `infra/terraform/modules/mcp-aks-host` wraps
`Azure/avm-res-containerservice-managedcluster/azurerm` 0.8.1, which is
itself azapi-backed (its own "Provider Dependencies" name `azapi ~> 2.9`).
That matters beyond convenience: it is why this module can express
`service_mesh_profile` and `ingress_profile.gateway_api` at all without
waiting on the classic `azurerm_kubernetes_cluster` HCL resource's own
provider-schema lag -- the same lag pattern already documented for
`apim-mcp-server`'s `2025-09-01-preview` pin. `network_profile` is Azure CNI
Overlay with the Cilium dataplane (`network_plugin = "azure"`,
`network_plugin_mode = "overlay"`, `network_dataplane = "cilium"`); overlay
means pod IPs come from a separate range (`pod_cidr`, default
`192.168.0.0/16`), not the node subnet, which is why the node subnet in
`private-network` only has to be sized for node NICs. `network_policy` is
left unset: Cilium enforces policy through the dataplane itself, and
`network_dataplane = "cilium"` does not imply `network_policy = "cilium"`.
https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium
https://learn.microsoft.com/azure/aks/istio-about

**Managed Gateway API is a preview ARM surface, accepted as a live-gate
risk, not a local one.** `ingressProfile.gatewayAPI.installation` (enum
`Disabled` | `Standard`) exists only from
`Microsoft.ContainerService/managedClusters` api-version
`2025-10-02-preview` onward -- it is absent from the newest STABLE
api-version, `2025-05-01`, at issue-start verification (2026-08-13). This
module sets it anyway, the same risk-acceptance pattern `apim-mcp-server`
already uses for its own preview pin: whether the underlying AVM module
actually reaches a preview-capable api-version is that module's own
internal choice, and ARM acceptance is proven at the live gate, not
asserted locally. Separately, Microsoft Learn's own pages currently
disagree with each other on whether Gateway API ingress for the add-on is
GA: `istio-gateway-api` presents it as an ordinary supported feature with no
preview banner, while `istio-about`'s own Limitations section still lists it
as "currently under active development." Both are recorded, not reconciled,
in COMPATIBILITY.md.
https://learn.microsoft.com/azure/templates/microsoft.containerservice/2026-04-02-preview/managedclusters
https://learn.microsoft.com/azure/aks/istio-gateway-api
https://learn.microsoft.com/azure/aks/istio-about

**Istio add-on revision is a standing maintenance obligation, not a fixed
pin.** AKS supports an `n-2` revision only until six weeks after revision
`n` STARTS rolling out to all regions (not "finishes," which an earlier
draft of this platform's planning notes had backwards), and keeps at least
two revisions alive at any time. `mcp-aks-host`'s `istio_revision` variable
defaults to `asm-1-27`: it clears the `asm-1-26` floor Managed Gateway API
needs, one revision below the newest AKS-released revision at issue-start
verification (`asm-1-28`, itself close to or past its documented expected
end-of-life window). That default is a point-in-time choice. The module's
own variable description and COMPATIBILITY.md both say to re-run
`az aks mesh get-revisions --location <region> -o table` immediately before
any live apply rather than trust the default.
https://learn.microsoft.com/azure/aks/istio-support-policy

**The internal ingress gateway gets its own subnet, and a pinned,
predetermined private IP.** Azure reserves the first four addresses in any
subnet; sharing the node subnet risks a node claiming the address the
gateway needs first. `private-network` carves a dedicated `/28` for it
(`infra/terraform/modules/private-network/README.md` has the sizing math)
and validates the pinned IP falls inside it. Pinning the load balancer
itself, though, is a Kubernetes-object-level step (annotating the
`Service` AKS creates in the `aks-istio-ingress` namespace with
`service.beta.kubernetes.io/azure-load-balancer-ipv4` and
`-internal-subnet`) that no ARM property on the cluster resource can
express -- it happens in `deploy-aks-platform.yml`, after cluster creation,
not in Terraform.
https://learn.microsoft.com/azure/aks/internal-lb#specify-an-ip-address

**APIM moves to Standard v2 with outbound-only VNet integration for the new
`private-backend` deployment profile; its gateway host stays public.**
Outbound VNet integration needs Standard v2 or Premium v2 -- Basic v2 does
not support it (re-verified at issue start; COMPATIBILITY.md). This ADR
amends ADR-003 (see that file): ADR-003 scoped Standard v2 to the FULL
private platform variant (inbound private endpoint AND outbound
integration, S4, still gated); this child proves only the outbound half,
for the narrow AGENTS.md carve-out (APIM-to-AKS-backend private path). APIM
gets no inbound private endpoint here, and `apim-gateway`'s
`virtual_network_type` variable is deliberately restricted to `None` or
`External` -- never `Internal` (classic VNet injection), which the
AGENTS.md carve-out forbids and which Standard v2 rejects outright in live
testing anyway (an open upstream provider issue, azurerm#30296, shows the
exact rejection).
https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound
https://learn.microsoft.com/azure/api-management/upgrade-and-scale

**No private DNS zone in this child.** The AGENTS.md carve-out names
"private DNS for the backend" as in scope for epic 108 child (b) generally,
but issue #110's own task breakdown (section 4) never lists a private DNS
step, and nothing in this child yet needs one: APIM does not route real MCP
traffic to the AKS backend by name (or at all) until child (b4), issue
#117, repoints it. A DNS zone with no consumer would be built ahead of the
thing that needs it. This platform's backend is reached, when #117 wires
it, by the pinned private IP this child already establishes; whether that
graduates to a private DNS name is #117's decision to make when it actually
builds the route, not this child's to pre-empt.

**GitOps is Argo CD, self-installed from a pinned upstream Helm chart, not
the `Microsoft.ArgoCD` managed extension.** That extension is public
preview, and Microsoft's own Learn pages disagree with each other on its
resource type casing (`microsoft.argocd` on the conceptual page,
`Microsoft.ArgoCD` in every runnable example). This epic exists because a
preview-adjacent platform dependency (the Functions MCP extension's
revision ceiling) became a blocker; the replacement platform does not put
a second preview dependency in its own deploy path. The chart is pinned
like every other dependency: `argo-cd` 10.3.2 (`appVersion` v3.5.0),
verified at issue start against the chart's own GitHub release and
`Chart.yaml`.
https://github.com/argoproj/argo-helm/releases/tag/argo-cd-10.3.2

**Argo CD's bootstrap is two steps, matching the plan, though the plan's
own stated REASON for that no longer matches the current chart.** Hari's
2026-08-13 planning session recorded "the first Application cannot be
declared inside the chart configuration" as the reason bootstrap needs two
steps (chart install, then `kubectl apply` of the app-of-apps). Issue-start
verification found that premise stale for chart 10.3.2: it exposes a
top-level `extraObjects` value specifically for embedding extra manifests
(including an `Application`) directly in the same `helm install`, which
would collapse this to one step. This ADR keeps the two-step design anyway
-- `deploy-aks-platform.yml` installs the chart, then applies
`infra/argocd/bootstrap-app-of-apps.yaml` as a separate `kubectl apply` --
because the design itself is still correct and was Hari's explicit decision
in section 2 of issue #110, not something this implementation session has
standing to silently change on a corrected premise. The correction is
recorded here so a future PR can revisit collapsing it, as a real option,
not a forgotten one.

The chart's `redis-ha.enabled` also turned out to already default to
`false` (HA is opt-in, not the chart default) -- the issue's stated edge
case, "Argo CD's default HA mode wants four or more nodes... set
`redis-ha.enabled=false` or the install will not schedule," does not hold
for chart 10.3.2 on a stock install. `deploy-aks-platform.yml` still passes
`redis-ha.enabled=false` explicitly, harmless and matching the documented
value's own default, so the workflow's intent is not implicit and does not
silently regress if a future chart bump flips that default.

**Argo CD reads a separate, public, credential-free manifests
repository.** `collaborationwithothers/mcp-platform-kubernetes-manifests`,
public, created for this purpose. Microsoft Learn documents secretless Argo
CD git access via workload identity for Azure Repos and ACR only; GitHub
has no such documented path, so a private repo would need a stored
credential (an SSH key or token secret), which this platform's hard rule
against stored secrets forbids outright. A public repo sidesteps the
question entirely: it is read anonymously, so there is nothing to store.

**A user-assigned managed identity for workload identity, not
system-assigned.** A system-assigned identity cannot hold a federated
identity credential at all -- the AKS cluster's own control-plane identity
stays system-assigned (unaffected), but the placeholder workload's pod
identity is a separate `azurerm_user_assigned_identity` plus
`azurerm_federated_identity_credential`, federated against
`mcp-aks-host`'s OIDC issuer, subject
`system:serviceaccount:<namespace>:<serviceaccount>`, audience
`api://AzureADTokenExchange`.
https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity

**Images are pulled by role assignment, never an image pull secret; the
registry admin account is disabled.** `container-registry` grants AcrPull
to the cluster's kubelet identity and AcrPush to the CI identity that
pushes the placeholder image, both role assignments, both least-privilege.
Microsoft Learn discourages the registry admin account directly; this
platform never enables it.
https://learn.microsoft.com/azure/container-registry/container-registry-authentication#admin-account

**The deploy-and-bootstrap workflow reuses the existing `live-test` GitHub
Environment rather than a new one.** This repo's own domain glossary
(`infra/CONTEXT.md`) defines "Live-test environment" as singular: "The
single gated environment in which terraform apply and destroy may run."
`deploy-aks-platform.yml` does run `terraform apply` (to create or update
the persistent platform), so it uses that same environment and its
existing OIDC federated credential rather than asking Hari to provision a
second one for a workflow with an identical hard-safety posture (OIDC-only,
no stored secret, environment-gated). Its lifecycle still differs from
`ephemeral-env.yml`'s apply-call-destroy pattern -- this platform is
created or resumed, never destroyed by this workflow -- and it targets a
stable, separately-named resource group so the two workflows' state and
cleanup sweeps never collide. This reuse is a deliberate operational
choice, not an oversight; it is named here as the thing for governance
review to scrutinise by hand, alongside the runner-VNet-peering item below.

**The spoke's VNet runner peering is created now, one-sided, ahead of the
child that will use it.** Hari's decision, 2026-08-13: `private-network`
creates the spoke-side `azurerm_virtual_network_peering` link to the
existing GitHub Actions VNet runner network now, even though issue #110's
own task list and out-of-scope section never mention it, and the live-test
gate that will actually need it (once the backend sits behind this internal
ingress gateway, a `ubuntu-latest` runner cannot reach it at all) is child
(b4), issue #117's job, per the AGENTS.md hard-safety-rules exception dated
the same day. The reverse peering link, inside the runner's own resource
group (`rg-dv-gh-actions-neu`), is outside this repo's blast radius
entirely and is not created here -- Hari's step, or a change wherever that
network is actually managed. Until it exists, this peering sits
half-connected (Azure permits the one-sided create; no traffic flows). The
runner network's own address space (`172.16.0.0/24`) and resource id are
never literals in this repo -- an ARM resource id embeds a real
subscription id, which AGENTS.md's hard safety rules forbid committing to
this public repo -- so the peering target is a required Terraform variable
with no default, supplied out of band.

## Alternatives considered

- **Container Apps.** Rejected; see Decision (no PRM surface at any checked
  ARM api-version).
- **`Microsoft.ArgoCD` managed cluster extension.** Rejected; see Decision
  (public preview, inconsistent Learn documentation of its own resource
  type).
- **Classic `azurerm_kubernetes_cluster` HCL resource, wrapped directly
  instead of via an AVM module.** Rejected: it would reintroduce the exact
  provider-schema-lag problem this platform is trying to avoid (the
  provider's documented internal API-Providers pin,
  `Microsoft.ContainerService - 2025-10-01`, is six releases behind the
  newest stable ARM version at issue-start verification,
  `2026-04-01`), and would need a hand-authored `azapi_update_resource` for
  Managed Gateway API instead of the AVM module's native
  `ingress_profile.gateway_api` input.
- **APIM Premium v2 injection, or classic Developer, for the private-backend
  profile.** Not reconsidered here; ADR-003 already covers this trade-off
  for the private platform variant generally, and this child changes
  nothing about that reasoning -- it just proves the narrower outbound-only
  slice of what ADR-003 already recommends.

## Consequences

- Live proof is still outstanding. This ADR's Terraform is proven by
  `terraform fmt` / `init -backend=false` / `validate` / `tflint` /
  `checkov` only, per the hard rule that agents never run `terraform apply`
  or `destroy` outside the gated live-test environment. A real bootstrap
  run, a real stop/start cycle with its measured Istio-add-on and
  pinned-IP behaviour recorded in COMPATIBILITY.md, and a real placeholder
  deploy through Argo CD are all still needed before this ADR's Status
  moves to Accepted, matching how ADR-002 itself only reached Accepted at
  the v1 tag once its own live proof existed.
- `avm-res-containerservice-managedcluster` 0.8.1 has a validation defect:
  `terraform validate` fails with a `coalesce` error if
  `ingress_profile.web_app_routing` is left unset. Worked around in
  `mcp-aks-host/main.tf` by setting it to a real, intentional `Disabled`
  value (App Routing, a separate AKS ingress add-on this platform does not
  use, really is disabled) rather than filing this as a blocking issue;
  the module README records this as a known upstream defect, not this
  repo's bug.
- The private-backend `deployment_profile` value is now accepted by BOTH
  `s1-entra-mcp-server` and `s2-apim-mcp-gateway`'s variable validation, for
  contract consistency, but only changes `s2`'s behaviour (APIM's SKU and
  VNet integration). `s1`'s own sizing map carries an identical
  `private-backend` entry to `public-demo` deliberately: the Functions
  backend it provisions does not change shape until child (b4) cuts over.
- COMPATIBILITY.md grows several new rows this PR: the AKS
  `managedClusters` ARM api-versions, the Istio add-on revision policy and
  its wording correction, the Managed Gateway API preview-surface finding
  and its Learn-vs-Learn GA disagreement, the `argo-cd` chart pin and its
  `redis-ha`/`extraObjects` corrections, and the re-verified APIM Standard
  v2 outbound integration tier list and subnet delegation requirement.

## References

Every doc URL cited above; also see COMPATIBILITY.md for the same claims
with their exact verification dates.
