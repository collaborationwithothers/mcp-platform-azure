# Hand-authored azapi module for Azure API Center: the S3 registry surface of
# the v1 tracer bullet. API Center has no native azurerm resource
# (hashicorp/terraform-provider-azurerm#26200, still open, confirmed
# 2026-07-12), so every resource here is azapi. All ARM shapes below are pinned
# to 2024-06-01-preview and verified 2026-07-12 against the Microsoft.ApiCenter
# ARM template reference; see README.md and COMPATIBILITY.md for the pins.
#
# The module provisions the inventory (service + single "default" workspace +
# one environment), wires APIM auto-sync (apiSources) so the MCP server appears
# automatically, grants the API Center identity the access that sync needs,
# grants Data Reader on the instance to the poll principal(s) that read the
# registry authenticated, and derives the data-plane registry endpoint URL for
# the ticket-5 bounded poll. It does NOT create the MCP server entry explicitly:
# auto-sync from APIM is the production-correct mechanism
# (docs/specs/v1-tracer-bullet.md, Registry (S3)).

locals {
  # API Center currently supports a single workspace, named "default"; the
  # data-plane registry path is /workspaces/default/... (Microsoft Learn,
  # register-discover-mcp-server). Auto-provisioned by Azure with the service
  # (see data.azapi_resource.workspace above); this module never sets its
  # title, only reads it by this fixed name.
  workspace_name = "default"

  # Subscription that hosts APIM, reused for the API Center service. The tracer
  # composition deploys both together in one subscription; resource_group_name
  # is a group in this subscription. ARM id format:
  # /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ApiManagement/service/{name}
  subscription_id   = split("/", var.apim_source_id)[2]
  resource_group_id = "/subscriptions/${local.subscription_id}/resourceGroups/${var.resource_group_name}"

  # Built-in role definition ids (subscription-scoped references). Both role
  # assignments in this module are authored via azapi to keep it single-provider.
  # - API Management Service Reader Role (71522526-...): the API Center identity
  #   needs it on the APIM instance so auto-sync can import APIs.
  # - Azure API Center Data Reader (c7244dfb-...): granted on THIS API Center
  #   instance to the principals in data_reader_principal_ids so they can read
  #   the data-plane registry with an authenticated call.
  # Both GUIDs verified 2026-07-12 against the Microsoft Learn built-in roles
  # reference (role-based-access-control/built-in-roles/integration).
  apim_reader_role_definition_id = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/71522526-b88f-4d52-b57f-d31fc3546d0d"
  data_reader_role_definition_id = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/c7244dfb-f447-457d-b2ba-3999044d1706"

  # Data-plane registry hostname uses the region as a normalized slug (lowercase,
  # no spaces): "East US" and "eastus" both yield "eastus". Re-verify the derived
  # hostname at the live gate for any region whose data-plane slug is not simply
  # its lowercased name (COMPATIBILITY.md).
  location_slug = replace(lower(var.location), " ", "")

  # Form required by the spec and by MCP clients (Microsoft Learn,
  # register-discover-mcp-server, Configure MCP registry metadata). Known doc
  # inconsistency (2026-07-12): that page's stated format string includes the
  # /workspaces/ segment (used here), but its own worked example omits it
  # (.../default/v0.1/servers). Ticket 5's bounded poll must confirm the live
  # form empirically before relying on it; see README.md and COMPATIBILITY.md.
  registry_endpoint_url = "https://${var.name}.data.${local.location_slug}.azure-apicenter.ms/workspaces/${local.workspace_name}/v0.1/servers"
}

# API Center service. System-assigned identity is enabled so auto-sync can read
# APIM once the identity holds the API Management Service Reader role (below).
#
# EXPERIMENTAL / UNVERIFIED (2026-07-14): restore = true is set unconditionally.
# API Center has genuine soft-delete (verified against the Microsoft.ApiCenter
# deletedServices REST reference: tombstones carry softDeletionDate and
# scheduledPurgeDate). Live gate: since this module's name (var.name) is a
# fixed value reused across every ephemeral run, a second run's create hit 400
# "The name ... is already taken" against the first run's tombstone, even
# though that first run's terraform destroy succeeded (destroy deletes the
# live service; it does not un-reserve the soft-deleted name). properties.restore
# is documented ("Flag used to restore soft-deleted API Center service. If
# specified and set to 'true' all other properties will be ignored", ARM
# template reference, 2024-03-15-preview onward) but no source found confirms
# its behavior on a genuinely first-ever create with no prior soft-deleted
# instance to restore (no purge REST operation for API Center could be
# confirmed to exist either, so purge-before-create is not an available
# alternative). Costs nothing to set here since properties was already empty.
# Re-verify at the next live-test run (both the fresh-create case and the
# restore-after-destroy case) and correct this comment/COMPATIBILITY.md either
# way.
resource "azapi_resource" "api_center" {
  type      = "Microsoft.ApiCenter/services@2024-06-01-preview"
  name      = var.name
  parent_id = local.resource_group_id
  location  = var.location
  tags      = var.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      restore = true
    }
  }
}

# Single "default" workspace, which the data-plane registry path depends on
# (Microsoft Learn, set-up-api-center-arm-template: "Currently, API Center
# supports a single, default workspace for all child resources"). Confirmed at
# the live gate (2026-07-13): Azure auto-provisions this workspace as a side
# effect of creating the service, so a GET on it succeeds immediately after
# azapi_resource.api_center is created. A `resource "azapi_resource"` here
# therefore always fails its own pre-create existence check with "Resource
# already exists". This module never manages the workspace's title/description
# as a result; whether the auto-created instance's properties can be updated
# via a later PUT/PATCH is unverified, so this only reads it.
data "azapi_resource" "workspace" {
  type      = "Microsoft.ApiCenter/services/workspaces@2024-06-01-preview"
  name      = local.workspace_name
  parent_id = azapi_resource.api_center.id
}

# Environment the remote MCP server is associated with. The
# register-discover-mcp-server prerequisites require a remote MCP server to be
# associated with an environment (the location of the server, e.g. an API
# management platform); server.type is "Azure API Management" for the tracer.
resource "azapi_resource" "environment" {
  type      = "Microsoft.ApiCenter/services/workspaces/environments@2024-06-01-preview"
  name      = "apim"
  parent_id = data.azapi_resource.workspace.id

  body = {
    properties = {
      title = var.environment.title
      kind  = var.environment.kind
      server = {
        type                = var.environment.server_type
        managementPortalUri = var.environment.management_portal_uri
      }
    }
  }
}

# API Management auto-sync. This is the production-correct mechanism that keeps
# the inventory current: MCP servers managed in APIM populate the registry
# automatically, rather than being registered explicitly (Microsoft Learn,
# synchronize-api-management-apis). depends_on the role assignment so the
# identity can already read APIM when the source is created.
resource "azapi_resource" "apim_source" {
  type      = "Microsoft.ApiCenter/services/workspaces/apiSources@2024-06-01-preview"
  name      = "apim-sync"
  parent_id = data.azapi_resource.workspace.id

  body = {
    properties = {
      azureApiManagementSource = {
        resourceId = var.apim_source_id
        # msiResourceId is only for a user-assigned identity; the tracer uses
        # the service's system-assigned identity, so it is omitted.
      }
      importSpecification  = var.deployment.import_specification
      targetEnvironmentId  = azapi_resource.environment.id
      targetLifecycleStage = var.deployment.target_lifecycle_stage
    }
  }

  depends_on = [azapi_resource.apim_reader]
}

# API Management Service Reader role for the API Center identity on the APIM
# instance. This is the access auto-sync requires to import APIs (Microsoft
# Learn, synchronize-api-management-apis: "assign your API center's managed
# identity the API Management Service Reader role in your API Management
# instance"). Authored via azapi to keep the module single-provider. The role
# definition GUID 71522526-b88f-4d52-b57f-d31fc3546d0d is the built-in "API
# Management Service Reader Role" (Microsoft Learn, Azure built-in roles).
resource "azapi_resource" "apim_reader" {
  count = var.assign_apim_reader_role ? 1 : 0

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "${var.apim_source_id}|${local.apim_reader_role_definition_id}|${azapi_resource.api_center.identity[0].principal_id}")
  parent_id = var.apim_source_id

  body = {
    properties = {
      roleDefinitionId = local.apim_reader_role_definition_id
      principalId      = azapi_resource.api_center.identity[0].principal_id
      principalType    = "ServicePrincipal"
    }
  }
}

# Azure API Center Data Reader on THIS API Center instance, for each principal in
# data_reader_principal_ids. The data-plane registry endpoint's read-access mode
# (authenticated vs anonymous) is not an ARM/azapi property in ANY published
# Microsoft.ApiCenter API version as of 2026-07-12 (see README.md and
# COMPATIBILITY.md); the default posture is authenticated. So consumers inside
# the Entra trust boundary -- here, the ticket-5 bounded poll's OIDC principal --
# read the registry with this role rather than via an anonymous toggle. Anonymous
# read, if ever wanted, is a portal-only opt-in
# (docs/runbooks/registry-anonymous-access.md), not used by this deployment.
# The uuidv5 name seed includes the instance (parent) id so the deterministic
# name is unique per (scope, role, principal). Empty list (default) => no grants.
resource "azapi_resource" "data_reader" {
  for_each = toset(var.data_reader_principal_ids)

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "${azapi_resource.api_center.id}|${local.data_reader_role_definition_id}|${each.value}")
  parent_id = azapi_resource.api_center.id

  body = {
    properties = {
      roleDefinitionId = local.data_reader_role_definition_id
      principalId      = each.value
      principalType    = "ServicePrincipal"
    }
  }
}
