# Thick interface: every input a later thickening of this platform needs
# (a second node pool, a canary Istio revision, a different Gateway API
# installation state) is present even though the placeholder workload this
# child proves (issue 110, task 9) exercises only the minimum. See
# docs/specs/v1-tracer-bullet.md, Delivery shape.

variable "name" {
  type        = string
  description = "Name of the AKS cluster."
}

variable "location" {
  type        = string
  description = "Azure region for the cluster."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group the cluster is deployed into. The resource group itself is out of band."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the cluster."
  default     = {}
}

variable "node_subnet_id" {
  type        = string
  description = "ARM resource ID of the AKS node subnet (private-network module's aks_node_subnet_id output)."
}

variable "log_analytics_workspace_id" {
  type        = string
  nullable    = false
  description = "ARM resource ID of the out-of-band Log Analytics workspace the cluster's diagnostic settings send logs and metrics to (issue 75's discovery-based pattern, extended to this child's resources)."

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/[Mm]icrosoft\\.[Oo]perational[Ii]nsights/workspaces/[^/]+$", var.log_analytics_workspace_id))
    error_message = "log_analytics_workspace_id must be a valid Microsoft.OperationalInsights/workspaces ARM resource ID."
  }
}

# 2 is the floor, not a default a caller is expected to raise casually: an AKS
# system node pool requires at least two nodes (issue 110 section 2, "An AKS
# system node pool requires at least two nodes, so idling by node count is
# impossible; only user pools reach zero"), and this module creates only the
# system pool -- the placeholder workload (task 9) runs on it. A dedicated
# user pool is a later thickening, not this child.
variable "system_pool_node_count" {
  type        = number
  description = "Fixed node count for the system pool. Must be at least 2 (AKS system pool minimum)."
  default     = 2

  validation {
    condition     = var.system_pool_node_count >= 2
    error_message = "system_pool_node_count must be at least 2: an AKS system node pool cannot run below its documented minimum."
  }
}

variable "system_pool_vm_size" {
  type        = string
  description = "VM size for the system pool."
  default     = "Standard_D2s_v6"
}

# Free (no SLA) is the module default: this platform is a reference
# deployment proven by a placeholder workload (issue 110), not a paid-SLA
# production cluster, and the ticket names no uptime requirement. A later
# thickening can raise this to Standard without restructuring the interface.
variable "sku_tier" {
  type        = string
  description = "AKS uptime SLA tier: Free (no SLA, no cost) or Standard."
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard"], var.sku_tier)
    error_message = "sku_tier must be \"Free\" or \"Standard\"."
  }
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version for the cluster. Null uses the AKS default (the current GA minor at apply time)."
  default     = null
}

# Overlay, not the node-subnet-IP variant: pod IPs come from this separate
# range, not from node_subnet_id, so the node subnet only has to size for node
# NICs (see private-network's README). 192.168.0.0/16 is chosen to avoid the
# spoke's own 10.20.0.0/16 and the existing GitHub Actions VNet runner network
# (172.16.0.0/24), even though overlay pod traffic does not cross the VNet
# peering in this design; keeping it clear of both ranges avoids a routing
# surprise if that ever changes.
variable "pod_cidr" {
  type        = string
  description = "CIDR range for pod IPs under Azure CNI Overlay."
  default     = "192.168.0.0/16"
}

# asm-1-27: one revision below the newest AKS-released revision at
# issue-start verification (asm-1-28, itself close to or past its documented
# expected EOL window) -- chosen for headroom, not because asm-1-28 is
# unusable. This platform does not use Managed Gateway API (see ADR-010,
# COMPATIBILITY.md), which would otherwise need at least asm-1-26. Istio
# revisions move
# on their own release cadence, independent of every other pin in this module
# (COMPATIBILITY.md, "Istio revision support is a standing maintenance
# obligation"); re-verify with `az aks mesh get-revisions --location <region>
# -o table` immediately before any live apply, not from this default.
variable "istio_revision" {
  type        = string
  description = "Istio add-on control plane revision (e.g. \"asm-1-27\"). Re-verify against `az aks mesh get-revisions` before any live apply; this default is a point-in-time choice, not a standing recommendation."
  default     = "asm-1-27"
}
