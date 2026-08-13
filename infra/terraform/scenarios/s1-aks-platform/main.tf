# The shared observability Application Insights component is provisioned out
# of band, exactly as s1-entra-mcp-server and s2-apim-mcp-gateway already read
# it. Its workspace-based component properties identify the Log Analytics
# workspace this composition's new resources send diagnostics to.
data "azapi_resource" "shared_observability_application_insights" {
  type        = "Microsoft.Insights/components@2020-02-02"
  resource_id = var.shared_observability_application_insights_id

  response_export_values = ["properties.WorkspaceResourceId"]
}

locals {
  log_analytics_workspace_id = data.azapi_resource.shared_observability_application_insights.output.properties.WorkspaceResourceId
}

module "network" {
  source = "../../modules/private-network"

  name_prefix                = var.name_prefix
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tags                       = var.tags
  runner_vnet_id             = var.runner_vnet_id
  ingress_gateway_private_ip = var.ingress_gateway_private_ip
  log_analytics_workspace_id = local.log_analytics_workspace_id
}

module "aks" {
  source = "../../modules/mcp-aks-host"

  name                       = var.cluster_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tags                       = var.tags
  node_subnet_id             = module.network.aks_node_subnet_id
  log_analytics_workspace_id = local.log_analytics_workspace_id
}

# AKS uses its cluster identity, rather than the kubelet identity, to manage
# the internal load balancer. Microsoft Learn requires Network Contributor on
# the virtual network. That documented scope covers both the node and Istio
# ingress subnets that the load balancer uses.
resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                            = module.network.vnet_id
  role_definition_name             = "Network Contributor"
  principal_id                     = module.aks.cluster_identity_principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

module "registry" {
  source = "../../modules/container-registry"

  name                       = var.registry_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tags                       = var.tags
  log_analytics_workspace_id = local.log_analytics_workspace_id

  # The AKS cluster's kubelet identity pulls images; the CI identity pushes
  # them (issue 110 task 4). kubelet_identity is passed through undeconstructed
  # by mcp-aks-host (see its outputs.tf) because the AVM module's own docs do
  # not state its key casing; .objectId is this repo's best-verified read of
  # that shape (ARM's identityProfile.kubeletidentity is returned camelCase),
  # confirmed at terraform validate / plan time, not asserted stronger than
  # that here.
  acr_pull_principal_ids = [module.aks.kubelet_identity.objectId]
  acr_push_principal_ids = var.acr_push_principal_ids
}

# User-assigned identity the placeholder workload's pod uses via workload
# identity federation (issue 110 section 2, "Workload identity uses a
# user-assigned managed identity" -- forced because a system-assigned
# identity cannot hold a federated identity credential at all). This
# composition creates the identity and its federated credential; the
# placeholder workload's own ServiceAccount (in the manifests repo) carries
# the matching azure.workload.identity/client-id annotation and
# azure.workload.identity/use: "true" pod label.
resource "azurerm_user_assigned_identity" "placeholder_workload" {
  name                = "${var.name_prefix}-placeholder-workload-id"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "placeholder_workload" {
  # resource_group_name deliberately omitted: azurerm provider ~> 4.80
  # (this repo's pin) warns "This field is no longer used and will be
  # removed in the next major version of the Azure Provider" -- confirmed
  # live (Hari's bootstrap apply, 2026-08-13), not from static docs, since
  # the Terraform Registry's rendered docs for this resource already show
  # only the next-major argument shape (user_assigned_identity_id) and do
  # not preserve this provider line's exact deprecated-vs-required argument
  # set. parent_id alone already fully identifies the resource group and
  # parent identity.
  name      = "${var.name_prefix}-placeholder-workload-fic"
  parent_id = azurerm_user_assigned_identity.placeholder_workload.id
  issuer    = module.aks.oidc_issuer_url
  subject   = "system:serviceaccount:${var.placeholder_namespace}:${var.placeholder_service_account_name}"
  audience  = ["api://AzureADTokenExchange"]
}
