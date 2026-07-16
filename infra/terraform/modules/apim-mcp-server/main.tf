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
  # 2025-09-01-preview is the documented API version (Microsoft Learn,
  # manage-mcp-servers-rest-api); ARM acceptance is proven at the live gate,
  # not asserted here. Every 2025-09-01-preview resource below references
  # this local so the workaround flips in one place if a newer azapi release
  # adds the schema. See COMPATIBILITY.md.
  azapi_schema_validation_enabled = false

  apim_gateway_url = data.azapi_resource.apim.output.properties.gatewayUrl

  # The root protected resource metadata (PRM) document itself is owned by
  # the apim-gateway module (one root well-known path per gateway); this
  # module only needs the URL so its 401 challenge can point callers at it.
  prm_url = "${local.apim_gateway_url}/.well-known/oauth-protected-resource"
  # With no endpoints map (see mcp_server below), the MCP server is exposed at
  # the api path itself; the client connects to <gateway>/<path>, matching the
  # AI-Gateway sample (path is the MCP endpoint, no transport suffix).
  mcp_server_url = "${local.apim_gateway_url}/${var.server_path}"
}

# Backend wiring for type=mcp is a separate Backend entity referenced by
# properties.backendId, NOT properties.serviceUrl. The 2025-09-01-preview
# swagger describes only serviceUrl, but the DEPLOYED service rejects it: run
# 29509xxxxx returned 400 "Either BackendId or MCP tools must be set, but not
# both for MCP API." with serviceUrl set. backendId is therefore required (the
# swagger is ahead of the deployed service on this too). serviceUrl reads back
# null in that mode -- expected, the backend url lives on this Backend entity.
resource "azapi_resource" "mcp_backend" {
  type      = "Microsoft.ApiManagement/service/backends@2025-09-01-preview"
  name      = "${var.server_name}-backend"
  parent_id = var.apim_id

  schema_validation_enabled = local.azapi_schema_validation_enabled

  body = {
    properties = {
      title       = "${var.server_name}-backend"
      description = "Backend for passthrough MCP server ${var.server_name}. Synthetic data; see mcp-function-host for the backend tool contract."
      # The full backend MCP endpoint (base + /runtime/webhooks/mcp) is baked
      # into the backend url, matching the shipped AI-Gateway sample: on this
      # build the map endpoints did not route, so the path lives here, not in
      # mcpProperties.endpoints.
      url      = var.backend_service_url
      protocol = "http"
      type     = "Single"
      tls = {
        validateCertificateChain = true
        validateCertificateName  = true
      }
    }
  }
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
      backendId            = azapi_resource.mcp_backend.name
      subscriptionRequired = var.subscription_required
      # Match the shipped Azure sample (Azure-Samples/AI-Gateway, api-version
      # 2024-06-01-preview -- the generation this APIM stamp actually runs, ahead
      # of the 2025-09-01-preview serviceUrl+array swagger): backendId +
      # mcpProperties.transportType only, NO endpoints map, plus empty
      # authenticationSettings and isCurrent. The backend MCP path is baked into
      # the backend entity url above. On this build the map endpoints did not
      # round-trip transportType and did not route (call stage 500 with the
      # backend healthy directly). Verified against the sample 2026-07-16.
      mcpProperties = {
        transportType = var.transport.type
      }
      authenticationSettings = {
        oAuth2AuthenticationSettings = []
        openidAuthenticationSettings = []
      }
      isCurrent = true
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
