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

  # Subscription hosting the out-of-band Application Insights resource, derived
  # from its ARM resource ID for the subscription-scoped role definition reference.
  audit_appinsights_subscription_id = split("/", var.audit_application_insights_id)[2]

  # Log Analytics Data Reader (3b03c2da-...): built-in role with the explicit
  # DataAction Microsoft.OperationalInsights/workspaces/tables/data/read.
  # Deliberately the NARROWER of two documented options (the other, Log
  # Analytics Reader, grants a broader */read Action) -- least privilege for a
  # gate script that only runs one KQL query. GUID verified 2026-08-06:
  # https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/monitor#log-analytics-data-reader
  log_analytics_data_reader_role_id = "/subscriptions/${local.audit_appinsights_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/3b03c2da-16b3-4a49-8834-0f8130efdd3b"

  # Monitoring Metrics Publisher (3913510d-...): built-in role with
  # Microsoft.Insights/Telemetry/Write and Microsoft.Insights/Metrics/Write
  # DataActions. Required for APIM's system-assigned managed identity to ingest
  # telemetry without an instrumentation key (managed-identity credential mode).
  # GUID verified 2026-08-06:
  # https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/monitor
  monitoring_metrics_publisher_role_id = "/subscriptions/${local.audit_appinsights_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/3913510d-42f4-4e42-8a64-420c390055eb"

  # ARM resource ID of the Log Analytics workspace underlying the out-of-band
  # Application Insights resource (issue 18), derived rather than a second
  # out-of-band variable. The live gate's audit-event KQL assertion needs this
  # (via az monitor log-analytics workspace show --ids ... --query customerId,
  # since az monitor log-analytics query's --workspace expects the workspace's
  # own GUID, not this ARM resource ID -- verified 2026-08-06).
  audit_workspace_id = data.azapi_resource.audit_appinsights.output.properties.WorkspaceResourceId

  # Current subscription, for the Event Hub role definitions below (same
  # subscription as this deployment -- unlike the out-of-band Application
  # Insights resource, the ephemeral audit Event Hub lives in THIS resource
  # group, so no second out-of-band subscription id is needed).
  current_subscription_id = split("/", data.azurerm_resource_group.this.id)[2]

  # Azure Event Hubs Data Sender (2b629674-...) and Data Receiver
  # (a638d3c7-...): built-in roles, DataActions Microsoft.EventHub/*/send/action
  # and Microsoft.EventHub/*/receive/action respectively. GUIDs verified
  # 2026-08-07: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/analytics
  eventhub_data_sender_role_id   = "/subscriptions/${local.current_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/2b629674-e913-4c01-ae53-ef4638d8f975"
  eventhub_data_receiver_role_id = "/subscriptions/${local.current_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/a638d3c7-ab3a-418d-83e6-5f17a39d4fde"

  prm_url = "${module.apim.apim_gateway_url}/.well-known/oauth-protected-resource"

  # Root RFC 9728 protected resource metadata document, describing the primary
  # server, served at the gateway root well-known location. Rendered here (not
  # inline in the policy template) so the policy template only ever embeds one
  # already-valid JSON value, never hand-built JSON/XML escaping. Retained even
  # in the multi-server form as the RFC 9728 s3.3 fail-closed guard: a client
  # that falls back to root while targeting another server sees a resource
  # mismatch and MUST discard this document.
  prm_root_document_json = jsonencode({
    resource                 = var.prm.root.resource
    authorization_servers    = [var.prm.authorization_server]
    bearer_methods_supported = ["header"]
    scopes_supported         = var.prm.root.scopes
  })

  # Per-server path-inserted documents (issue 17). RFC 9728 s3.1 serves the
  # metadata for a path-bearing resource at the well-known path with the resource
  # path INSERTED after it, and a spec-conformant client (VS Code) fetches THAT
  # url and rejects the bare-root document as inconsistent with a path-bearing
  # resource (VS Code MCP discovery trace, 2026-07-18; see COMPATIBILITY.md).
  # Each server behind this gateway whose resource carries a path therefore gets
  # its OWN document at its own path-inserted location, served by an
  # operation-scoped policy (a single API-level return-response cannot vary the
  # body per operation). This is the count-guarded single-server pathed operation
  # generalised to a per-server collection: RFC 9728's own multi-resource
  # construction, not a workaround (ADR-006, issue 17).
  #
  # Keyed by a stable slug (list index) because the resource path contains
  # slashes and cannot name an ARM resource; each.value.path drives the
  # urlTemplate. Servers whose resource has no path are skipped (the urlTemplate
  # would collide with the root operation).
  prm_servers = {
    for idx, s in var.prm.servers :
    "server-${idx}" => {
      resource = s.resource
      path     = try(regex("^https?://[^/]+(.*)$", s.resource)[0], "")
      document_json = jsonencode({
        resource                 = s.resource
        authorization_servers    = [var.prm.authorization_server]
        bearer_methods_supported = ["header"]
        scopes_supported         = s.scopes
      })
    }
    if try(regex("^https?://[^/]+(.*)$", s.resource)[0], "") != ""
  }
}

# Protected resource metadata (PRM) API, RFC 9728. This single well-known API
# lives in apim-gateway, not apim-mcp-server, because the well-known locations
# are a property of the gateway host: there is exactly one root path per API
# Management service. It carries one root operation (the primary server's
# document, the s3.3 fail-closed guard) plus one path-inserted operation per
# server behind the gateway (issue 17), each operation serving its own document
# via an operation-scoped policy. The documents' contents arrive as var.prm from
# the composition. apim-mcp-server is what gets instantiated once per server; the
# per-server documents this API advertises are how the single gateway host
# carries them all (the instantiate-twice contract: server instances multiply,
# this well-known API does not). See README.md.
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

# Root operation policy: serves the root document. Operation-scoped (not
# API-scoped) because each path-inserted operation below serves a DIFFERENT
# document, and an API-level return-response would terminate via <base /> before
# an operation policy could override the body. The root operation carries the
# primary server's document (the s3.3 fail-closed guard for misrouted clients).
resource "azapi_resource" "prm_well_known_root_policy" {
  type      = "Microsoft.ApiManagement/service/apis/operations/policies@2025-09-01-preview"
  name      = "policy"
  parent_id = azapi_resource.prm_well_known_operation.id

  schema_validation_enabled = local.azapi_schema_validation_enabled

  body = {
    properties = {
      format = "rawxml"
      value = templatefile("${path.module}/policies/prm-well-known.xml", {
        prm_document_json = local.prm_root_document_json
      })
    }
  }
}

# RFC 9728 s3.1 path-inserted well-known operations, one per server (issue 17). A
# spec-conformant MCP client validating a PATH-BEARING resource (a server's URL)
# fetches the document at /.well-known/oauth-protected-resource<resource-path>,
# not the bare root, and rejects a root document whose resource carries a path
# (VS Code MCP trace, 2026-07-18). Each server serves ITS OWN document here via
# the operation-scoped policy below.
resource "azapi_resource" "prm_well_known_operation_pathed" {
  for_each = local.prm_servers

  type      = "Microsoft.ApiManagement/service/apis/operations@2025-09-01-preview"
  name      = "get-oauth-protected-resource-metadata-${each.key}"
  parent_id = azapi_resource.prm_well_known.id

  schema_validation_enabled = local.azapi_schema_validation_enabled

  body = {
    properties = {
      displayName = "Get OAuth protected resource metadata (RFC 9728 path-inserted, ${each.key})"
      method      = "GET"
      urlTemplate = "/.well-known/oauth-protected-resource${each.value.path}"
    }
  }
}

# Per-server operation policy: serves that server's document at its path-inserted
# location. One per path-inserted operation.
resource "azapi_resource" "prm_well_known_pathed_policy" {
  for_each = local.prm_servers

  type      = "Microsoft.ApiManagement/service/apis/operations/policies@2025-09-01-preview"
  name      = "policy"
  parent_id = azapi_resource.prm_well_known_operation_pathed[each.key].id

  schema_validation_enabled = local.azapi_schema_validation_enabled

  body = {
    properties = {
      format = "rawxml"
      value = templatefile("${path.module}/policies/prm-well-known.xml", {
        prm_document_json = each.value.document_json
      })
    }
  }
}

# Read-only lookup of the out-of-band Application Insights connection string.
# The connection string is NOT a committed value or GitHub Environment secret:
# it is derived at plan/apply time from the ARM resource ID. In managed-identity
# credential mode the connection string identifies the ingestion endpoint only;
# actual auth to Application Insights uses APIM's system-assigned identity token,
# not the instrumentation key embedded in the string. Microsoft Learn,
# api-management-howto-app-insights (credential types), verified 2026-08-06:
# https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights
data "azapi_resource" "audit_appinsights" {
  type        = "Microsoft.Insights/components@2020-02-02"
  resource_id = var.audit_application_insights_id
  # WorkspaceResourceId: ARM resource ID of the underlying Log Analytics
  # workspace on a workspace-based Application Insights resource, documented on
  # ApplicationInsightsComponentProperties since 2020-02-02-preview, carried
  # unchanged into the 2020-02-02 GA version (issue 18: derives the audit KQL
  # query target without a second out-of-band variable). Verified 2026-08-06:
  # https://learn.microsoft.com/azure/templates/microsoft.insights/2020-02-02/components
  response_export_values = ["properties.ConnectionString", "properties.WorkspaceResourceId"]
}

# Monitoring Metrics Publisher on the out-of-band Application Insights resource,
# granted to the APIM service's system-assigned managed identity. This is the
# prerequisite for managed-identity credential mode: Microsoft.Insights/Telemetry/Write
# (a DataAction) lets the identity publish telemetry without the instrumentation key.
# Verified 2026-08-06:
# https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights#prerequisites
# Authoring pattern mirrors api-center-registry's apim_reader/data_reader role
# assignments: Microsoft.Authorization/roleAssignments@2022-04-01, deterministic
# name via uuidv5(scope|roleDef|principal), principalType = ServicePrincipal.
resource "azapi_resource" "monitoring_metrics_publisher" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "${var.audit_application_insights_id}|${local.monitoring_metrics_publisher_role_id}|${module.apim.resource.identity[0].principal_id}")
  parent_id = var.audit_application_insights_id

  body = {
    properties = {
      roleDefinitionId = local.monitoring_metrics_publisher_role_id
      principalId      = module.apim.resource.identity[0].principal_id
      principalType    = "ServicePrincipal"
    }
  }
}

# Log Analytics Data Reader on the audit workspace, for each principal in
# data_reader_principal_ids (issue 18). Lets the live gate's OIDC principal run
# the KQL query that asserts a deny emitted its audit event. Mirrors
# api-center-registry's data_reader for_each exactly: deterministic name via
# uuidv5(scope|roleDef|principal), empty list (default) => no grants.
resource "azapi_resource" "audit_log_analytics_reader" {
  for_each = toset(var.data_reader_principal_ids)

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "${local.audit_workspace_id}|${local.log_analytics_data_reader_role_id}|${each.value}")
  parent_id = local.audit_workspace_id

  body = {
    properties = {
      roleDefinitionId = local.log_analytics_data_reader_role_id
      principalId      = each.value
      principalType    = "ServicePrincipal"
    }
  }
}

# Application Insights logger for per-tool deny audit events (issue 18).
# Uses managed-identity credential mode: credentials.connectionString provides
# the ingestion endpoint; credentials.identityClientId = "SystemAssigned" directs
# APIM to authenticate via its system-assigned identity rather than the key.
# The out-of-band Application Insights resource lives in a stable resource group
# not tagged for the ephemeral-env cleanup sweep. Verified 2026-08-06:
# https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights
resource "azapi_resource" "audit_logger" {
  type      = "Microsoft.ApiManagement/service/loggers@2022-08-01"
  name      = "audit-appinsights"
  parent_id = module.apim.resource_id

  body = {
    properties = {
      loggerType  = "applicationInsights"
      description = "Out-of-band Application Insights logger for per-tool deny audit events (issue 18). Managed-identity credential mode; see docs/runbooks/observability-bootstrap.md."
      resourceId  = var.audit_application_insights_id
      credentials = {
        connectionString = data.azapi_resource.audit_appinsights.output.properties.ConnectionString
        identityClientId = "SystemAssigned"
      }
    }
  }

  depends_on = [azapi_resource.monitoring_metrics_publisher]
}

# Ephemeral Event Hub for the live gate's audit-event verification (issue
# 18), added alongside the Application Insights sink above, NOT replacing
# it: <trace> still fires on every deny and the Application Insights audit
# trail is unchanged. This exists only because Application Insights ingestion
# proved to have no bounded latency in practice -- live-gate rounds 7-9
# showed real ingestion landing anywhere from ~286s to over 600s after the
# trace fired, non-deterministically, which makes it unsuitable for a
# same-run pass/fail gate even though it remains the right long-lived,
# human-reviewable audit trail. Deliberately lives IN this ephemeral
# resource group (unlike the out-of-band Application Insights resource) and
# is destroyed with it: a verification-only signal has no reason to outlive
# the run that produced it. Basic tier, single partition, 1-day retention --
# this only ever carries one run's own denial events. azurerm schema
# (namespace_id, not the older namespace_name; sku as a plain string, not a
# block) verified 2026-08-07 against the provider's own docs source.
resource "azurerm_eventhub_namespace" "audit" {
  name                = "${var.name}-audit"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  sku                 = "Basic"
  tags                = var.tags
}

resource "azurerm_eventhub" "audit" {
  name              = "audit-denials"
  namespace_id      = azurerm_eventhub_namespace.audit.id
  partition_count   = 1
  message_retention = 1
}

# Event Hubs Data Sender on APIM's system-assigned identity, scoped to the
# Event Hub entity: prerequisite for the log-to-eventhub policy's
# managed-identity credential mode (no connection string/shared access key
# -- repo hard rule against secrets in the repo). GUID verified 2026-08-07.
resource "azapi_resource" "eventhub_data_sender" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "${azurerm_eventhub.audit.id}|${local.eventhub_data_sender_role_id}|${module.apim.resource.identity[0].principal_id}")
  parent_id = azurerm_eventhub.audit.id

  body = {
    properties = {
      roleDefinitionId = local.eventhub_data_sender_role_id
      principalId      = module.apim.resource.identity[0].principal_id
      principalType    = "ServicePrincipal"
    }
  }
}

# Event Hubs Data Receiver for each principal in data_reader_principal_ids
# (issue 18) -- the SAME variable already used for Log Analytics Data Reader
# and (in api-center-registry) API Center Data Reader, extended here so the
# live gate's OIDC principal can consume the audit-denial event it just
# triggered. GUID verified 2026-08-07.
resource "azapi_resource" "eventhub_data_receiver" {
  for_each = toset(var.data_reader_principal_ids)

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", "${azurerm_eventhub.audit.id}|${local.eventhub_data_receiver_role_id}|${each.value}")
  parent_id = azurerm_eventhub.audit.id

  body = {
    properties = {
      roleDefinitionId = local.eventhub_data_receiver_role_id
      principalId      = each.value
      principalType    = "ServicePrincipal"
    }
  }
}

# Event Hub logger for the per-tool deny audit event (issue 18), parallel to
# the Application Insights logger above, not a replacement. log-to-eventhub
# references a logger by NAME directly (no diagnostic-setting indirection,
# unlike <trace>, which reads the diagnostic setting's bound logger).
# Managed-identity credential mode verified 2026-08-07:
# https://learn.microsoft.com/azure/api-management/api-management-howto-log-event-hubs#configure-access-to-the-event-hub
resource "azapi_resource" "eventhub_logger" {
  type      = "Microsoft.ApiManagement/service/loggers@2022-08-01"
  name      = "audit-eventhub"
  parent_id = module.apim.resource_id

  body = {
    properties = {
      loggerType  = "azureEventHub"
      description = "Ephemeral Event Hub logger for the live gate's per-tool deny audit-event check (issue 18). Managed-identity credential mode; parallel to the Application Insights logger, not a replacement."
      credentials = {
        endpointAddress  = "${azurerm_eventhub_namespace.audit.name}.servicebus.windows.net"
        identityClientId = "SystemAssigned"
        name             = azurerm_eventhub.audit.name
      }
    }
  }

  depends_on = [azapi_resource.eventhub_data_sender]
}
