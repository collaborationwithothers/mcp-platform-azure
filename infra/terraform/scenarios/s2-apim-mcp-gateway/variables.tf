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
  description = "Inbound Entra ID token validation applied at server scope, passed straight through to both apim-mcp-server instances (shared registration and audience). Only tenant_id feeds the PRM documents, and only as the authorization_server (issuer) URL; each PRM document's resource is the MCP SERVER URL, NOT the token audience (see local.prm in main.tf and RFC 9728 s3.3). References the out-of-band server resource app and test client app registrations (docs/runbooks/entra-app-registrations.md); no app id is committed here or given a default."
}

variable "prm_scopes" {
  type        = list(string)
  description = "OAuth scopes surfaced in server 1's PRM document scopes_supported (the api://<server-app-id>/<scope> form), e.g. [\"api://<server-app-id>/user_impersonation\"]. Server 1's PRM advertises only its own scope; server 2 uses server_2_prm_scopes."
}

# Per-server entitlement (issue 17). server 1 keeps the composition's existing
# unprefixed variable names (server_name, server_path, prm_scopes) because the
# live gate reads those keys from the s2 tfvars and drives API Center
# convergence by server_name; server 2 is the additive server_2_* set. required_*
# are the claim VALUES as they appear in the token (scp short name; roles value),
# supplied out-of-band via tfvars, never committed. See
# docs/runbooks/entra-app-registrations.md.
variable "required_scope" {
  type        = string
  description = "Server 1's per-server delegated scope value (as it appears in the token scp claim). apim-mcp-server checks scp contains this OR roles contains required_role."
}

variable "required_role" {
  type        = string
  description = "Server 1's per-server app role value (as it appears in the token roles claim). Checked with OR semantics against required_scope."
}

variable "server_2_name" {
  type        = string
  description = "Resource name of the second MCP server API (apim-mcp-server's server_name input for server 2). Unique within the API Management service."
}

variable "server_2_path" {
  type        = string
  description = "Path segment the second MCP server is exposed under (apim-mcp-server's server_path input for server 2). Must differ from server_path."

  validation {
    condition     = var.server_2_path != var.server_path
    error_message = "server_2_path must differ from server_path: two servers on one gateway need distinct paths so each gets its own RFC 9728 s3.1 path-inserted PRM location (issue 17)."
  }
}

variable "server_2_prm_scopes" {
  type        = list(string)
  description = "OAuth scopes surfaced in server 2's PRM document scopes_supported (the api://<server-app-id>/<scope> form). Server 2's PRM advertises only its own scope."
}

variable "server_2_required_scope" {
  type        = string
  description = "Server 2's per-server delegated scope value (as it appears in the token scp claim). apim-mcp-server checks scp contains this OR roles contains server_2_required_role."
}

variable "server_2_required_role" {
  type        = string
  description = "Server 2's per-server app role value (as it appears in the token roles claim). Checked with OR semantics against server_2_required_scope."
}

# Per-tool authorization (issue 18). Same unprefixed/server_2_* convention as
# required_scope/required_role above. Each map is the hand-maintained
# passthrough provenance for that server's tool surface. Three tools today, all
# under src/McpTools/Tools/: get_order_status gated on the Orders.Read app role,
# get_service_info (issue 79) on ServiceInfo.Read -- both matching the issue-45
# MCP-layer checks they sit in front of -- and get_access_guidance (issue 82)
# mapped unrestricted = true, which applies no per-tool check at all and is the
# only tool exercising that branch of the policy fragment. The live gate's
# per-server set-equality assertion is what proves this map has not drifted from
# the deployed server's tools/list; ADR-009.
variable "tool_authorization_map" {
  type = map(object({
    scope        = optional(string)
    role         = optional(string)
    unrestricted = optional(bool, false)
  }))
  description = "Server 1's total map of MCP tool name to required scope, role, or unrestricted marker (apim-mcp-server's tool_authorization_map input)."
}

variable "server_2_tool_authorization_map" {
  type = map(object({
    scope        = optional(string)
    role         = optional(string)
    unrestricted = optional(bool, false)
  }))
  description = "Server 2's total map of MCP tool name to required scope, role, or unrestricted marker (apim-mcp-server's tool_authorization_map input for server 2)."
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

variable "shared_observability_application_insights_id" {
  type        = string
  description = "ARM resource ID of the out-of-band workspace-based Application Insights resource shared by the scenarios. The composition derives its WorkspaceResourceId for APIM diagnostic settings and passes the resource ID to apim-gateway for its Application Insights ConnectionString lookup. Supplied as TF_VAR_shared_observability_application_insights_id on the live-test GitHub Environment; never committed."
}

variable "data_reader_principal_ids" {
  type        = list(string)
  description = "Object ids of Entra principals to grant Azure API Center Data Reader on the registry instance (passed to api-center-registry) AND Log Analytics Data Reader plus Event Hubs Data Receiver on the audit resources (passed to apim-gateway, issue 18), so the same principal can run the ticket-5 bounded registry poll, and the live gate's audit-event check against the ephemeral Event Hub (KQL against the durable Application Insights trail also remains available with the same grant)."
  default     = []
}
