# Thick interface: every input is present even though the tracer only
# exercises a subset (public-demo, Basic v2, system-assigned identity), so
# later thickening (private profile, additional locations, user-assigned
# identity for cross-resource auth) extends this contract without
# restructuring it. See docs/specs/v1-tracer-bullet.md, Delivery shape.

variable "name" {
  type        = string
  description = "Name of the API Management service."
}

variable "location" {
  type        = string
  description = "Azure region for the API Management service."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group the service is deployed into. The resource group itself is out of band."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the API Management service. Expected to include the ephemeral expiry tag used by the cleanup sweep (see docs/specs/v1-tracer-bullet.md, Ephemeral)."
  default     = {}
}

variable "sku_name" {
  type        = string
  description = "SKU of the API Management service, as \"<tier>_<capacity>\" (e.g. \"BasicV2_1\"). Defaults to the public-demo tracer profile (Basic v2, capacity 1); a later scenario composition can drive a different profile without changing this module. See COMPATIBILITY.md for the issue-3 AVM capability check confirming Basic v2 support."
  default     = "BasicV2_1"

  validation {
    condition     = can(regex("^(Consumption|Developer|Basic|BasicV2|Standard|StandardV2|Premium|PremiumV2)_[0-9]+$", var.sku_name))
    error_message = "sku_name must be \"<tier>_<capacity>\" where tier is one of Consumption, Developer, Basic, BasicV2, Standard, StandardV2, Premium, PremiumV2 (azurerm_api_management sku_name format)."
  }
}

variable "publisher_name" {
  type        = string
  description = "Name of the API Management publisher/company."
}

variable "publisher_email" {
  type        = string
  description = "Email address of the API Management publisher."
}

# "None" (the module default) keeps the public-demo profile unchanged.
# private-backend sets this to "External" -- outbound-only VNet integration,
# so APIM's own gateway host stays publicly reachable while it can reach a
# backend isolated inside the virtual network. "Internal" (classic VNet
# injection) is deliberately not this variable's private-backend value: the
# AGENTS.md scope carve-out for epic 108 child (b) is explicit that "APIM's
# own gateway host stays publicly reachable" and "APIM gets no inbound
# private endpoint" -- "Internal" would violate both, and is documented as
# rejected for Standard v2 specifically (COMPATIBILITY.md, "APIM Standard v2
# outbound VNet integration").
variable "virtual_network_type" {
  type        = string
  description = "Virtual network configuration type for this API Management service. \"None\" (default, public-demo) or \"External\" (private-backend: outbound-only integration, gateway host stays public)."
  default     = "None"

  validation {
    condition     = contains(["None", "External"], var.virtual_network_type)
    error_message = "virtual_network_type must be \"None\" or \"External\" (this module never sets \"Internal\": that is classic VNet injection, out of scope per AGENTS.md's epic 108 child (b) carve-out, and documented as rejected for Standard v2)."
  }
}

variable "virtual_network_subnet_id" {
  type        = string
  description = "ARM resource ID of the delegated subnet for outbound VNet integration (private-network module's apim_outbound_subnet_id output). Required when virtual_network_type is \"External\"; null for public-demo."
  default     = null

  validation {
    condition     = var.virtual_network_type != "External" || var.virtual_network_subnet_id != null
    error_message = "virtual_network_subnet_id is required when virtual_network_type is \"External\"."
  }
}

# tenant_id is a required input of this module's thick interface per the
# issue-3 apim-gateway interface spec, even though nothing in the tracer
# consumes it yet (Entra token validation is owned by apim-mcp-server's
# server-scope policy, not the gateway resource). Removing it to satisfy the
# linter would break the interface contract later modules and compositions
# depend on; suppressing the unused-declaration warning is the intended
# trade-off. See docs/specs/v1-tracer-bullet.md, Delivery shape.
# The tflint-ignore annotation must sit on the line directly above the
# declaration to take effect.
# tflint-ignore: terraform_unused_declarations
variable "tenant_id" {
  type        = string
  description = "Microsoft Entra tenant ID this gateway's callers authenticate against. Not consumed by this module today (Entra token validation is owned by apim-mcp-server's server-scope policy, not the gateway resource itself); present for thick-interface completeness and any future management-plane Entra wiring."
}

variable "shared_observability_application_insights_id" {
  type        = string
  description = "ARM resource ID of the out-of-band Application Insights resource that receives per-tool deny audit events (issue 18). Must be created before the first live run per docs/runbooks/observability-bootstrap.md; lives in a stable resource group never tagged for the ephemeral-env cleanup sweep. Supplied as TF_VAR_shared_observability_application_insights_id on the live-test GitHub Environment; never committed."

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/[Mm]icrosoft\\.[Ii]nsights/components/[^/]+$", var.shared_observability_application_insights_id))
    error_message = "shared_observability_application_insights_id must be a valid Microsoft.Insights/components ARM resource ID."
  }
}

variable "log_analytics_workspace_id" {
  type        = string
  nullable    = false
  description = "ARM resource ID of the out-of-band Log Analytics workspace that receives mandatory APIM service and Event Hubs namespace diagnostic settings."

  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/[Mm]icrosoft\\.[Oo]perational[Ii]nsights/workspaces/[^/]+$", var.log_analytics_workspace_id))
    error_message = "log_analytics_workspace_id must be a valid Microsoft.OperationalInsights/workspaces ARM resource ID."
  }
}

variable "data_reader_principal_ids" {
  type        = list(string)
  description = "Object ids of Entra principals to grant Log Analytics Data Reader on the shared observability workspace and Event Hubs Data Receiver on the ephemeral audit Event Hub (issue 18), so they can read back a per-tool deny's audit signal -- the KQL path for the durable Application Insights trail, and the Event Hub path the live gate's pass/fail check actually reads (see ADR-009 and Assert-AuditEventEmitted). The live gate passes the same OIDC principal already granted API Center Data Reader (see api-center-registry's data_reader_principal_ids). Empty list (default) => no grants."
  default     = []
}

variable "prm" {
  type = object({
    authorization_server = string
    root = object({
      resource = string
      scopes   = list(string)
    })
    servers = list(object({
      resource = string
      scopes   = list(string)
    }))
  })
  description = "RFC 9728 protected resource metadata (PRM) this gateway serves, as a per-server collection (issue 17). authorization_server is the shared OAuth authorization server (issuer) URL rendered into authorization_servers[0] of every document. root describes the primary server and is served at the gateway root well-known location; a client that falls back to root while targeting another server sees a resource mismatch and MUST discard it under RFC 9728 s3.3 (the retained-root fail-closed guard). servers is the full set of MCP servers behind this gateway (including the primary): each whose resource carries a path gets its OWN document served at the RFC 9728 s3.1 path-inserted well-known location for that resource, via an operation-scoped policy. resource is the MCP server URL the client connects to (what a spec client validates the document against), NOT the token audience; scopes becomes that server's scopes_supported. Multi-server is the composition instantiating apim-mcp-server more than once; this collection is how the singleton gateway advertises each per RFC 9728's own multi-resource construction (ADR-006, issue 17)."
}
