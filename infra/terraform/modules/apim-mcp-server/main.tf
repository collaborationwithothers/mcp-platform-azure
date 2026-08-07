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

  # The PRM documents themselves are owned by the apim-gateway module (the
  # well-known locations are a property of the gateway host); this module only
  # needs the URL so its 401 challenge can point callers at the right document.
  # prm_url is the gateway-root well-known location (exposed as this module's
  # prm_url output for interface stability).
  prm_url = "${local.apim_gateway_url}/.well-known/oauth-protected-resource"
  # The client MCP endpoint is <gateway>/<path><uriTemplate>: the passthrough
  # appends the endpoint's uriTemplate to both the client route and the backend
  # url. A portal-created reference server on this same stamp exposed exactly
  # <gateway>/<path>/runtime/webhooks/mcp (verified 2026-07-16). streamable has
  # a single endpoint, so its uriTemplate is the suffix.
  mcp_endpoint_uri_template = var.transport.endpoints[0].uri_template
  mcp_server_url            = "${local.apim_gateway_url}/${var.server_path}${local.mcp_endpoint_uri_template}"
  # This server's OWN RFC 9728 s3.1 path-inserted PRM location (issue 17): the
  # gateway-root well-known URL with this server's resource path inserted after
  # it. Matches the apim-gateway module's per-server path-inserted operation
  # urlTemplate (/.well-known/oauth-protected-resource<resource-path>).
  #
  # The two 401 sites emit DIFFERENT values because the deployed type=mcp runtime
  # rewrites the no-token challenge but not the on-error one (established at the
  # live gate, issue 17; COMPATIBILITY.md):
  #   - No-token 401 emits prm_url (the gateway ROOT well-known). The runtime
  #     rewrites it by inserting this server's path after the host, so the
  #     CLIENT-VISIBLE challenge becomes <gateway>/<server_path>/.well-known/...
  #     -- per-server automatically. Emitting the path-inserted form there would
  #     be double-prefixed by the rewrite into a broken URL.
  #   - On-error 401 emits prm_server_url (this path-inserted value). The runtime
  #     does NOT rewrite this path, so the literal per-server value reaches the
  #     client, ensuring a second server's on-error points at its OWN metadata
  #     and never the shared root (server 1's document). This is the #17 fix for
  #     the on-error path.
  prm_server_url = "${local.prm_url}/${var.server_path}${local.mcp_endpoint_uri_template}"
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
      # Backend url is the BASE host; the endpoint path lives in
      # mcpProperties.endpoints[].uriTemplate and is appended at forward time
      # (the gateway trace showed set-backend-service forwarding to
      # base + uriTemplate). This matches the portal-created reference server on
      # this stamp (its backend url was the bare base). Verified 2026-07-16.
      url      = var.backend_service_url
      protocol = "http"
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
      # mcpProperties.endpoints is a MAP keyed by endpoint name, value
      # { uriTemplate }. This is the shape a portal-created reference MCP server
      # on this same stamp produced (endpoints = { "mcp" = { uriTemplate =
      # "/runtime/webhooks/mcp" } }), verified by GET on 2026-07-16 -- NOT the
      # serviceUrl+array swagger shape (rejected 400) and NOT transportType
      # (this build drops it; the reference server has none). The endpoint name
      # is the map key. Earlier map attempts appeared to fail, but that was the
      # TLS 1.3/1.2 backend handshake (fixed in mcp-function-host), not this
      # shape.
      mcpProperties = {
        endpoints = {
          for e in var.transport.endpoints : e.name => {
            uriTemplate = e.uri_template
          }
        }
      }
      isCurrent = true
    }
  }
}

# Server-scope policy: owns the 401 + WWW-Authenticate challenge for
# unauthenticated calls (pointing at THIS server's path-inserted PRM), validates
# the Entra token (issuer via tenant-id, audience, allowed client application
# ids), enforces this server's per-server entitlement (scp OR roles, issue 17),
# and forwards to the backend. Does not read context.Response.Body (breaks MCP
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
        prm_root_url                   = local.prm_url
        prm_server_url                 = local.prm_server_url
        required_scope                 = var.required_scope
        required_role                  = var.required_role
        # Issue 18: rendered into the fragment's per-tool <choose> once that
        # block lands. Passed through unconsumed until then -- templatefile()
        # does not require every supplied variable to be referenced by the
        # template, so this keeps validate green ahead of the fragment change.
        tool_authorization_map = var.tool_authorization_map
        eventhub_logger_name   = var.eventhub_logger_name
      })
    }
  }
}

# Per-API diagnostic setting binding this MCP server API to the shared
# Application Insights audit logger. verbosity = "error" ensures only traces
# emitted at severity = "error" (the policy fragment's audit <trace> level for
# per-tool denials) are forwarded to Application Insights; lower-severity traces
# are suppressed. The fragment's audit event reaches the logger only if its
# severity >= this verbosity (error >= error: emitted). Microsoft Learn (trace
# policy), verified 2026-08-06:
# https://learn.microsoft.com/azure/api-management/trace-policy
resource "azapi_resource" "mcp_server_diagnostic" {
  type      = "Microsoft.ApiManagement/service/apis/diagnostics@2022-08-01"
  name      = "applicationinsights"
  parent_id = azapi_resource.mcp_server.id

  body = {
    properties = {
      loggerId  = var.audit_logger_id
      verbosity = "error"
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
