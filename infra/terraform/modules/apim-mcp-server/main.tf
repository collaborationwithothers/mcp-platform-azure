# Hand-authored azapi: Microsoft.ApiManagement/service/apis at
# 2025-09-01-preview, type = mcp, has no azurerm equivalent. Verified
# 2026-07-12 against https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api
# (the Terraform example there is mirrored below). See README.md and
# COMPATIBILITY.md for the pin.

# Read-only lookup of the parent service's gateway hostname. apim_id (an ARM
# resource ID) is the only parent-identifying input on this module's thick
# interface; this avoids adding a redundant gateway_url input that would
# duplicate apim-gateway's own output.
data "azapi_resource" "apim" {
  type                   = "Microsoft.ApiManagement/service@2024-05-01"
  resource_id            = var.apim_id
  response_export_values = ["properties.gatewayUrl"]
}

locals {
  # azapi 2.10.0 (the latest release; this repo's pin) does not yet
  # recognize 2025-09-01-preview in its embedded resource schema for the
  # Microsoft.ApiManagement/service/apis family (confirmed locally:
  # terraform validate rejects the api-version with schema validation on,
  # listing 2025-03-01-preview as its newest known version for these types).
  # ARM itself accepts 2025-09-01-preview (Microsoft Learn,
  # manage-mcp-servers-rest-api). Every 2025-09-01-preview resource below
  # references this local so the workaround flips in one place if a newer
  # azapi release adds the schema. See COMPATIBILITY.md.
  azapi_schema_validation_enabled = false

  apim_gateway_url = data.azapi_resource.apim.output.properties.gatewayUrl

  mcp_message_endpoint = one([
    for e in var.transport.endpoints : e.uri_template if e.name == "message"
  ])

  prm_url        = "${local.apim_gateway_url}/.well-known/oauth-protected-resource"
  mcp_server_url = "${local.apim_gateway_url}/${var.server_path}${local.mcp_message_endpoint}"

  # RFC 9728 protected resource metadata document. Rendered here (not
  # inline in the policy template) so the policy template only ever embeds
  # one already-valid JSON value, never hand-built JSON/XML escaping.
  prm_document_json = jsonencode({
    resource                 = var.prm.resource
    authorization_servers    = [var.prm.issuer]
    bearer_methods_supported = ["header"]
    scopes_supported         = var.prm.scopes
  })
}

# Passthrough MCP server. For a passthrough server the external backend
# (mcp-function-host) owns the tool surface, so this module creates no
# apis/tools child resources (docs/specs/v1-tracer-bullet.md, Gateway and
# authorization (S2)).
resource "azapi_resource" "mcp_server" {
  type      = "Microsoft.ApiManagement/service/apis@2025-09-01-preview"
  name      = var.server_name
  parent_id = var.apim_id

  schema_validation_enabled = local.azapi_schema_validation_enabled

  body = {
    properties = {
      type                 = "mcp"
      displayName          = var.server_name
      description          = "Passthrough MCP server. Synthetic data; see mcp-function-host for the backend tool contract."
      path                 = var.server_path
      protocols            = ["https"]
      serviceUrl           = var.backend_service_url
      subscriptionRequired = var.subscription_required
      mcpProperties = {
        transportType = var.transport.type
        endpoints = [
          for e in var.transport.endpoints : {
            name        = e.name
            uriTemplate = e.uri_template
          }
        ]
      }
    }
  }
}

# Server-scope policy: owns the 401 + WWW-Authenticate challenge for
# unauthenticated calls, validates the Entra token (issuer via tenant-id,
# audience, allowed client application ids) for authenticated calls, and
# forwards to the backend. Does not read context.Response.Body (breaks MCP
# streaming; Microsoft Learn, expose-existing-mcp-server, verified
# 2026-07-12). See policies/mcp-server.xml and README.md.
resource "azapi_resource" "mcp_server_policy" {
  type      = "Microsoft.ApiManagement/service/apis/policies@2025-09-01-preview"
  name      = "policy"
  parent_id = azapi_resource.mcp_server.id

  schema_validation_enabled = local.azapi_schema_validation_enabled

  body = {
    properties = {
      format = "rawxml"
      value = templatefile("${path.module}/policies/mcp-server.xml", {
        tenant_id                      = var.entra_validation.tenant_id
        audience                       = var.entra_validation.audience
        allowed_client_application_ids = var.entra_validation.allowed_client_application_ids
        prm_url                        = local.prm_url
      })
    }
  }
}

# Product bindings. Empty in the tracer (var.product_ids default []);
# binding a product later only adds entries here, it does not touch
# azapi_resource.mcp_server. docs/specs/v1-tracer-bullet.md, Gateway and
# authorization (S2).
resource "azapi_resource" "product_binding" {
  for_each = toset(var.product_ids)

  type      = "Microsoft.ApiManagement/service/products/apis@2025-09-01-preview"
  name      = var.server_name
  parent_id = "${var.apim_id}/products/${each.value}"

  schema_validation_enabled = local.azapi_schema_validation_enabled

  body = {}

  depends_on = [azapi_resource.mcp_server]
}

# Gateway-root protected resource metadata (PRM), RFC 9728. Microsoft Learn
# documents no native APIM feature for serving a document at the gateway
# root well-known path (verified 2026-07-12; see README.md "Root PRM is
# hand-rolled"); this hand-rolls it as a second API mounted at path = ""
# (the gateway root), following the community reference architecture named
# in the ticket (https://github.com/blackchoey/remote-mcp-apim-oauth-prm).
# A root path is unique per API Management service, so this resource is
# naturally a gateway-level singleton; see README.md, "Future: a second MCP
# server", for what a second server on the same gateway must do.
resource "azapi_resource" "prm_well_known" {
  type      = "Microsoft.ApiManagement/service/apis@2025-09-01-preview"
  name      = "oauth-protected-resource-metadata"
  parent_id = var.apim_id

  schema_validation_enabled = local.azapi_schema_validation_enabled

  body = {
    properties = {
      displayName          = "OAuth Protected Resource Metadata"
      description          = "Serves the RFC 9728 protected resource metadata document at the gateway root well-known path. Every operation is policy-terminated (return-response) before any backend dispatch, so serviceUrl below is never called."
      path                 = ""
      protocols            = ["https"]
      subscriptionRequired = false
      serviceUrl           = "https://unused.invalid"
    }
  }
}

resource "azapi_resource" "prm_well_known_operation" {
  type      = "Microsoft.ApiManagement/service/apis/operations@2025-09-01-preview"
  name      = "get-oauth-protected-resource-metadata"
  parent_id = azapi_resource.prm_well_known.id

  schema_validation_enabled = local.azapi_schema_validation_enabled

  body = {
    properties = {
      displayName = "Get OAuth protected resource metadata"
      method      = "GET"
      urlTemplate = "/.well-known/oauth-protected-resource"
    }
  }
}

resource "azapi_resource" "prm_well_known_policy" {
  type      = "Microsoft.ApiManagement/service/apis/policies@2025-09-01-preview"
  name      = "policy"
  parent_id = azapi_resource.prm_well_known.id

  schema_validation_enabled = local.azapi_schema_validation_enabled

  body = {
    properties = {
      format = "rawxml"
      value = templatefile("${path.module}/policies/prm-well-known.xml", {
        prm_document_json = local.prm_document_json
      })
    }
  }

  depends_on = [azapi_resource.prm_well_known_operation]
}
