# private-network

The spoke virtual network for the epic 108 child (b) `private-backend`
deployment profile: an AKS node subnet, a dedicated subnet for the Istio
internal ingress gateway, and a delegated subnet for APIM Standard v2
outbound VNet integration. This is the network foundation task (issue 110,
task 1) that the `mcp-aks-host` module and the `private-backend` APIM
composition build on.

No deployment happens in this ticket: the module is proven by `terraform
fmt`, `init -backend=false`, `validate`, `tflint`, and `checkov` only.

## Address plan

Spoke CIDR `10.20.0.0/16`, chosen 2026-08-13 (Hari) because no hub network
exists yet and it does not overlap the existing GitHub Actions VNet runner
network's address space (`172.16.0.0/24`). This module builds one spoke; it
does not create a hub. If a hub network is added later, its CIDR must avoid
`10.20.0.0/16` -- this module does not need to change for that.

| Subnet | CIDR | Usable addresses | Why this size |
| --- | --- | --- | --- |
| APIM outbound (`apim_outbound_subnet_cidr`) | `10.20.0.0/24` | 251 | Microsoft's RECOMMENDED size for the outbound VNet integration subnet ("to accommodate scaling of API Management instance"); the documented minimum is /27. This subnet cannot be resized without recreating the integration, so the module defaults to the recommended size, not the minimum. |
| AKS nodes (`node_subnet_cidr`) | `10.20.1.0/24` | 251 | `mcp-aks-host` runs Azure CNI Overlay with the Cilium dataplane, so pod IPs come from a separate overlay range, not this subnet -- it only has to hold node NIC addresses. /24 is generous headroom over the 2-node system pool minimum (issue 110 section 2) for the node count to grow without a resize. |
| Istio ingress gateway (`ingress_gateway_subnet_cidr`) | `10.20.2.0/28` | 11 | Its own subnet, deliberately (Hari, 2026-08-13 planning session), so the gateway's pinned private IP (`ingress_gateway_private_ip`) cannot collide with a node. Azure reserves the first four addresses in any subnet (`.0`-`.3`); a load balancer frontend IP sharing the node subnet risks a node claiming the address first. /28 covers one ingress gateway frontend IP plus headroom for a second, canary Istio revision during an upgrade -- it is sized for load balancer IPs, not compute. |

`10.20.0.0/24` + `10.20.1.0/24` + `10.20.2.0/28` all fall inside
`10.20.0.0/16` with no overlap between them.

## The runner peering is spoke-side only

The module creates one `azurerm_virtual_network_peering` from this spoke to
the existing GitHub Actions VNet runner network (`var.runner_vnet_id`), added
now per Hari's 2026-08-13 decision so #117 (which owns the live-test gate
rewrite, per issue 110's out-of-scope list) only has to consume it rather
than create it.

Azure VNet peering is symmetric: a link on one side alone does not pass
traffic. The matching link back from the runner VNet to this spoke has to be
created inside the runner's own resource group, which this repo does not own
or manage -- that is Hari's step, or a change in whatever manages that
network, not this module's blast radius. Until that reverse link exists, this
peering sits in a half-connected state (Azure permits the create; traffic
does not flow).

`var.runner_vnet_id` has no default and is never a literal in this repo: it
is an ARM resource ID, which embeds a real subscription id, and AGENTS.md's
hard safety rules forbid committing subscription or tenant ids to this public
repo. It is supplied out of band as `TF_VAR_runner_vnet_id` on the live-test
GitHub Environment, the same pattern `apim-gateway`'s
`shared_observability_application_insights_id` already uses for a
non-secret-but-real resource reference.

## What this module does not do

- No hub network, and no peering to one -- none exists yet.
- No NSG rules beyond Azure's defaults. Each subnet gets its own network
  security group (satisfying the "every subnet has an NSG" posture) but no
  custom allow rule; AKS and the APIM outbound integration both reach what
  they need over Azure-managed control-plane paths that do not require one.
  A future PR that needs a specific rule has a named NSG per subnet to add it
  to.
- No private DNS. Issue 110's task list assigns private DNS for the backend
  to a later step in the same composition, not to this module.
