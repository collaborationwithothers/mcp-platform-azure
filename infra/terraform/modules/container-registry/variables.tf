variable "name" {
  type        = string
  description = "Name of the container registry (globally unique, alphanumeric only)."
}

variable "location" {
  type        = string
  description = "Azure region for the registry."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group the registry is deployed into. The resource group itself is out of band."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the registry."
  default     = {}
}

# Standard, not the module's own Premium default: AcrPull/AcrPush and the
# admin-disabled posture this module enforces do not need Premium features
# (geo-replication, private endpoints, customer-managed keys), and none of
# those are in scope for the placeholder workload this child proves (issue
# 110, task 9). zone_redundancy_enabled must be false alongside this: Azure
# Container Registry zone redundancy requires Premium.
variable "sku" {
  type        = string
  description = "SKU of the container registry."
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku)
    error_message = "sku must be \"Basic\", \"Standard\", or \"Premium\"."
  }
}

# AcrPull for each principal (the AKS cluster's kubelet identity in this
# composition; issue 110 task 4, "an AcrPull role assignment to the cluster's
# kubelet identity"). Empty list (default) => no grants, matching the
# data_reader_principal_ids pattern api-center-registry and apim-gateway
# already use for optional role grants.
variable "acr_pull_principal_ids" {
  type        = list(string)
  description = "Object ids of Entra principals to grant AcrPull on this registry."
  default     = []
}

# AcrPush for the CI identity that builds and pushes the placeholder image
# (issue 110 task 4, "a push role for the CI identity"; task 9's image
# pipeline). Same empty-list-default pattern as acr_pull_principal_ids.
variable "acr_push_principal_ids" {
  type        = list(string)
  description = "Object ids of Entra principals to grant AcrPush on this registry."
  default     = []
}

variable "log_analytics_workspace_id" {
  type        = string
  nullable    = false
  description = "ARM resource ID of the core-state Log Analytics workspace the registry's diagnostic settings send logs and metrics to (issue 75's discovery-based pattern, extended to this child's resources)."

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/[Mm]icrosoft\\.[Oo]perational[Ii]nsights/workspaces/[^/]+$", var.log_analytics_workspace_id))
    error_message = "log_analytics_workspace_id must be a valid Microsoft.OperationalInsights/workspaces ARM resource ID."
  }
}
