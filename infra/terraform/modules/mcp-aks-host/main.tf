# Wrapper over Azure/avm-res-containerservice-managedcluster/azurerm 0.8.1.
# The AVM module is the swappable implementation; this wrapper is the stable
# thick interface the private-backend composition depends on. See README.md
# for the issue-start AVM capability check this main.tf depends on, and
# COMPATIBILITY.md for the pins.
#
# Unlike mcp-function-host and apim-gateway's AVM wrappers, this module's
# inputs mirror the Microsoft.ContainerService/managedClusters ARM body
# almost field-for-field (service_mesh_profile.mode, ingress_profile.
# web_app_routing, and so on): the module is itself azapi-backed (Terraform
# Registry "Provider Dependencies": azapi ~> 2.9, modtm, random), which is
# why it can expose the Istio surface below without waiting on the classic
# azurerm_kubernetes_cluster resource to catch up.

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

module "aks" {
  source  = "Azure/avm-res-containerservice-managedcluster/azurerm"
  version = "0.8.1"

  name             = var.name
  location         = var.location
  parent_id        = data.azurerm_resource_group.this.id
  enable_telemetry = false
  tags             = var.tags

  kubernetes_version = var.kubernetes_version

  # sku.name is REQUIRED by ARM at apply time (confirmed live: PUT fails with
  # "Required property 'name' not found in 'sku'" if omitted), even though
  # the AVM module's own variable and the ARM template reference both mark
  # it optional in their schema tables -- a live-vs-doc gap, not something
  # terraform validate/plan catches. "Base" is the standard (non-Automatic)
  # managed cluster SKU name; "Automatic" is a different cluster management
  # model this module does not use. See COMPATIBILITY.md.
  sku = {
    name = "Base"
    tier = var.sku_tier
  }

  managed_identities = {
    system_assigned = true
  }

  # Azure CNI Overlay with the Cilium dataplane: pod IPs come from pod_cidr,
  # not from node_subnet_id, so the node subnet only has to hold node NIC
  # addresses (see private-network/README.md). network_policy is left unset
  # deliberately: Cilium enforces policy through the dataplane itself: "With
  # Azure CNI powered by Cilium, you don't need to install a separate network
  # policy engine" (Microsoft Learn, verified at issue start; see
  # COMPATIBILITY.md); network_policy = "cilium" would be accepted but is not
  # required by network_dataplane = "cilium", and AKS's own CLI examples for
  # enabling Cilium never pass it either.
  network_profile = {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_dataplane   = "cilium"
    pod_cidr            = var.pod_cidr
  }

  # --enable-oidc-issuer and --enable-workload-identity, both required
  # together for a workload's federated identity credential to exist at all
  # (issue 110 section 2, "Workload identity uses a user-assigned managed
  # identity" -- the forced choice there is downstream of these two flags
  # being on). Not exposed as module inputs: every caller of this module
  # needs both, so there is no scenario where either is off.
  oidc_issuer_profile = {
    enabled = true
  }

  security_profile = {
    workload_identity = {
      enabled = true
    }
  }

  default_agent_pool = {
    name           = "systempool"
    vm_size        = var.system_pool_vm_size
    count_of       = var.system_pool_node_count
    vnet_subnet_id = var.node_subnet_id
  }

  # mode = "Internal": the ingress gateway's Azure load balancer must be
  # internal, never publicly reachable (issue 110 section 2, "Ingress is the
  # AKS Istio add-on, internal gateway"). AKS creates the resulting
  # Kubernetes Service in the aks-istio-ingress namespace; pinning its load
  # balancer to the predetermined private IP and the dedicated ingress
  # subnet (private-network's istio_ingress_subnet_id/_name) happens by
  # annotating that Service after cluster creation
  # (service.beta.kubernetes.io/azure-load-balancer-ipv4 and
  # -internal-subnet), a Kubernetes-object-level step this Terraform module
  # does not own -- see the deploy-and-bootstrap workflow and
  # docs/runbooks/aks-platform-bootstrap.md.
  service_mesh_profile = {
    mode = "Istio"

    istio = {
      revisions = [var.istio_revision]

      components = {
        ingress_gateways = [
          {
            enabled = true
            mode    = "Internal"
          }
        ]
      }
    }
  }

  # gateway_api.installation = "Disabled" is a real, intentional value, not a
  # dummy: this module deliberately does not enable Managed Gateway API
  # (ingressProfile.gatewayAPI.installation). Ingress is the Istio add-on's
  # own Gateway/VirtualService API (networking.istio.io) against the
  # ingress_gateways component above, not the Kubernetes Gateway API
  # standard -- see ADR-010, "Ingress uses Istio's own API, not the
  # Kubernetes Gateway API standard", for why: Microsoft's own docs describe
  # Gateway API's "automated deployment model" as provisioning a NEW proxy
  # Deployment/Service per Gateway object, separate from the persistent
  # ingress_gateways component this module configures and the
  # deploy-and-bootstrap workflow pins to a fixed private IP. Enabling both
  # mechanisms risks two competing gateway deployments, with traffic
  # possibly routed through the unpinned one.
  #
  # It must be set explicitly, though, not omitted: the SAME
  # avm-res-containerservice-managedcluster 0.8.1 validation defect that
  # forces web_app_routing below to be explicit also fires here --
  # `terraform validate` fails with "Call to function coalesce failed: no
  # non-null, non-empty-string arguments" when gateway_api is left unset,
  # because the module's own input validation coalesces a null try() result
  # with an empty string. Confirmed by re-running validate with this block
  # omitted before adding it back explicitly.
  #
  # web_app_routing is a SEPARATE AKS add-on (the "Application Routing"
  # ingress controller) this module does not use -- ingress here is the Istio
  # gateway above, not App Routing. Filing both instances of the defect
  # upstream is tracked as a follow-up; the explicit "Disabled" values below
  # are real, intentional values (App Routing's own Gateway API
  # implementation is off, same as Managed Gateway API), not dummies chosen
  # only to dodge the crash -- it happens to also be what avoids it.
  ingress_profile = {
    gateway_api = {
      installation = "Disabled"
    }

    web_app_routing = {
      enabled = false

      gateway_api_implementations = {
        app_routing_istio = {
          mode = "Disabled"
        }
      }
    }
  }
}
