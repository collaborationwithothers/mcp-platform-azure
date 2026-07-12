# Hand-authored azapi module for Azure API Center: the S3 registry surface of
# the v1 tracer bullet. API Center has no native azurerm resource
# (hashicorp/terraform-provider-azurerm#26200, still open, confirmed
# 2026-07-12), so every resource here is azapi. All ARM shapes below are pinned
# to 2024-06-01-preview and verified 2026-07-12 against the Microsoft.ApiCenter
# ARM template reference; see README.md and COMPATIBILITY.md for the pins.
#
# The module provisions the inventory (service + single "default" workspace +
# one environment), wires APIM auto-sync (apiSources) so the MCP server appears
# automatically, grants the identity the access that sync needs, and derives
# the data-plane registry endpoint URL for the ticket-5 bounded poll. It does
# NOT create the MCP server entry explicitly: auto-sync from APIM is the
# production-correct mechanism (docs/specs/v1-tracer-bullet.md, Registry (S3)).

locals {
  # API Center currently supports a single workspace, named "default"; the
  # data-plane registry path is /workspaces/default/... (Microsoft Learn,
  # register-discover-mcp-server). Resource name is fixed; only the title is an
  # input.
  workspace_name = "default"

  # Subscription that hosts APIM, reused for the API Center service. The tracer
  # composition deploys both together in one subscription; resource_group_name
  # is a group in this subscription. ARM id format:
  # /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ApiManagement/service/{name}
  subscription_id    = split("/", var.apim_source_id)[2]
  resource_group_id  = "/subscriptions/${local.subscription_id}/resourceGroups/${var.resource_group_name}"
  role_definition_id = "/subscriptions/${local.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/71522526-b88f-4d52-b57f-d31fc3546d0d"

  # Data-plane registry hostname uses the region as a normalized slug (lowercase,
  # no spaces): "East US" and "eastus" both yield "eastus". Re-verify the derived
  # hostname at the live gate for any region whose data-plane slug is not simply
  # its lowercased name (COMPATIBILITY.md).
  location_slug = replace(lower(var.location), " ", "")

  # Exact form required by the spec and by MCP clients (Microsoft Learn,
  # register-discover-mcp-server, Configure MCP registry metadata).
  registry_endpoint_url = "https://${var.name}.data.${local.location_slug}.azure-apicenter.ms/workspaces/${local.workspace_name}/v0.1/servers"
}

# API Center service. System-assigned identity is enabled so auto-sync can read
# APIM once the identity holds the API Management Service Reader role (below).
# The only service-scoped property is `restore` (soft-delete restore), which the
# tracer never sets, so properties is an empty object.
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
    properties = {}
  }
}

# Single "default" workspace. Must be declared explicitly: API Center does not
# auto-create it, and the data-plane registry path depends on it existing
# (Microsoft Learn, set-up-api-center-arm-template: "Currently, API Center
# supports a single, default workspace for all child resources").
resource "azapi_resource" "workspace" {
  type      = "Microsoft.ApiCenter/services/workspaces@2024-06-01-preview"
  name      = local.workspace_name
  parent_id = azapi_resource.api_center.id

  body = {
    properties = {
      title       = var.workspace_title
      description = "Default workspace. Backs the /workspaces/default data-plane registry path."
    }
  }
}

# Environment the remote MCP server is associated with. The
# register-discover-mcp-server prerequisites require a remote MCP server to be
# associated with an environment (the location of the server, e.g. an API
# management platform); server.type is "Azure API Management" for the tracer.
resource "azapi_resource" "environment" {
  type      = "Microsoft.ApiCenter/services/workspaces/environments@2024-06-01-preview"
  name      = "apim"
  parent_id = azapi_resource.workspace.id

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
  parent_id = azapi_resource.workspace.id

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
  name      = uuidv5("url", "${var.apim_source_id}|${local.role_definition_id}|${azapi_resource.api_center.identity[0].principal_id}")
  parent_id = var.apim_source_id

  body = {
    properties = {
      roleDefinitionId = local.role_definition_id
      principalId      = azapi_resource.api_center.identity[0].principal_id
      principalType    = "ServicePrincipal"
    }
  }
}
