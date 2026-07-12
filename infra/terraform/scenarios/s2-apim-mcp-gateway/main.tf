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
}

module "apim_gateway" {
  source = "../../modules/apim-gateway"

  name                = var.apim_name
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

  apim_id             = module.apim_gateway.apim_id
  server_name         = var.server_name
  server_path         = var.server_path
  backend_service_url = local.mcp_backend_base_url

  # subscription_required and product_ids are left at their module defaults
  # (false, []): no products or subscriptions in the tracer
  # (docs/specs/v1-tracer-bullet.md, Gateway and authorization (S2)).
  entra_validation = var.entra_validation
}

module "api_center_registry" {
  source = "../../modules/api-center-registry"

  name                = var.registry_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  apim_source_id = module.apim_gateway.apim_id
  environment    = var.registry_environment
  deployment     = var.registry_deployment

  data_reader_principal_ids = var.data_reader_principal_ids
}
