module "network" {
  source = "../../modules/private-network"

  name_prefix                = var.name_prefix
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tags                       = var.tags
  runner_vnet_id             = var.runner_vnet_id
  ingress_gateway_private_ip = var.ingress_gateway_private_ip
}

module "aks" {
  source = "../../modules/mcp-aks-host"

  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
  node_subnet_id      = module.network.aks_node_subnet_id
}

module "registry" {
  source = "../../modules/container-registry"

  name                = var.registry_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

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
  name                = "${var.name_prefix}-placeholder-workload-fic"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.placeholder_workload.id
  issuer              = module.aks.oidc_issuer_url
  subject             = "system:serviceaccount:${var.placeholder_namespace}:${var.placeholder_service_account_name}"
  audience            = ["api://AzureADTokenExchange"]
}
