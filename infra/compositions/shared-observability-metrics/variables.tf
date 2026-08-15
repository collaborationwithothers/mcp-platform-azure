variable "resource_group_name" {
  type        = string
  description = "Name of the existing resource group that owns the shared metrics resources. This composition reads it and never manages it."
}

variable "location" {
  type        = string
  description = "Azure region for the Azure Monitor workspace and Azure Managed Grafana workspace."
}

variable "tags" {
  type        = map(string)
  description = "Optional tags merged with the fixed shared-observability tags."
  default     = {}
}

variable "grafana_admin_principal_ids" {
  type        = set(string)
  description = "Microsoft Entra principal object IDs that receive Grafana Admin on this Azure Managed Grafana workspace. Supplied out of band and never committed."
  default     = []
}

variable "grafana_viewer_principal_ids" {
  type        = set(string)
  description = "Microsoft Entra principal object IDs that receive Grafana Viewer on this Azure Managed Grafana workspace. Supplied out of band and never committed."
  default     = []
}
