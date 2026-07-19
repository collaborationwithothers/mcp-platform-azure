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
  # Read by McpTools.Program.cs to construct the OBO confidential client
  # (ManagedIdentityOboTokenAcquirer) and DownstreamOrdersClient. The
  # downstream app's client id is NOT passed as an app setting: OBO's
  # AcquireTokenOnBehalfOf only needs the scope (DownstreamOrdersApi__Scope
  # already carries the downstream app id as its api://<id>/... prefix), so
  # a separate ClientId setting would be unused configuration.
  app_settings = merge(var.app_settings, {
    MicrosoftEntra__ServerAppClientId = var.entra_auth.server_app_client_id
    MicrosoftEntra__TenantId          = var.entra_auth.tenant_id
    DownstreamOrdersApi__BaseUrl      = module.downstream_orders_api.base_url
    DownstreamOrdersApi__Scope        = var.downstream_app.api_scope
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

# --- Issue 10 (OBO thickening): OBO identity wiring (azuread) ---
#
# The out-of-band server and downstream app registrations already exist
# (docs/runbooks/entra-app-registrations.md, docs/runbooks/
# obo-app-registrations.md); referenced by client_id, never created here
# (Identity provisioning, docs/specs/v1-tracer-bullet.md -- directory-write
# for CREATING app registrations stays out of the ephemeral CI principal's
# hands). What IS Terraform-managed here are two child objects that must be
# re-created every ephemeral run, not set up once by a human:
#
# 1. The federated identity credential (FIC) on the server app, trusting
#    the MCP server's system-assigned managed identity as a client
#    assertion source (no stored secret, ManagedIdentityOboTokenAcquirer).
#    This CANNOT be a one-time manual runbook step: the Function App's
#    system-assigned identity's principal id is different every apply (a
#    fresh identity in a fresh, ephemeral resource group), so the FIC's
#    subject must be re-created to match each run's actual identity.
# 2. The delegated-permission (OBO) consent grant from the server app to
#    the downstream app's user_impersonation scope. This one COULD be a
#    one-time human step (both apps are stable, out-of-band identities),
#    but is kept alongside the FIC as Terraform-managed for the same reason
#    the rest of this composition is declarative: idempotent, torn down
#    and recreated cleanly by the same apply/destroy cycle, no drift
#    between what the runbook says and what actually exists.
#
# Both resources are destroyed with the rest of this composition's state at
# the end of each live-test run (docs/runbooks/live-test-gate.md); if a
# destroy ever fails partway (the established risk pattern for this repo's
# ephemeral model -- see COMPATIBILITY.md's API Center/APIM soft-delete
# tombstone rows), a stale FIC can be left on the server app. Entra allows
# up to 20 federated credentials per application, so this is a slow-building
# risk, not an immediate one; display_name is suffixed per run (below) so a
# stale FIC from a failed teardown does not collide with the next run's
# apply, it just accumulates until manually cleaned up or the limit is hit.
#
# Deploying-principal Graph permissions this needs, beyond the ARM
# roleAssignments/write already documented in docs/runbooks/live-test-gate.md:
# Application.ReadWrite.All (FIC) and Directory.ReadWrite.All (permission
# grant), both admin-consented -- docs/runbooks/obo-app-registrations.md.

data "azuread_application" "server" {
  client_id = var.entra_auth.server_app_client_id
}

data "azuread_service_principal" "server" {
  client_id = var.entra_auth.server_app_client_id
}

data "azuread_service_principal" "downstream" {
  client_id = var.downstream_app.client_id
}

resource "azuread_application_federated_identity_credential" "obo_managed_identity" {
  #checkov:skip=CKV_AZURE_249:False positive -- this check (checkov source, GithubActionsOIDCTrustPolicy.py) inspects ONLY subject for GitHub Actions' colon-delimited claimtype:value format and never reads issuer, so it fires on every azuread_application_federated_identity_credential regardless of federation type. issuer here is Entra managed-identity federation (login.microsoftonline.com/<tenant>/v2.0), NOT GitHub Actions (token.actions.githubusercontent.com); subject is correctly a bare GUID (the Function App's managed identity principal id, per Microsoft's documented shape for this trust type), which has no colon and can never satisfy this check's GitHub-Actions-shaped logic.
  application_id = data.azuread_application.server.id
  # Unique per run (see the block comment above): a fixed name risks
  # colliding with a leftover credential from a prior run whose destroy
  # step failed partway. resource_group_name is already this composition's
  # per-run-unique value (rg-mcp-tracer-<run_id>), matching the pattern
  # api-center-registry and s2's apim_name already use for the same reason.
  display_name = "mcp-server-obo-${substr(sha1(var.resource_group_name), 0, 8)}"
  description  = "OBO client assertion credential for the MCP server's Function App managed identity (issue 10). Re-created per live-test run."
  audiences    = ["api://AzureADTokenExchange"]
  issuer       = "https://login.microsoftonline.com/${var.entra_auth.tenant_id}/v2.0"
  subject      = module.mcp_function_host.identity_principal_id
}

resource "azuread_service_principal_delegated_permission_grant" "obo_downstream_consent" {
  service_principal_object_id          = data.azuread_service_principal.server.object_id
  resource_service_principal_object_id = data.azuread_service_principal.downstream.object_id
  # Admin consent for all users (user_object_id omitted): the server acts
  # on behalf of whichever user's token it receives, not one specific user.
  claim_values = ["user_impersonation"]
}
