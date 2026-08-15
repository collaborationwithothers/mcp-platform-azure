# Thick interface: every input is present even though this composition only
# drives one deployment_profile (private-backend) at one address plan, so a
# later composition (a second cluster, a second region) extends this contract
# without restructuring it. See docs/specs/v1-tracer-bullet.md, Delivery shape.

variable "name_prefix" {
  type        = string
  description = "Prefix applied to every resource this module creates (virtual network, subnets, network security groups)."
}

variable "location" {
  type        = string
  description = "Azure region for the virtual network and its subnets."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group the network is deployed into. The resource group itself is out of band."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource this module creates."
  default     = {}
}

# 10.20.0.0/16 (Hari, 2026-08-13): a spoke range chosen because no hub network
# exists yet and it does not overlap the existing GitHub Actions VNet runner
# network's address space. This module builds a single spoke; it does not
# create a hub or manage anything on the runner's side of the peering (see
# runner_vnet_id below). If a hub network is created later, its own CIDR must
# be chosen to avoid this range, and this module does not need to change.
variable "address_space" {
  type        = list(string)
  description = "Address space of the spoke virtual network."
  default     = ["10.20.0.0/16"]

  validation {
    condition     = alltrue([for cidr in var.address_space : can(cidrhost(cidr, 0))])
    error_message = "Every entry in address_space must be a valid CIDR block."
  }
}

# Sized for the placeholder workload this child proves (issue 110, task 9), not
# for a production node count: Azure CNI Overlay (see mcp-aks-host's
# network_dataplane = "cilium" with network_plugin_mode = "overlay") assigns
# pod IPs from a separate overlay range, not from this subnet, so the node
# subnet only has to hold node NIC addresses. /24 (256 addresses, 251 usable
# after Azure's first-4 reservation) is generous headroom over the 2-node
# system pool minimum documented in issue 110 section 2, for the node count to
# grow without a subnet resize.
variable "node_subnet_cidr" {
  type        = string
  description = "CIDR block for the AKS node subnet, carved from address_space."
  default     = "10.20.1.0/24"

  validation {
    condition     = can(cidrhost(var.node_subnet_cidr, 0))
    error_message = "node_subnet_cidr must be a valid CIDR block."
  }
}

# The Istio internal ingress gateway gets its OWN subnet (Hari, 2026-08-13
# planning session, issue 110 section 3 item 7) specifically so its pinned
# private IP (see ingress_gateway_private_ip) cannot collide with a node: Azure
# reserves only the first four addresses in a subnet (.0-.3), so a load
# balancer frontend IP sharing the node subnet risks a node claiming the same
# address first. /28 (16 addresses, 11 usable) is sized for one internal load
# balancer frontend IP plus headroom for a canary Istio revision's second
# ingress gateway during an upgrade, not for compute.
variable "ingress_gateway_subnet_cidr" {
  type        = string
  description = "CIDR block for the Istio internal ingress gateway subnet, carved from address_space."
  default     = "10.20.2.0/28"

  validation {
    condition     = can(cidrhost(var.ingress_gateway_subnet_cidr, 0))
    error_message = "ingress_gateway_subnet_cidr must be a valid CIDR block."
  }
}

# /24 is Microsoft's RECOMMENDED size for the APIM outbound VNet integration
# delegated subnet ("to accommodate scaling of API Management instance"); /27
# is the documented minimum. This module uses the recommended size, not the
# minimum, because this subnet cannot be resized without recreating the
# integration. See COMPATIBILITY.md, "APIM Standard v2 outbound VNet
# integration".
variable "apim_outbound_subnet_cidr" {
  type        = string
  description = "CIDR block for the APIM Standard v2 outbound VNet integration subnet, carved from address_space. Delegated to Microsoft.Web/serverFarms by this module."
  default     = "10.20.0.0/24"

  validation {
    condition     = can(cidrhost(var.apim_outbound_subnet_cidr, 0))
    error_message = "apim_outbound_subnet_cidr must be a valid CIDR block."
  }
}

# The predetermined private IP for the Istio internal ingress gateway's
# Azure internal load balancer (issue 110 section 2, "The internal load
# balancer gets a pinned, predetermined private IP"). Must fall inside
# ingress_gateway_subnet_cidr, which this module validates; the composition
# passes the same value to the gateway's
# service.beta.kubernetes.io/azure-load-balancer-ipv4 annotation, and this
# module never defaults it, because pinning is the point.
# This module's own resources never read the value -- the annotation itself
# is a Kubernetes-object-level step the deploy-and-bootstrap workflow
# performs, not a Terraform resource here (see mcp-aks-host/README.md, "The
# ingress gateway's load balancer IP is not this module's job"). Declaring
# it here anyway is deliberate: it is the one place the caller's chosen IP
# gets checked against the subnet it must live in, before anything
# downstream consumes it.
# tflint-ignore: terraform_unused_declarations
variable "ingress_gateway_private_ip" {
  type        = string
  description = "Predetermined private IPv4 address for the Istio internal ingress gateway's load balancer, inside ingress_gateway_subnet_cidr."

  validation {
    condition     = can(cidrhost("${var.ingress_gateway_private_ip}/32", 0))
    error_message = "ingress_gateway_private_ip must be a valid IPv4 address."
  }

  # Terraform 1.15 has no cidrcontains function. cidrhost masks its prefix
  # argument down to that prefix length's network address and ignores any
  # host bits given, so re-applying the subnet's own prefix length to the
  # candidate IP and comparing network addresses is an exact containment
  # check without manual bit arithmetic.
  validation {
    condition     = cidrhost("${var.ingress_gateway_private_ip}/${split("/", var.ingress_gateway_subnet_cidr)[1]}", 0) == cidrhost(var.ingress_gateway_subnet_cidr, 0)
    error_message = "ingress_gateway_private_ip must fall inside ingress_gateway_subnet_cidr."
  }
}

variable "log_analytics_workspace_id" {
  type        = string
  nullable    = false
  description = "ARM resource ID of the core-state Log Analytics workspace the three NSGs' diagnostic settings send logs to (issue 75's discovery-based pattern, extended to this child's resources). Not wired to the virtual network resource itself; see main.tf for why."

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/[Mm]icrosoft\\.[Oo]perational[Ii]nsights/workspaces/[^/]+$", var.log_analytics_workspace_id))
    error_message = "log_analytics_workspace_id must be a valid Microsoft.OperationalInsights/workspaces ARM resource ID."
  }
}

# No default: the runner VNet's resource ID is real infrastructure Hari owns
# outside this repo (a different resource group than anything this module
# creates, though the same subscription -- see main.tf for why that makes
# the reverse peering link this module's blast radius, not an external one)
# and must never be a literal in this repo (AGENTS.md hard safety rule: no
# subscription or tenant ids committed; an ARM resource ID embeds the
# subscription id). Supplied out of band as TF_VAR_runner_vnet_id on the
# live-test GitHub Environment. The shared observability module input is
# supplied by its scenario through remote state instead.
# This module creates BOTH sides of the peering link (main.tf,
# to_runner_network and from_runner_network): the runner's resource group
# and VNet name are parsed out of this value, not passed separately.
variable "runner_vnet_id" {
  type        = string
  description = "ARM resource ID of the existing GitHub Actions VNet runner network to peer this spoke to, so the live-test gate's VNet-runner job (AGENTS.md hard safety rules, epic 108 child (b) exception) can reach the private backend once #117 wires the gate itself. Never a literal default; supplied out of band."

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", var.runner_vnet_id))
    error_message = "runner_vnet_id must be a valid Microsoft.Network/virtualNetworks ARM resource ID."
  }
}
