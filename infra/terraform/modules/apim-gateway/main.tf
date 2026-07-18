# Wrapper over Azure/avm-res-apimanagement-service/azurerm 0.9.0. The AVM
# module is the swappable implementation; this wrapper is the stable thick
# interface apim-mcp-server and scenario compositions depend on. See
# README.md for the issue-3 AVM capability-check outcome this main.tf
# depends on, and COMPATIBILITY.md for the pin.

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

module "apim" {
  source  = "Azure/avm-res-apimanagement-service/azurerm"
  version = "0.9.0"

  name                = var.name
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = var.sku_name
  enable_telemetry    = false

  managed_identities = {
    system_assigned = true
  }

  tags = var.tags
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

  prm_url = "${module.apim.apim_gateway_url}/.well-known/oauth-protected-resource"

  # RFC 9728 protected resource metadata document. Rendered here (not
  # inline in the policy template) so the policy template only ever embeds
  # one already-valid JSON value, never hand-built JSON/XML escaping.
  prm_document_json = jsonencode({
    resource                 = var.prm.resource
    authorization_servers    = [var.prm.authorization_server]
    bearer_methods_supported = ["header"]
    scopes_supported         = var.prm.scopes
  })

  # Path component of the PRM resource (the MCP server URL), e.g.
  # /orders/runtime/webhooks/mcp. RFC 9728 s3.1 serves the metadata for a
  # path-bearing resource at the well-known path with the resource path INSERTED
  # after it, and a spec-conformant client (VS Code) fetches THAT url and rejects
  # the bare-root document as inconsistent with a path-bearing resource (proven
  # by VS Code's MCP discovery trace, 2026-07-18; see prm_well_known_operation_pathed
  # and COMPATIBILITY.md). Empty when the resource has no path (then only the root
  # operation is created).
  prm_resource_path = try(regex("^https?://[^/]+(.*)$", var.prm.resource)[0], "")
}

# Gateway-root protected resource metadata (PRM), RFC 9728. This singleton
# lives in apim-gateway, not apim-mcp-server, because the root well-known
# location is a property of the gateway: there is exactly one root path per
# API Management service, so exactly one root PRM document. Only the
# document's contents describe a server, and those arrive as var.prm from
# the composition. A second MCP server added to the same gateway reuses this
# one document; it does not create its own (the instantiate-twice test:
# apim-mcp-server can be instantiated more than once against one gateway,
# this cannot, so the singleton belongs in the layer whose cardinality it
# shares). See README.md.
#
# Microsoft Learn documents no native APIM feature for serving a document at
# the gateway root well-known path (verified 2026-07-12; see README.md "Root
# PRM is hand-rolled"); this hand-rolls it as an API mounted at path = ""
# (the gateway root), following the community reference architecture named
# in the ticket (https://github.com/blackchoey/remote-mcp-apim-oauth-prm).
resource "azapi_resource" "prm_well_known" {
  type      = "Microsoft.ApiManagement/service/apis@2025-09-01-preview"
  name      = "oauth-protected-resource-metadata"
  parent_id = module.apim.resource_id

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

# RFC 9728 s3.1 path-inserted well-known operation. A spec-conformant MCP client
# validating a PATH-BEARING resource (var.prm.resource = the MCP server URL)
# fetches the document at /.well-known/oauth-protected-resource<resource-path>,
# not the bare root, and rejects a root document whose resource carries a path
# (VS Code MCP trace, 2026-07-18). This serves the SAME document there. The
# API-level policy below return-responses the document for every operation of this
# API, so this operation needs no policy of its own. count guards the degenerate
# case where the resource has no path (the urlTemplate would collide with the root
# operation). Multi-server on one gateway would need one such operation per server
# path -- an ADR-006 growth path, out of v1 scope.
resource "azapi_resource" "prm_well_known_operation_pathed" {
  count = local.prm_resource_path != "" ? 1 : 0

  type      = "Microsoft.ApiManagement/service/apis/operations@2025-09-01-preview"
  name      = "get-oauth-protected-resource-metadata-pathed"
  parent_id = azapi_resource.prm_well_known.id

  schema_validation_enabled = local.azapi_schema_validation_enabled

  body = {
    properties = {
      displayName = "Get OAuth protected resource metadata (RFC 9728 path-inserted)"
      method      = "GET"
      urlTemplate = "/.well-known/oauth-protected-resource${local.prm_resource_path}"
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

  depends_on = [
    azapi_resource.prm_well_known_operation,
    azapi_resource.prm_well_known_operation_pathed,
  ]
}
