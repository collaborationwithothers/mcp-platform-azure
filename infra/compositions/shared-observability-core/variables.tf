variable "resource_group_name" {
  type        = string
  description = "Name of the existing resource group that owns the shared observability resources. This composition reads it and never manages it."
}

variable "location" {
  type        = string
  description = "Azure region for the shared Log Analytics and Application Insights resources."
}

variable "tags" {
  type        = map(string)
  description = "Optional tags merged with the fixed shared-observability tags."
  default     = {}
}

variable "log_analytics_retention_days" {
  type        = number
  description = "Log Analytics retention period in days."
  default     = 30

  validation {
    condition     = var.log_analytics_retention_days > 0
    error_message = "log_analytics_retention_days must be greater than zero."
  }
}

variable "daily_ingestion_cap_gb" {
  type        = number
  description = "Daily Log Analytics and Application Insights ingestion cap in GB. This is a guardrail, not a usage measurement or cost estimate."
  default     = 5

  validation {
    condition     = var.daily_ingestion_cap_gb > 0
    error_message = "daily_ingestion_cap_gb must be greater than zero."
  }
}
