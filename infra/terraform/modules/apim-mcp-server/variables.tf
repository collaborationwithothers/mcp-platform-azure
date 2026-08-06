# Thick interface: every input is present even though the tracer only
# exercises passthrough streamable transport with no products, so later
# thickening (SSE backends, multiple products, additional client apps)
# extends this contract without restructuring it. See
# docs/specs/v1-tracer-bullet.md, Delivery shape and Gateway and
# authorization (S2).

variable "apim_id" {
  type        = string
  description = "ARM resource ID of the parent API Management service (apim-gateway's apim_id output)."
}

variable "server_name" {
  type        = string
  description = "Resource name of the MCP server API. Must be unique within the API Management service."
}

variable "server_path" {
  type        = string
  description = "Path segment the MCP server is exposed under (e.g. \"mcp-server\"), giving mcp_server_url of the form https://<gateway>/<server_path>/mcp."
}

variable "backend_service_url" {
  type        = string
  description = "Base URL of the external MCP backend this passthrough server forwards to (mcp-function-host's mcp_backend_base_url output)."
}

variable "transport" {
  type = object({
    type = optional(string, "streamable")
    endpoints = optional(list(object({
      name         = string
      uri_template = string
    })), [{ name = "mcp", uri_template = "/mcp" }])
  })
  description = "MCP transport exposed to clients. \"streamable\" (the tracer's default) has a single endpoint; \"sse\" has two. The endpoint name is the mcpProperties.endpoints map key. The deployed 2025-09-01-preview stamp keys the streamable endpoint \"mcp\" (verified against a portal-created reference server 2026-07-16), not \"message\" as the published swagger shows."
  default     = {}

  validation {
    condition     = contains(["streamable", "sse"], var.transport.type)
    error_message = "transport.type must be \"streamable\" or \"sse\"."
  }

  validation {
    condition = (
      (var.transport.type == "streamable" && length(var.transport.endpoints) == 1) ||
      (var.transport.type == "sse" && length(var.transport.endpoints) == 2)
    )
    error_message = "streamable transport requires exactly one endpoint; sse transport requires exactly two."
  }
}

variable "subscription_required" {
  type        = bool
  description = "Whether a product subscription key is required to call the server. false in the tracer (no products or subscriptions); binding a product later via product_ids is additive config, not a restructure. See docs/specs/v1-tracer-bullet.md, Gateway and authorization (S2)."
  default     = false
}

variable "entra_validation" {
  type = object({
    tenant_id                      = string
    audience                       = string
    allowed_client_application_ids = list(string)
  })
  description = "Inbound Entra ID token validation applied at server scope. audience is the server app's App ID URI. allowed_client_application_ids must be non-empty."

  validation {
    condition     = length(var.entra_validation.allowed_client_application_ids) > 0
    error_message = "entra_validation.allowed_client_application_ids must include at least one client application ID."
  }
}

# Per-server entitlement (issue 17). The instantiate-twice contract carries
# per-server entitlement, not one shared entitlement: each apim-mcp-server
# instance requires its OWN delegated scope and app role under the shared Entra
# registration, so a caller granted one server's scope is rejected at the other.
# Both are the claim VALUES as they appear in the validated token, not the full
# App ID URI: required_scope is a value of the space-delimited scp claim (the
# short scope name, e.g. "mcp.orders.invoke"); required_role is a value of the
# roles claim (the app role value, e.g. "Mcp.Orders.Invoke"). The server-scope
# policy accepts a caller only if scp contains required_scope OR roles contains
# required_role (OR, because a delegated token carries scp and no roles, an
# app-only token the reverse). Advertised only in this server's PRM document.
variable "required_scope" {
  type        = string
  description = "Delegated scope value (as it appears in the token scp claim) this server requires. Checked with OR semantics against required_role after token validation. Supplied by the composition from the shared server app's per-server scope; the value is out-of-band (tfvars), never committed. See docs/runbooks/entra-app-registrations.md."

  validation {
    condition     = length(trimspace(var.required_scope)) > 0
    error_message = "required_scope must be a non-empty scope value (the per-server delegated scope name that appears in the token scp claim)."
  }
}

variable "required_role" {
  type        = string
  description = "App role value (as it appears in the token roles claim) this server requires. Checked with OR semantics against required_scope after token validation. Supplied by the composition from the shared server app's per-server app role; the value is out-of-band (tfvars), never committed. See docs/runbooks/entra-app-registrations.md."

  validation {
    condition     = length(trimspace(var.required_role)) > 0
    error_message = "required_role must be a non-empty app role value (the per-server app role that appears in the token roles claim)."
  }
}

variable "product_ids" {
  type        = list(string)
  description = "Existing product resource names to bind this MCP server to. Empty in the tracer (spec: subscriptionRequired is false, no products); binding a product is additive config appended to this list, not a restructure of the server resource."
  default     = []
}

# Per-tool authorization (issue 18). A TOTAL map: every tool name this server
# exposes must have exactly one entry, or the fragment default-denies it. This
# is the hand-maintained (passthrough) provenance -- the backend owns the tool
# surface, so this copy can drift from it; the live gate's per-server
# set-equality assertion (tools/list vs this map's keys, both directions) is
# what catches that drift, not this variable. See docs/specs/thickening.md,
# "Per-tool authorization and tool blocking (#18)", and ADR-009.
variable "tool_authorization_map" {
  type = map(object({
    # Claim VALUES as they appear in the validated token, matching
    # required_scope/required_role above: scope is a value of the
    # space/comma-delimited scp claim, role is a value of the roles claim.
    # Checked with OR semantics (a delegated token carries scp and no roles,
    # an app-only token the reverse), same as the per-server entitlement
    # check this fragment runs after.
    scope = optional(string)
    role  = optional(string)
    # Explicit escape hatch for a tool that is deliberately open to any
    # caller who already cleared the per-server entitlement check. Not a
    # default -- every entry sets this true or supplies scope/role, so an
    # entry can never accidentally fall through unrestricted.
    unrestricted = optional(bool, false)
  }))
  description = "Total map of MCP tool name to required scope, required role, or an explicit unrestricted marker. Gates tools/call only; any tool name not present as a key is default-denied by the fragment. See ADR-009."

  validation {
    condition = alltrue([
      for name, claim in var.tool_authorization_map :
      claim.unrestricted || claim.scope != null || claim.role != null
    ])
    error_message = "Every tool_authorization_map entry must set unrestricted = true, or a non-null scope, or a non-null role."
  }
}
