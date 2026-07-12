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
    })), [{ name = "message", uri_template = "/mcp" }])
  })
  description = "MCP transport exposed to clients. \"streamable\" (the tracer's default) requires exactly one \"message\" endpoint; \"sse\" requires exactly two endpoints named \"sse\" and \"message\" (Microsoft Learn, manage-mcp-servers-rest-api)."
  default     = {}

  validation {
    condition     = contains(["streamable", "sse"], var.transport.type)
    error_message = "transport.type must be \"streamable\" or \"sse\"."
  }

  validation {
    condition = (
      (var.transport.type == "streamable" && length(var.transport.endpoints) == 1 && var.transport.endpoints[0].name == "message") ||
      (var.transport.type == "sse" && length(var.transport.endpoints) == 2 && contains([for e in var.transport.endpoints : e.name], "sse") && contains([for e in var.transport.endpoints : e.name], "message"))
    )
    error_message = "streamable transport requires exactly one endpoint named \"message\"; sse transport requires exactly two endpoints named \"sse\" and \"message\"."
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

variable "product_ids" {
  type        = list(string)
  description = "Existing product resource names to bind this MCP server to. Empty in the tracer (spec: subscriptionRequired is false, no products); binding a product is additive config appended to this list, not a restructure of the server resource."
  default     = []
}
