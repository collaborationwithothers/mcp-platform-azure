# mcp-aks-host

Wraps [`Azure/avm-res-containerservice-managedcluster/azurerm` 0.8.1](https://registry.terraform.io/modules/Azure/avm-res-containerservice-managedcluster/azurerm/0.8.1)
to provision the AKS cluster the migrated MCP server will run on (epic 108
child (b), issue 110 task 2): a system-assigned identity, OIDC issuer and
workload identity enabled, Azure CNI Overlay with the Cilium dataplane, a
two-node system pool on the caller's node subnet, and the Istio add-on with
an internal ingress gateway. Ingress is Istio's own Gateway/VirtualService
API, not the Kubernetes Gateway API standard -- see ADR-010 for why. This
module ships no application code -- the proof this platform works is the
placeholder workload in issue 110 task 9, not this module.

No deployment happens in this ticket: the module is proven by `terraform
fmt`, `init -backend=false`, `validate`, and `checkov` only.

## Issue-start AVM capability check (2026-08-13)

Verified directly against the module's published documentation (Terraform
MCP registry tools, module id
`Azure/avm-res-containerservice-managedcluster/azurerm/0.8.1`).

**Outcome: every capability this module needs is directly expressible. No
azapi fallback needed.**

- `network_profile.network_dataplane` / `.network_plugin_mode` /
  `.pod_cidr` express Azure CNI Overlay with Cilium.
- `oidc_issuer_profile.enabled` and `security_profile.workload_identity.
  enabled` express `--enable-oidc-issuer` / `--enable-workload-identity`.
- `service_mesh_profile` (`mode`, `istio.revisions`,
  `istio.components.ingress_gateways[].mode`) expresses the Istio add-on
  with an internal ingress gateway at a pinned revision.

This module deliberately sets `ingress_profile.gateway_api.installation =
"Disabled"` (Managed Gateway API left off; see "Known module defect worked
around here" below for why it must be set explicitly rather than omitted).
Microsoft's own AKS Istio ingress how-to
(`learn.microsoft.com/azure/aks/istio-deploy-ingress`, checked 2026-08-13)
documents the persistent, cluster-level ingress gateway component this
module configures (`service_mesh_profile.istio.components.ingress_gateways`)
as fully independent of Managed Gateway API -- routing through it needs only
Istio's own `Gateway`/`VirtualService` CRDs (`networking.istio.io`), which
ship with the add-on. Managed Gateway API's "automated deployment model"
(`learn.microsoft.com/azure/aks/istio-gateway-api`) instead provisions a
NEW, separate proxy Deployment/Service per `Gateway` object it reconciles --
mixing that in alongside this module's own pinned ingress gateway component
risks traffic routing through an unpinned second gateway rather than the one
`deploy-and-bootstrap` actually pins to a fixed private IP. See ADR-010,
"Ingress uses Istio's own API, not the Kubernetes Gateway API standard".

The module's inputs mirror the ARM body closely (it is azapi-backed, unlike
`mcp-function-host` and `apim-gateway`'s more HCL-shaped AVM wrappers), which
is a genuine advantage here: it does not wait on the classic
`azurerm_kubernetes_cluster` resource's own provider-schema lag (the same
lag pattern COMPATIBILITY.md already documents for `apim-mcp-server`) to
expose the Istio surface above.

## Known module defect worked around here (not this repo's bug)

`terraform validate` fails on `avm-res-containerservice-managedcluster`
0.8.1 with `Call to function "coalesce" failed: no non-null, non-empty-string
arguments` when either `ingress_profile.web_app_routing` OR
`ingress_profile.gateway_api` is left unset -- the module's own input
validation coalesces a `try()` result that resolves to `null` with an empty
string for both fields, and `coalesce` rejects both. Worked around in
`main.tf` by setting both explicitly: `gateway_api = { installation =
"Disabled" }` (this module deliberately does not enable Managed Gateway
API; see ADR-010) and `web_app_routing = { enabled = false,
gateway_api_implementations.app_routing_istio.mode = "Disabled" }` (App
Routing, a separate AKS ingress add-on this module does not use, really is
disabled). Both are real, intentional values that happen to also avoid the
crash, not dummy values chosen only to route around it.

## The ingress gateway's load balancer IP is not this module's job

`service_mesh_profile.istio.components.ingress_gateways[].mode = "Internal"`
tells AKS to create the ingress gateway's Kubernetes `Service` (in the
`aks-istio-ingress` namespace) as an internal load balancer, but pinning
that load balancer to the predetermined private IP and the dedicated ingress
subnet (`private-network`'s `istio_ingress_subnet_id`/`_name` outputs) means
annotating that `Service` after cluster creation
(`service.beta.kubernetes.io/azure-load-balancer-ipv4` and
`-internal-subnet`) -- a Kubernetes-object-level step, not an ARM property
this Terraform module can set. That step lives in the deploy-and-bootstrap
workflow (issue 110 task 8), not here.

## Node resource group

The Istio ingress gateway's load balancer and public IP resources (if any)
land in the AKS-managed node resource group (`node_resource_group_name`
output), not `resource_group_name`. This is standard AKS behaviour, not
specific to this module.
