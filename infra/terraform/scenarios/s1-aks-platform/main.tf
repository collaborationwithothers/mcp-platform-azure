data "terraform_remote_state" "shared_observability_core" {
  backend = "azurerm"

  config = {
    storage_account_name = var.shared_observability_core_remote_state.storage_account_name
    container_name       = var.shared_observability_core_remote_state.container_name
    key                  = var.shared_observability_core_remote_state.key
    use_oidc             = true
    use_azuread_auth     = true
  }
}

data "terraform_remote_state" "shared_observability_metrics" {
  backend = "azurerm"

  config = {
    storage_account_name = var.shared_observability_metrics_remote_state.storage_account_name
    container_name       = var.shared_observability_metrics_remote_state.container_name
    key                  = var.shared_observability_metrics_remote_state.key
    use_oidc             = true
    use_azuread_auth     = true
  }
}

locals {
  log_analytics_workspace_id = data.terraform_remote_state.shared_observability_core.outputs.log_analytics_workspace_id
  application_insights_id    = data.terraform_remote_state.shared_observability_core.outputs.application_insights_id
  azure_monitor_workspace_id = data.terraform_remote_state.shared_observability_metrics.outputs.azure_monitor_workspace_id

  mcp_workload_subject  = "system:serviceaccount:${var.mcp_namespace}:${var.mcp_service_account_name}"
  mcp_private_dns_zone  = "internal.consultwithcloud.com"
  mcp_private_hostname  = "mcp.${local.mcp_private_dns_zone}"
  mcp_resource_audience = one(data.azuread_application.mcp_server.identifier_uris)
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

  # Argo CD's public external Istio gateway needs inbound Internet 80/443 to the
  # node subnet (issue 121, ADR-011); without it the node NSG's default rules
  # deny the public path and the endpoint times out. Scoped to this composition;
  # the module keeps its private-only default for any other caller.
  public_https_ingress_enabled = true
}

module "aks" {
  source = "../../modules/mcp-aks-host"

  name                       = var.cluster_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tags                       = var.tags
  node_subnet_id             = module.network.aks_node_subnet_id
  log_analytics_workspace_id = local.log_analytics_workspace_id
  azure_monitor_workspace_id = local.azure_monitor_workspace_id
  managed_prometheus_enabled = var.managed_prometheus_enabled
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

# Argo CD's public entry point (issue 121, ADR-011). The external Istio gateway
# is enabled in mcp-aks-host; these two resources make it reachable at a stable
# public address.
#
# The public IP is pre-created (Standard SKU, Static) so the deploy workflow can
# pin the external gateway's load balancer to it with the
# service.beta.kubernetes.io/azure-pip-name annotation. Pinning matters for the
# same reason the internal gateway's IP is pinned: the address must survive the
# az aks stop/start idle cycle and the Cloudflare record must keep pointing at
# it. It lives in the AKS-managed node resource group (MC_*), where AKS's own
# load balancer and public IPs already land (see mcp-aks-host/outputs.tf,
# node_resource_group_name), so the cluster identity already has rights over it
# and no extra role assignment is needed -- this is Microsoft's documented
# bring-your-own-public-IP pattern for AKS LoadBalancer services.
resource "azurerm_public_ip" "argocd" {
  name                = "${var.name_prefix}-argocd-pip"
  resource_group_name = module.aks.node_resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# DNS-only (grey-cloud) A record: Cloudflare resolves the name to the pinned
# public IP but does NOT proxy the traffic (proxied = false). ADR-011 keeps
# Cloudflare to DNS alone; the security posture is Entra SSO plus read-only
# Argo CD RBAC, with no Cloudflare WAF in the path.
resource "cloudflare_dns_record" "argocd" {
  zone_id = var.cloudflare_zone_id
  name    = var.argocd_hostname
  type    = "A"
  content = azurerm_public_ip.argocd.ip_address
  ttl     = 300
  proxied = false
  # Cloudflare caps this field at 100 characters.
  comment = "Argo CD public UI/API (issue 121, ADR-011)."
}

# Workload identity for argocd-server's Entra OIDC token exchange (issue 121,
# ADR-011). Argo CD 3.1+ redeems the OIDC code server-side, which Entra will not
# do for an SPA/PKCE client, and a client secret is a second non-OIDC credential
# this repo forbids. So argocd-server authenticates with a federated managed
# identity instead: the Entra app (created out of band, read here by client id,
# same pattern as s1-entra-mcp-server) gets a federated identity credential
# trusting the argocd-server Kubernetes ServiceAccount through the cluster's OIDC
# issuer. The matching pod label and ServiceAccount annotation live in the Argo
# CD Helm values (infra/argocd/public-access/argocd-server-values.yaml).
data "azuread_application" "argocd" {
  client_id = var.argocd_oidc_client_id
}

resource "azuread_application_federated_identity_credential" "argocd_server" {
  application_id = data.azuread_application.argocd.id
  display_name   = "argocd-server-workload-identity"
  description    = "Lets argocd-server use AKS workload identity for its Entra OIDC token exchange (issue 121)."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = module.aks.oidc_issuer_url
  subject        = "system:serviceaccount:${var.argocd_namespace}:${var.argocd_server_service_account_name}"
}

# The migrated MCP server uses one Kubernetes ServiceAccount but two distinct
# federation targets. The managed identity is the pod's Azure resource identity.
# The existing Entra server application is the confidential client identity
# MSAL uses for the on-behalf-of exchange. Both credentials trust the same AKS
# issuer and ServiceAccount subject; neither credential contains a secret.
resource "azurerm_user_assigned_identity" "mcp_workload" {
  name                = "${var.name_prefix}-mcp-workload-id"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "mcp_workload" {
  name                      = "${var.name_prefix}-mcp-workload-fic"
  user_assigned_identity_id = azurerm_user_assigned_identity.mcp_workload.id
  issuer                    = module.aks.oidc_issuer_url
  subject                   = local.mcp_workload_subject
  audience                  = ["api://AzureADTokenExchange"]
}

data "azuread_application" "mcp_server" {
  client_id = var.mcp_server_application_client_id
}

resource "azuread_application_federated_identity_credential" "mcp_server" {
  application_id = data.azuread_application.mcp_server.id
  display_name   = "mcp-server-workload-identity"
  description    = "Lets the AKS MCP server use workload identity as its confidential client credential for OBO (issue 149)."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = module.aks.oidc_issuer_url
  subject        = local.mcp_workload_subject
}

# The MCP pod publishes telemetry through Entra authentication. The deployment
# workflow supplies the Application Insights connection string as live-only
# runtime configuration, so the pod has no management-plane read permission.
resource "azurerm_role_assignment" "mcp_monitoring_metrics_publisher" {
  scope                            = local.application_insights_id
  role_definition_name             = "Monitoring Metrics Publisher"
  principal_id                     = azurerm_user_assigned_identity.mcp_workload.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# Azure Private DNS is owned by this composition because it joins the platform
# VNet created here to the existing runner VNet supplied by the live-test
# environment. No public DNS record is created for this hostname.
resource "azurerm_private_dns_zone" "mcp" {
  name                = local.mcp_private_dns_zone
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_a_record" "mcp" {
  name                = "mcp"
  zone_name           = azurerm_private_dns_zone.mcp.name
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [var.ingress_gateway_private_ip]
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "mcp_platform" {
  name                  = "${var.name_prefix}-mcp-platform-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.mcp.name
  virtual_network_id    = module.network.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "mcp_runner" {
  name                  = "${var.name_prefix}-mcp-runner-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.mcp.name
  virtual_network_id    = var.runner_vnet_id
  registration_enabled  = false
  tags                  = var.tags
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
  name                      = "${var.name_prefix}-placeholder-workload-fic"
  user_assigned_identity_id = azurerm_user_assigned_identity.placeholder_workload.id
  issuer                    = module.aks.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.placeholder_namespace}:${var.placeholder_service_account_name}"
  audience                  = ["api://AzureADTokenExchange"]
}
