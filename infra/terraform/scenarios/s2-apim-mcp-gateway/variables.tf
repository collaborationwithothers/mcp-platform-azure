# S2 composition: instantiates apim-gateway + apim-mcp-server +
# api-center-registry, consuming s1-entra-mcp-server's mcp_backend_base_url
# via terraform_remote_state. See docs/specs/v1-tracer-bullet.md, Delivery
# shape and Registry (S3).

variable "resource_group_name" {
  type        = string
  description = "Name of the (out-of-band) resource group this composition deploys into. Assumed to be the same subscription as s1_remote_state's backend, and the group api-center-registry's derived subscription id must match."
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

variable "deployment_profile" {
  type        = string
  description = "Selects a named profile for this composition. Only \"public-demo\" is in v1 scope; public-demo selects the Basic v2 APIM SKU and public endpoints from the same modules. The variable exists so a later profile (e.g. the v1.1 private-network variant) is additive, not a restructure."
  default     = "public-demo"

  validation {
    condition     = contains(["public-demo"], var.deployment_profile)
    error_message = "deployment_profile must be \"public-demo\": the only profile in v1 scope (docs/specs/v1-tracer-bullet.md, Out of Scope)."
  }
}

variable "s1_remote_state" {
  type = object({
    storage_account_name = string
    container_name       = string
    key                  = string
  })
  description = <<-EOT
    azurerm backend config identifying the s1-entra-mcp-server composition's
    state, so this composition can read its mcp_backend_base_url output via
    terraform_remote_state. Read access uses use_azuread_auth (OIDC), matching
    this composition's own backend.tf; no account name or key is hardcoded, so
    the live-test workflow supplies these as the same values it passed to
    s1-entra-mcp-server's own -backend-config at that composition's apply.
  EOT
}

variable "apim_name" {
  type        = string
  description = "Name of the API Management service (apim-gateway's name input)."
}

variable "publisher_name" {
  type        = string
  description = "Name of the API Management publisher/company (apim-gateway's publisher_name input)."
}

variable "publisher_email" {
  type        = string
  description = "Email address of the API Management publisher (apim-gateway's publisher_email input)."
}

variable "server_name" {
  type        = string
  description = "Resource name of the MCP server API (apim-mcp-server's server_name input)."
}

variable "server_path" {
  type        = string
  description = "Path segment the MCP server is exposed under (apim-mcp-server's server_path input)."
}

variable "entra_validation" {
  type = object({
    tenant_id                      = string
    audience                       = string
    allowed_client_application_ids = list(string)
  })
  description = "Inbound Entra ID token validation applied at server scope, passed straight through to apim-mcp-server. Also used to derive the gateway-root PRM document (resource = audience, authorization_server from tenant_id): see local.prm in main.tf. References the out-of-band server resource app and test client app registrations (docs/runbooks/entra-app-registrations.md); no app id is committed here or given a default."
}

variable "prm_scopes" {
  type        = list(string)
  description = "OAuth scopes surfaced in the gateway-root protected resource metadata document's scopes_supported, e.g. [\"api://<server-app-id>/user_impersonation\"]."
}

variable "registry_name" {
  type        = string
  description = "Base name (prefix) of the API Center service. The composition appends a short suffix derived from resource_group_name to form the actual, globally-unique service name (api-center-registry's name input), because API Center names form a global data-plane DNS label and, once soft-deleted, stay reserved with no working purge. Keep this short enough that base + '-' + 8 chars stays within the 63-char DNS label and 90-char API Center name limits."
}

variable "registry_environment" {
  type = object({
    title                 = string
    kind                  = optional(string, "development")
    server_type           = optional(string, "Azure API Management")
    management_portal_uri = optional(list(string), [])
  })
  description = "The API Center environment representing where the MCP server is deployed, passed straight through to api-center-registry."
}

variable "registry_deployment" {
  type = object({
    import_specification   = optional(string, "always")
    target_lifecycle_stage = optional(string, "production")
  })
  description = "Deployment metadata for the servers synced into the registry, passed straight through to api-center-registry."
  default     = {}
}

variable "data_reader_principal_ids" {
  type        = list(string)
  description = "Object ids of Entra principals to grant Azure API Center Data Reader on the registry instance, passed straight through to api-center-registry. The tracer passes the gated live-test OIDC principal that runs ticket 5's bounded poll."
  default     = []
}
