# S1 scenario composition: the Entra-secured .NET Functions MCP server, on its
# own. See docs/specs/v1-tracer-bullet.md, Delivery shape ("Composition
# interface"). This composition owns no resources of its own beyond the
# mcp-function-host instance; sizing varies only by var.deployment_profile.

locals {
  # Only "public-demo" exists in v1 scope (see variables.tf validation); the
  # map exists so a later profile is an added entry, not a restructure.
  profile_flex_consumption = {
    "public-demo" = {
      instance_memory_mb     = 2048
      maximum_instance_count = 40
    }
  }
}

module "mcp_function_host" {
  source = "../../modules/mcp-function-host"

  name_prefix         = var.name_prefix
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  storage_account_name   = var.storage_account_name
  create_storage_account = var.create_storage_account
  flex_consumption       = local.profile_flex_consumption[var.deployment_profile]

  entra_auth   = var.entra_auth
  prm_scope    = var.prm_scope
  app_settings = var.app_settings
}
