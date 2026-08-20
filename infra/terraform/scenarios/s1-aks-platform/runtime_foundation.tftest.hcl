# Exercises the shipped S1 AKS composition without Azure credentials. Mocked
# modules isolate the issue 149 composition seam; the assertions below still
# evaluate the real identity, role, DNS, and promotion-output resources.

mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "azapi" {}
mock_provider "cloudflare" {}
mock_provider "modtm" {}
mock_provider "random" {}

override_data {
  target = data.terraform_remote_state.shared_observability_core
  values = {
    outputs = {
      log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.OperationalInsights/workspaces/test"
      application_insights_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.Insights/components/test"
    }
  }
}

override_data {
  target = data.terraform_remote_state.shared_observability_metrics
  values = {
    outputs = {
      azure_monitor_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.Monitor/accounts/test"
    }
  }
}

override_data {
  target = data.azuread_application.argocd
  values = {
    id = "/applications/11111111-1111-1111-1111-111111111111"
  }
}

override_data {
  target = data.azuread_application.mcp_server
  values = {
    id              = "/applications/22222222-2222-2222-2222-222222222222"
    identifier_uris = ["api://mcp-server"]
  }
}

override_module {
  target = module.network
  outputs = {
    vnet_id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.Network/virtualNetworks/platform"
    aks_node_subnet_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.Network/virtualNetworks/platform/subnets/aks"
    istio_ingress_subnet_name = "snet-istio-ingress"
  }
}

override_module {
  target = module.aks
  outputs = {
    cluster_name                  = "test-aks"
    oidc_issuer_url               = "https://oidc.test/"
    cluster_identity_principal_id = "33333333-3333-3333-3333-333333333333"
    node_resource_group_name      = "MC_test"
    kubelet_identity = {
      objectId = "44444444-4444-4444-4444-444444444444"
    }
    istio_revision = "asm-1-29"
  }
}

override_module {
  target = module.registry
  outputs = {
    login_server = "test.azurecr.io"
  }
}

override_resource {
  target          = azurerm_user_assigned_identity.mcp_workload
  override_during = plan
  values = {
    id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mcp-workload"
    client_id    = "55555555-5555-5555-5555-555555555555"
    principal_id = "66666666-6666-6666-6666-666666666666"
  }
}

run "plans_private_mcp_runtime_foundation" {
  command = plan

  variables {
    resource_group_name              = "rg-test"
    location                         = "uksouth"
    cluster_name                     = "test-aks"
    registry_name                    = "testregistry"
    runner_vnet_id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.Network/virtualNetworks/runner"
    ingress_gateway_private_ip       = "10.20.2.10"
    cloudflare_zone_id               = "test-zone"
    cloudflare_api_token             = "test-token"
    argocd_oidc_client_id            = "77777777-7777-7777-7777-777777777777"
    mcp_server_application_client_id = "88888888-8888-8888-8888-888888888888"
    shared_observability_core_remote_state = {
      storage_account_name = "teststate"
      container_name       = "tfstate"
      key                  = "core.tfstate"
    }
    shared_observability_metrics_remote_state = {
      storage_account_name = "teststate"
      container_name       = "tfstate"
      key                  = "metrics.tfstate"
    }
  }

  assert {
    condition = (
      azurerm_user_assigned_identity.mcp_workload.name
      != azurerm_user_assigned_identity.placeholder_workload.name
      && azurerm_federated_identity_credential.mcp_workload.subject
      != azurerm_federated_identity_credential.placeholder_workload.subject
      &&
      azurerm_federated_identity_credential.mcp_workload.user_assigned_identity_id
      == azurerm_user_assigned_identity.mcp_workload.id
      && azurerm_federated_identity_credential.mcp_workload.subject
      == "system:serviceaccount:mcp-platform:mcp-server"
      && length(azurerm_federated_identity_credential.mcp_workload.audience) == 1
      && tolist(azurerm_federated_identity_credential.mcp_workload.audience)[0]
      == "api://AzureADTokenExchange"
    )
    error_message = "The MCP identity and subject must stay distinct from the placeholder and trust only the token-exchange audience."
  }

  assert {
    condition = (
      azuread_application_federated_identity_credential.mcp_server.application_id
      == data.azuread_application.mcp_server.id
      && azuread_application_federated_identity_credential.mcp_server.subject
      == azurerm_federated_identity_credential.mcp_workload.subject
      && length(azuread_application_federated_identity_credential.mcp_server.audiences) == 1
      && tolist(azuread_application_federated_identity_credential.mcp_server.audiences)[0]
      == "api://AzureADTokenExchange"
    )
    error_message = "The existing MCP server app and MCP managed identity must trust the same dedicated ServiceAccount subject."
  }

  assert {
    condition = (
      azurerm_role_assignment.mcp_monitoring_metrics_publisher.scope
      == data.terraform_remote_state.shared_observability_core.outputs.application_insights_id
      && azurerm_role_assignment.mcp_monitoring_metrics_publisher.principal_id
      == azurerm_user_assigned_identity.mcp_workload.principal_id
      && azurerm_role_assignment.mcp_monitoring_metrics_publisher.role_definition_name
      == "Monitoring Metrics Publisher"
    )
    error_message = "Monitoring Metrics Publisher must be scoped to shared Application Insights and granted to the MCP managed identity principal."
  }

  assert {
    condition = (
      azurerm_role_assignment.mcp_application_insights_reader.scope
      == data.terraform_remote_state.shared_observability_core.outputs.application_insights_id
      && azurerm_role_assignment.mcp_application_insights_reader.principal_id
      == azurerm_user_assigned_identity.mcp_workload.principal_id
      && azurerm_role_assignment.mcp_application_insights_reader.role_definition_name
      == "Reader"
    )
    error_message = "Reader must be scoped to shared Application Insights and granted to the MCP managed identity principal."
  }

  assert {
    condition = (
      azurerm_private_dns_zone.mcp.name == "internal.consultwithcloud.com"
      && azurerm_private_dns_a_record.mcp.name == "mcp"
      && length(azurerm_private_dns_a_record.mcp.records) == 1
      && tolist(azurerm_private_dns_a_record.mcp.records)[0] == "10.20.2.10"
    )
    error_message = "Private DNS must resolve mcp.internal.consultwithcloud.com to the pinned internal gateway address."
  }

  assert {
    condition = (
      azurerm_private_dns_zone_virtual_network_link.mcp_platform.virtual_network_id
      == module.network.vnet_id
      && azurerm_private_dns_zone_virtual_network_link.mcp_runner.virtual_network_id
      == var.runner_vnet_id
      && !azurerm_private_dns_zone_virtual_network_link.mcp_platform.registration_enabled
      && !azurerm_private_dns_zone_virtual_network_link.mcp_runner.registration_enabled
    )
    error_message = "The private zone must link to both platform and runner VNets with registration disabled."
  }

  assert {
    condition = (
      output.mcp_workload_client_id == azurerm_user_assigned_identity.mcp_workload.client_id
      && output.mcp_server_application_client_id == "88888888-8888-8888-8888-888888888888"
      && output.mcp_namespace == "mcp-platform"
      && output.mcp_service_account_name == "mcp-server"
      && output.mcp_private_hostname == "mcp.internal.consultwithcloud.com"
      && output.mcp_resource_audience == "api://mcp-server"
      && output.istio_revision == "asm-1-29"
    )
    error_message = "Promotion outputs must expose the non-secret identity, resource, hostname, and configured Istio revision inputs."
  }
}
