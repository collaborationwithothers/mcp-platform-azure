# Wrapper over Azure/avm-res-web-site/azurerm 0.22.0. The AVM module is the
# swappable implementation; this wrapper is the stable thick interface later
# modules (apim-gateway, apim-mcp-server) and scenario compositions depend on.
# See README.md for the issue-1 AVM capability-check outcome this main.tf
# depends on, and COMPATIBILITY.md for the pin.

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# The Flex Consumption plan (service_plan_resource_id) is required by
# avm-res-web-site but not created by it. There is no AVM module wrap for a
# single-resource App Service Plan; azurerm_service_plan is the AzureRM-tier
# fallback per docs/specs/v1-tracer-bullet.md, Terraform and state (general
# fallback policy).
resource "azurerm_service_plan" "this" {
  name                = "${var.name_prefix}-plan"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = var.tags
}

# Flex Consumption deployment storage. Created here only when the caller asks
# for it; otherwise this module expects the account to already exist, the
# same out-of-band pattern the tracer uses for Entra app registrations.
# Customer-managed-key encryption needs a Key Vault, out of v1 module scope
# (docs/specs/v1-tracer-bullet.md, Out of Scope: the private-network and
# observability modules are v1.1/v1.2). checkov's CKV2_AZURE_1/18 graph
# checks for this are skipped repo-wide in .checkov.yaml, not inline (an
# inline skip annotation on this resource does not suppress CKV2_* graph
# checks).
resource "azurerm_storage_account" "this" {
  count = var.create_storage_account ? 1 : 0

  name                             = var.storage_account_name
  resource_group_name              = data.azurerm_resource_group.this.name
  location                         = var.location
  account_tier                     = "Standard"
  account_replication_type         = "LRS"
  min_tls_version                  = "TLS1_2"
  https_traffic_only_enabled       = true
  cross_tenant_replication_enabled = false
  # Only managed identity is used for storage auth in this module
  # (storage_uses_managed_identity below); shared keys are never issued.
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  sas_policy {
    expiration_period = "01.00:00:00"
  }

  tags = var.tags
}

data "azurerm_storage_account" "existing" {
  count = var.create_storage_account ? 0 : 1

  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
}

locals {
  storage_account_id = var.create_storage_account ? azurerm_storage_account.this[0].id : data.azurerm_storage_account.existing[0].id
}

# prevent_destroy would block the gated live-test environment's destroy
# step; the tracer's whole point is apply-call-destroy leaving nothing
# running (docs/specs/v1-tracer-bullet.md, Ephemeral). This container holds
# only the deployment package, not user data. Blob read-request logging
# (checkov CKV2_AZURE_21) is observability wiring, out of v1 module scope;
# skipped repo-wide in .checkov.yaml (inline skip comments do not suppress
# CKV2_* graph checks).
# tflint-ignore: azurerm_resources_missing_prevent_destroy
resource "azurerm_storage_container" "deployment_package" {
  name                  = "deploymentpackage"
  storage_account_id    = local.storage_account_id
  container_access_type = "private"
}

locals {
  open_id_issuer = "https://login.microsoftonline.com/${var.entra_auth.tenant_id}/v2.0"

  # The Functions MCP extension's key-based access path (the mcp_extension
  # system key) is not a supported access path once built-in auth is
  # enabled: Easy Auth intercepts every request to the Functions runtime,
  # including the extension's webhook route, ahead of the runtime's own key
  # check (see README.md, "mcp_extension key posture" for the doc citations
  # behind this). Setting the key's authorization level to Anonymous removes
  # the redundant, potentially confusing second gate rather than leaving a
  # dormant key check behind Easy Auth. The behavioural proof that no shadow
  # path exists is ticket 5's negative test (system key present, no Entra
  # token -> 401), not this app setting.
  mcp_extension_key_app_settings = {
    AzureFunctionsJobHost__extensions__mcp__system__webhookAuthorizationLevel = "Anonymous"
  }

  # Preview capability (see COMPATIBILITY.md): serves the OAuth protected
  # resource metadata document backend-side so a caller reaching the
  # Functions host directly still gets a spec-shaped 401 challenge.
  prm_app_settings = {
    WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES = var.prm_scope
  }

  merged_app_settings = merge(
    var.app_settings,
    local.mcp_extension_key_app_settings,
    local.prm_app_settings,
  )
}

module "function_app" {
  source  = "Azure/avm-res-web-site/azurerm"
  version = "0.22.0"

  name             = "${var.name_prefix}-func"
  location         = var.location
  parent_id        = data.azurerm_resource_group.this.id
  kind             = "functionapp"
  os_type          = "Linux"
  enable_telemetry = false

  service_plan_resource_id = azurerm_service_plan.this.id

  function_app_uses_fc1  = true
  fc1_runtime_name       = "dotnet-isolated"
  fc1_runtime_version    = var.runtime.version
  instance_memory_in_mb  = var.flex_consumption.instance_memory_mb
  maximum_instance_count = var.flex_consumption.maximum_instance_count

  storage_account_name          = var.storage_account_name
  storage_uses_managed_identity = true
  storage_authentication_type   = "SystemAssignedIdentity"
  storage_container_endpoint    = azurerm_storage_container.deployment_package.id
  storage_container_type        = "blobContainer"

  managed_identities = {
    system_assigned = true
  }

  public_network_access_enabled = true

  app_settings = local.merged_app_settings

  # Entra built-in auth (Easy Auth). require_authentication plus
  # unauthenticated_client_action = Return401 with excluded_paths left empty
  # means every request, including to the MCP endpoint, must carry a valid
  # Entra token or is rejected with 401 -- there is no auth-excluded MCP
  # path. See the acceptance criteria in issue 5 and README.md.
  auth_settings_v2 = {
    auth_enabled                  = true
    require_authentication        = true
    unauthenticated_client_action = var.entra_auth.unauthenticated_action
    excluded_paths                = []

    identity_providers = {
      azure_active_directory = {
        enabled = true

        registration = {
          client_id      = var.entra_auth.server_app_client_id
          open_id_issuer = local.open_id_issuer
        }

        validation = {
          allowed_audiences = var.entra_auth.allowed_audiences
        }
      }
    }
  }

  tags = var.tags
}

# storage_uses_managed_identity above requires the Function App's
# system-assigned identity to hold data-plane access on the deployment
# storage account; avm-res-web-site does not create this role assignment
# itself (confirmed against its examples, see README.md).
resource "azurerm_role_assignment" "function_app_storage_blob_data_owner" {
  scope                = local.storage_account_id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = module.function_app.identity_principal_id
}
