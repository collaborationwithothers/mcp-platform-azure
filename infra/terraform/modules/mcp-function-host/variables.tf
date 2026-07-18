# Thick interface: every input is present even though the tracer only
# exercises a subset, so later thickening PRs (OBO, multi-tenant, private
# networking) extend behaviour without restructuring this contract. See
# docs/specs/v1-tracer-bullet.md, Delivery shape.

variable "name_prefix" {
  type        = string
  description = "Prefix used to derive names for resources this module owns (service plan, function app, and any storage account it creates)."
}

variable "location" {
  type        = string
  description = "Azure region for all resources this module creates."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group the resources are deployed into. The resource group itself is out of band."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource this module creates. Expected to include the ephemeral expiry tag used by the cleanup sweep (see docs/specs/v1-tracer-bullet.md, Ephemeral)."
  default     = {}
}

variable "runtime" {
  type = object({
    stack   = optional(string, "dotnet-isolated")
    version = optional(string, "10.0")
  })
  description = "Functions worker runtime. Only dotnet-isolated is supported by this module; the field exists for interface completeness with other language runtimes avm-res-web-site can express. version is passed straight through to functionAppConfig.runtime.version; dotnet-isolated uses the major.minor form (\"8.0\", \"9.0\", \"10.0\"), matching the official Flex Consumption IaC samples and the Az.Functions runtimes list. See COMPATIBILITY.md."
  default     = {}

  validation {
    condition     = var.runtime.stack == "dotnet-isolated"
    error_message = "runtime.stack must be \"dotnet-isolated\": the tracer's scope is the .NET isolated worker per ADR-002."
  }
}

variable "flex_consumption" {
  type = object({
    instance_memory_mb     = optional(number, 2048)
    maximum_instance_count = optional(number, 40)
  })
  description = "Flex Consumption sizing. Defaults are a small demo footprint (2048 MB instances, scale ceiling of 40)."
  default     = {}

  validation {
    condition     = contains([512, 2048, 4096], var.flex_consumption.instance_memory_mb)
    error_message = "flex_consumption.instance_memory_mb must be one of 512, 2048, or 4096 (Flex Consumption's documented instance sizes)."
  }

  validation {
    condition     = var.flex_consumption.maximum_instance_count >= 1 && var.flex_consumption.maximum_instance_count <= 1000
    error_message = "flex_consumption.maximum_instance_count must be between 1 and 1000."
  }
}

variable "storage_account_name" {
  type        = string
  description = "Name of the storage account backing the Flex Consumption deployment package. Either an existing account (create_storage_account = false, the default) or the name to give a new account this module creates (create_storage_account = true)."
}

variable "create_storage_account" {
  type        = bool
  description = "Whether this module creates storage_account_name (true) or expects it to already exist (false, the default), matching the out-of-band pattern used for other long-lived assets in the tracer."
  default     = false
}

variable "entra_auth" {
  type = object({
    tenant_id              = string
    server_app_client_id   = string
    allowed_audiences      = list(string)
    unauthenticated_action = optional(string, "Return401")
  })
  description = "Entra built-in auth (Easy Auth) settings. allowed_audiences must include the server app's App ID URI. unauthenticated_action is fixed at \"Return401\" (see validation): the acceptance criterion is that unauthenticated requests are rejected, not redirected to a login page."

  validation {
    condition     = var.entra_auth.unauthenticated_action == "Return401"
    error_message = "entra_auth.unauthenticated_action must be \"Return401\": an MCP endpoint returns 401, it does not redirect to a login page."
  }

  validation {
    condition     = length(var.entra_auth.allowed_audiences) > 0
    error_message = "entra_auth.allowed_audiences must include at least the server app's App ID URI."
  }
}

variable "prm_scope" {
  type        = string
  default     = null
  description = "OAuth scope surfaced to callers via the WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES app setting, e.g. api://<server-app-id>/user_impersonation. This is a preview App Service capability; see README.md and COMPATIBILITY.md. Optional (default null): leave unset for an instance that is not itself an MCP resource server, e.g. the issue-10 downstream Orders API, which skips the WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES app setting entirely rather than publish an RFC 9728 challenge nothing points at."
}

variable "app_settings" {
  type        = map(string)
  description = "Additional app settings merged in alongside the settings this module sets for auth, protected resource metadata, and the MCP extension key posture. Caller-supplied keys do not override the module's own settings."
  default     = {}
}
