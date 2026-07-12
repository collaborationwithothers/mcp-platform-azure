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

variable "prm" {
  type = object({
    resource             = string
    authorization_server = string
    scopes               = list(string)
  })
  description = "Contents of the single RFC 9728 protected resource metadata (PRM) document this gateway serves at its root well-known path. Singular values for exactly one document (not a map): resource is the protected resource identifier, authorization_server is the OAuth authorization server (issuer) URL rendered into authorization_servers[0], and scopes becomes scopes_supported. The composition supplies these from the MCP server's identity values. The multi-server, path-suffixed PRM form is a documented ADR growth path, not this interface."
}
