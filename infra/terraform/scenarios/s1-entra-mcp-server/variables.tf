# S1 composition: instantiates mcp-function-host with Entra inputs wired from
# variables (app ids by reference, never committed). See
# docs/specs/v1-tracer-bullet.md, Delivery shape and Identity provisioning.

variable "resource_group_name" {
  type        = string
  description = "Name of the (out-of-band) resource group this composition deploys into. Expected to carry the ephemeral expiry tag's matching lifecycle in the live-test environment."
}

variable "location" {
  type        = string
  description = "Azure region for every resource this composition creates."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource this composition creates, expected to include the ephemeral expiry tag used by the cleanup sweep."
  default     = {}
}

variable "name_prefix" {
  type        = string
  description = "Prefix used to derive resource names (service plan, function app). Passed straight through to mcp-function-host."
}

variable "deployment_profile" {
  type        = string
  description = "Selects a named sizing profile for this composition. Only \"public-demo\" is in v1 scope; the variable exists so a later profile (e.g. a private-network variant in v1.1) is additive, not a restructure."
  default     = "public-demo"

  validation {
    condition     = contains(["public-demo"], var.deployment_profile)
    error_message = "deployment_profile must be \"public-demo\": the only profile in v1 scope (docs/specs/v1-tracer-bullet.md, Out of Scope)."
  }
}

variable "storage_account_name" {
  type        = string
  description = "Name of the Flex Consumption deployment storage account. Passed straight through to mcp-function-host (existing account by default; see create_storage_account)."
}

variable "create_storage_account" {
  type        = bool
  description = "Whether this composition has mcp-function-host create storage_account_name (true) or expects it to already exist (false, the default)."
  default     = false
}

variable "entra_auth" {
  type = object({
    tenant_id              = string
    server_app_client_id   = string
    allowed_audiences      = list(string)
    unauthenticated_action = optional(string, "Return401")
  })
  description = "Entra built-in auth (Easy Auth) settings for the Function App, passed straight through to mcp-function-host. Values reference the out-of-band server resource app registration (docs/runbooks/entra-app-registrations.md); no app id is committed here or given a default."
}

variable "prm_scope" {
  type        = string
  description = "OAuth scope surfaced via WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES, e.g. api://<server-app-id>/user_impersonation. Passed straight through to mcp-function-host."
}

variable "app_settings" {
  type        = map(string)
  description = "Additional app settings merged in alongside mcp-function-host's own. Empty by default; the tracer needs none beyond what the module sets."
  default     = {}
}

# --- Issue 10 (OBO thickening): downstream Orders API, referenced inputs ---
# The downstream app registration is provisioned out of band, the same
# pattern as entra_auth above (docs/runbooks/obo-app-registrations.md); no
# app id or scope value is committed or given a default.

variable "downstream_app" {
  type = object({
    client_id = string
    api_scope = string
  })
  description = "The out-of-band downstream (Orders API) app registration, referenced by id: client_id is its application (client) id (also used by the azuread_service_principal_delegated_permission_grant and data \"azuread_service_principal\" \"downstream\" in main.tf), api_scope is the delegated scope the OBO exchange requests (api://<downstream-app-id>/user_impersonation -- the same scope main.tf's azuread_service_principal_delegated_permission_grant admin-consents for the server app; OBO's AcquireTokenOnBehalfOf needs the specific consented delegated scope, not a .default app-only scope). api_scope is wired into the MCP server's DownstreamOrdersApi__Scope app setting, read by McpTools.Downstream.ManagedIdentityOboTokenAcquirer via GetOrderStatus.Run."
}

variable "downstream_entra_auth" {
  type = object({
    tenant_id              = string
    server_app_client_id   = string
    allowed_audiences      = list(string)
    unauthenticated_action = optional(string, "Return401")
  })
  description = "Entra built-in auth (Easy Auth) settings for the downstream Orders API's own Function App instance, passed straight through to its mcp-function-host instantiation. allowed_audiences is scoped to ONLY the downstream app (docs/runbooks/obo-app-registrations.md): this is what makes the negative test meaningful (a token minted for the MCP server app has a different audience and is rejected by the platform)."
}

variable "downstream_storage_account_name" {
  type        = string
  description = "Name of the downstream Orders API instance's Flex Consumption deployment storage account. Passed straight through to its mcp-function-host instantiation (existing account by default; see downstream_create_storage_account)."
}

variable "downstream_create_storage_account" {
  type        = bool
  description = "Whether this composition has the downstream instantiation create downstream_storage_account_name (true) or expects it to already exist (false, the default)."
  default     = false
}
