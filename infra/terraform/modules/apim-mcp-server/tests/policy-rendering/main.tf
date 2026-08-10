# Self-contained fixture for policy_rendering.tftest.hcl (issue 83). Declares
# no providers and no resources -- it exists only to call templatefile() on
# the REAL shipped mcp-server.xml with a fixture tool_authorization_map, so
# the test exercises the same rendering path main.tf uses, not a
# reimplementation of the template's logic. Kept as its own root module
# (rather than a tests/ subdirectory of apim-mcp-server itself) so
# `terraform test` here never touches that module's azapi provider
# requirement or needs Azure credentials.

variable "tool_authorization_map" {
  type = map(object({
    scope        = optional(string)
    role         = optional(string)
    unrestricted = optional(bool, false)
  }))
}

output "rendered_policy" {
  value = templatefile("${path.module}/../../policies/mcp-server.xml", {
    tenant_id                      = "00000000-0000-0000-0000-000000000000"
    audience                       = "api://fixture-server-app"
    allowed_client_application_ids = ["00000000-0000-0000-0000-000000000001"]
    prm_root_url                   = "https://fixture.example/.well-known/oauth-protected-resource"
    prm_server_url                 = "https://fixture.example/orders/.well-known/oauth-protected-resource"
    required_scope                 = "Orders.Invoke"
    required_role                  = "Orders.Invoke.All"
    tool_authorization_map         = var.tool_authorization_map
    eventhub_logger_name           = "fixture-eventhub-logger"
  })
}
