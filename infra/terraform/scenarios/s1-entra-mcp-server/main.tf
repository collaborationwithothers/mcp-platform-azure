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

  entra_auth = var.entra_auth
  prm_scope  = var.prm_scope
  # DownstreamOrdersApi__* settings are read by
  # McpTools.Downstream.ManagedIdentityOboTokenAcquirer /
  # DownstreamOrdersClient. Not currently consumed by GetOrderStatus.Run
  # (see its doc comment and ADR-006, "OBO exchange: the inbound-token
  # gap"); wired here so the settings exist ahead of that gap closing.
  app_settings = merge(var.app_settings, {
    DownstreamOrdersApi__BaseUrl  = module.downstream_orders_api.base_url
    DownstreamOrdersApi__ClientId = var.downstream_app.client_id
    DownstreamOrdersApi__Scope    = var.downstream_app.api_scope
  })
}

# Issue 10 (OBO thickening): the synthetic downstream Orders API
# (src/DownstreamOrdersApi), reusing mcp-function-host per its README
# ("Issue 10: reused for the downstream Orders API instance") rather than a
# new module -- it is the same shape (one Flex Consumption Function App,
# Easy Auth-gated), just with a different, narrower entra_auth and no MCP
# PRM scope. name_prefix is suffixed so both instances get distinct,
# derived names without a new mandatory variable.
module "downstream_orders_api" {
  source = "../../modules/mcp-function-host"

  name_prefix         = "${var.name_prefix}-downstream"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  storage_account_name   = var.downstream_storage_account_name
  create_storage_account = var.downstream_create_storage_account
  flex_consumption       = local.profile_flex_consumption[var.deployment_profile]

  entra_auth = var.downstream_entra_auth
  prm_scope  = null
}
