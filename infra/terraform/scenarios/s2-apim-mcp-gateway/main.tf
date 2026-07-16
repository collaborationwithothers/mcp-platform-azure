# S2 scenario composition: the multi-tenant APIM MCP gateway (public-demo
# profile), fronting the S1 backend. See
# docs/specs/v1-tracer-bullet.md, Delivery shape ("Composition interface").

# Reads s1-entra-mcp-server's mcp_backend_base_url output. Both compositions
# share one azurerm backend storage account (key-per-composition isolation);
# this data source targets the OTHER composition's key, read-only,
# OIDC-authenticated the same way as this composition's own backend.tf.
data "terraform_remote_state" "s1" {
  backend = "azurerm"

  config = {
    storage_account_name = var.s1_remote_state.storage_account_name
    container_name       = var.s1_remote_state.container_name
    key                  = var.s1_remote_state.key
    use_oidc             = true
    use_azuread_auth     = true
  }
}

locals {
  # Only "public-demo" exists in v1 scope (see variables.tf validation); the
  # map exists so a later profile is an added entry, not a restructure.
  profile_sku = {
    "public-demo" = "BasicV2_1"
  }

  mcp_backend_base_url = data.terraform_remote_state.s1.outputs.mcp_backend_base_url

  # The gateway-root PRM document's contents describe this server: resource
  # is the server app's App ID URI (the same audience apim-mcp-server
  # validates against), authorization_server is the Entra v2.0 issuer for
  # entra_validation.tenant_id. docs/specs/v1-tracer-bullet.md, Gateway and
  # authorization (S2).
  prm = {
    resource             = var.entra_validation.audience
    authorization_server = "https://login.microsoftonline.com/${var.entra_validation.tenant_id}/v2.0"
    scopes               = var.prm_scopes
  }

  # API Center service names are GLOBAL: var.registry_name is the leftmost label
  # of the data-plane DNS name (<name>.data.<region>.azure-apicenter.ms). Once a
  # service is destroyed the name stays reserved by a soft-delete tombstone that
  # has no working programmatic purge and cannot be restored across resource
  # groups (see modules/api-center-registry). The ephemeral gate reuses one
  # registry_name across runs but gives each run its own resource group
  # (rg-...-<github.run_id>), so a short, stable suffix derived from
  # resource_group_name makes the API Center name unique per run and sidesteps
  # the tombstone collision entirely. A stable (non-ephemeral) deploy keeps a
  # stable resource group, hence a stable, deterministic name.
  registry_name_unique = "${var.registry_name}-${substr(sha1(var.resource_group_name), 0, 8)}"

  # APIM service names are GLOBAL too (leftmost label of the gateway hostname
  # <name>.azure-api.net) and are soft-deleted on delete with a 48h retention on
  # ALL tiers incl. Basic v2 (Microsoft Learn, api-management/soft-delete,
  # verified 2026-07-14). A soft-deleted name is reserved until purge/auto-purge,
  # so reusing a fixed APIM name across ephemeral runs collides with the prior
  # run's tombstone. When the prior run's terraform destroy did not purge it
  # (e.g. the destroy failed and the belt-and-braces `az group delete` backstop
  # soft-deleted APIM without purging), the next apply with recover_soft_deleted
  # left at its default would attempt an undelete and hang (see versions.tf).
  # Same reasoning and same shape as registry_name_unique above: derive a name
  # unique per deployment instance from the resource group so each ephemeral run
  # (own RG rg-...-<github.run_id>) gets a fresh global name that never collides
  # with a tombstone, and a stable (non-ephemeral) RG yields a stable name.
  apim_name_unique = "${var.apim_name}-${substr(sha1(var.resource_group_name), 0, 8)}"
}

module "apim_gateway" {
  source = "../../modules/apim-gateway"

  name                = local.apim_name_unique
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  sku_name        = local.profile_sku[var.deployment_profile]
  publisher_name  = var.publisher_name
  publisher_email = var.publisher_email
  tenant_id       = var.entra_validation.tenant_id
  prm             = local.prm
}

module "apim_mcp_server" {
  source = "../../modules/apim-mcp-server"

  apim_id     = module.apim_gateway.apim_id
  server_name = var.server_name
  server_path = var.server_path
  # This build's MCP passthrough routes to the backend entity url directly (no
  # endpoints map), so the full Functions MCP webhook path is baked into the
  # backend url here. (AI-Gateway sample shape, verified 2026-07-16.)
  backend_service_url = "${local.mcp_backend_base_url}/runtime/webhooks/mcp"

  # subscription_required and product_ids are left at their module defaults
  # (false, []): no products or subscriptions in the tracer
  # (docs/specs/v1-tracer-bullet.md, Gateway and authorization (S2)).
  entra_validation = var.entra_validation
}

module "api_center_registry" {
  source = "../../modules/api-center-registry"

  name                = local.registry_name_unique
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  apim_source_id = module.apim_gateway.apim_id
  environment    = var.registry_environment
  deployment     = var.registry_deployment

  data_reader_principal_ids = var.data_reader_principal_ids
}
