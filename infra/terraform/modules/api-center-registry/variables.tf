# Thick interface: every input is present even though the tracer only exercises
# a single default workspace, one Azure API Management environment, and
# anonymous registry read access, so later thickening (user-assigned identity,
# multiple environments, Entra-gated read access, Git-repo sources) extends
# this contract without restructuring it. See docs/specs/v1-tracer-bullet.md,
# Delivery shape and Registry (S3).

variable "name" {
  type        = string
  description = "Resource name of the API Center service. Also the leftmost label of the data-plane registry hostname (https://<name>.data.<region>.azure-apicenter.ms/...), so it must be a valid API Center name (3-90 chars, letters/digits/hyphens)."

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{3,90}$", var.name))
    error_message = "name must be 3-90 characters of letters, digits, or hyphens (Microsoft.ApiCenter/services name constraint)."
  }
}

variable "location" {
  type        = string
  description = "Azure region for the API Center service. Also determines the data-plane registry hostname region segment; the module normalizes it (lowercase, spaces removed) so both \"East US\" and \"eastus\" yield \"eastus\". Re-verify the derived hostname at the live gate (COMPATIBILITY.md)."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group the API Center service is created in. Assumed to live in the same subscription as apim_source_id (the tracer composition deploys API Center and APIM together); the module derives that subscription id from apim_source_id to build the service's parent resource-group id."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the API Center service (a tracked resource). Child resources (workspace, environment, api source) are proxy resources and take no tags."
  default     = {}
}

variable "apim_source_id" {
  type        = string
  description = "ARM resource ID of the API Management instance to auto-sync from (apim-gateway's apim_id output). Its MCP servers populate this API center's inventory automatically. The subscription segment of this id is reused as the API Center service's subscription."

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.ApiManagement/service/[^/]+$", var.apim_source_id))
    error_message = "apim_source_id must be a full Microsoft.ApiManagement/service ARM resource ID."
  }
}

variable "environment" {
  type = object({
    title                 = string
    kind                  = optional(string, "development")
    server_type           = optional(string, "Azure API Management")
    management_portal_uri = optional(list(string), [])
  })
  description = "The API Center environment representing where the MCP server is deployed. For the tracer the server is fronted by API Management, so server_type defaults to \"Azure API Management\". title is required (1-50 chars); kind is one of development/production/staging/testing. This is the environment the register-discover-mcp-server docs require a remote MCP server to be associated with."

  validation {
    condition     = length(var.environment.title) >= 1 && length(var.environment.title) <= 50
    error_message = "environment.title must be 1-50 characters (Microsoft.ApiCenter environment title constraint)."
  }

  validation {
    condition     = contains(["development", "production", "staging", "testing"], var.environment.kind)
    error_message = "environment.kind must be one of development, production, staging, testing."
  }

  validation {
    condition = contains([
      "Apigee API Management", "AWS API Gateway", "Azure API Management",
      "Azure compute service", "Kong API Gateway", "Kubernetes", "MuleSoft API Management"
    ], var.environment.server_type)
    error_message = "environment.server_type must be one of the Microsoft.ApiCenter EnvironmentServer types (e.g. \"Azure API Management\")."
  }
}

variable "deployment" {
  type = object({
    import_specification   = optional(string, "always")
    target_lifecycle_stage = optional(string, "production")
  })
  description = "Deployment metadata for the servers synced into the registry. import_specification controls whether API specifications are imported alongside metadata (always/never/ondemand); target_lifecycle_stage is the lifecycle stage the synced entries are published at. Both are properties of the APIM api source (auto-sync), not of any manually created server."
  default     = {}

  validation {
    condition     = contains(["always", "never", "ondemand"], var.deployment.import_specification)
    error_message = "deployment.import_specification must be one of always, never, ondemand."
  }

  validation {
    condition = contains([
      "design", "development", "testing", "preview", "production", "deprecated", "retired"
    ], var.deployment.target_lifecycle_stage)
    error_message = "deployment.target_lifecycle_stage must be a Microsoft.ApiCenter lifecycle stage (design/development/testing/preview/production/deprecated/retired)."
  }
}

variable "data_reader_principal_ids" {
  type        = list(string)
  description = <<-EOT
    Object ids of Entra principals to grant the Azure API Center Data Reader
    role on this API Center instance, so they can read the data-plane MCP
    registry endpoint with an authenticated call. The tracer passes the OIDC
    principal that runs ticket 5's bounded poll.

    Why RBAC and not an access-mode input: the registry endpoint's read-access
    mode (authenticated vs anonymous) is NOT settable through the
    Microsoft.ApiCenter azapi surface in any published API version as of
    2026-07-12 (2023-07-01-preview, 2024-03-01, 2024-03-15-preview,
    2024-06-01-preview; see README.md and COMPATIBILITY.md). The default posture
    is authenticated (anonymous requests 401), so the module grants read access
    via this role rather than exposing an access-mode toggle. Anonymous read, if
    ever wanted, is a portal-only opt-in
    (docs/runbooks/registry-anonymous-access.md) and is not used by this
    deployment.

    Default [] grants nothing. Each id is treated as a service principal
    (principalType ServicePrincipal), matching an OIDC/CI identity. Assigning the
    role needs the deploying principal to hold roleAssignments/write on this
    instance at the live gate (docs/runbooks/live-test-gate.md).
  EOT
  default     = []
}

variable "assign_apim_reader_role" {
  type        = bool
  description = "Whether this module assigns the API Center service's system-assigned identity the API Management Service Reader role on apim_source_id. This is the access auto-sync needs to import APIs from APIM (per the synchronize-api-management-apis docs). Default true so auto-sync is self-contained and production-correct; set false only if the composition grants that role out of band. Applying it requires the deploying principal to hold role-assignment-write (for example User Access Administrator) on the APIM scope at the live gate."
  default     = true
}
