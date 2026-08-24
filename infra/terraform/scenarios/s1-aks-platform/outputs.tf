output "cluster_name" {
  value       = module.aks.cluster_name
  description = "Name of the AKS cluster, for kubelogin / az aks get-credentials in the deploy-and-bootstrap workflow."
}

output "node_resource_group_name" {
  value       = module.aks.node_resource_group_name
  description = "AKS-managed node resource group, where the Istio ingress gateway's load balancer lands."
}

output "registry_login_server" {
  value       = module.registry.login_server
  description = "Login server hostname for the placeholder image pipeline (az acr login / docker push)."
}

output "istio_ingress_subnet_name" {
  value       = module.network.istio_ingress_subnet_name
  description = "Subnet name for the azure-load-balancer-internal-subnet Service annotation the deploy-and-bootstrap workflow sets on the Istio ingress gateway's Service."
}

output "ingress_gateway_private_ip" {
  value       = var.ingress_gateway_private_ip
  description = "Pinned private IP for the azure-load-balancer-ipv4 Service annotation, passed straight through so the deploy-and-bootstrap workflow reads it from one place (this composition's own output, not a second copy of the input)."
}

output "placeholder_workload_client_id" {
  value       = azurerm_user_assigned_identity.placeholder_workload.client_id
  description = "Client id for the placeholder workload's ServiceAccount azure.workload.identity/client-id annotation, in the separate mcp-platform-kubernetes-manifests repo."
}

output "mcp_workload_client_id" {
  value       = azurerm_user_assigned_identity.mcp_workload.client_id
  description = "Client id for the migrated MCP server ServiceAccount azure.workload.identity/client-id annotation."
}

output "mcp_server_application_client_id" {
  value       = var.mcp_server_application_client_id
  description = "Existing MCP server Entra application client id for the migrated workload's OBO configuration."
}

output "mcp_namespace" {
  value       = var.mcp_namespace
  description = "Kubernetes namespace that must be used by the migrated MCP server manifests."
}

output "mcp_service_account_name" {
  value       = var.mcp_service_account_name
  description = "Kubernetes ServiceAccount name that must be used by the migrated MCP server manifests."
}

output "orders_workload_client_id" {
  value       = azurerm_user_assigned_identity.orders_workload.client_id
  description = "Client id for the Orders API ServiceAccount azure.workload.identity/client-id annotation."
}

output "orders_namespace" {
  value       = var.orders_namespace
  description = "Kubernetes namespace that the Orders API manifests must use."
}

output "orders_service_account_name" {
  value       = var.orders_service_account_name
  description = "Kubernetes ServiceAccount name that the Orders API manifests must use."
}

output "orders_telemetry_resource_id" {
  value       = local.application_insights_id
  description = "Application Insights resource ID the deployment workflow uses to retrieve the live-only Orders telemetry connection string."
}

output "mcp_private_hostname" {
  value       = local.mcp_private_hostname
  description = "Private MCP hostname resolved only from the platform and runner VNets."
}

output "mcp_resource_audience" {
  value       = local.mcp_resource_audience
  description = "App ID URI the migrated MCP server validates as its resource audience."
}

output "istio_revision" {
  value       = module.aks.istio_revision
  description = "Istio revision configured by Terraform for the AKS service mesh. The companion namespace label must use an installed revision with this value."
}

output "argocd_public_ip_name" {
  value       = azurerm_public_ip.argocd.name
  description = "Name of the pinned Standard public IP for Argo CD's external Istio gateway, for the service.beta.kubernetes.io/azure-pip-name annotation the deploy workflow sets."
}

output "argocd_public_ip_address" {
  value       = azurerm_public_ip.argocd.ip_address
  description = "The pinned public IPv4 address the external gateway's load balancer must report; the deploy workflow waits for the Service to reach exactly this address."
}

output "argocd_hostname" {
  value       = var.argocd_hostname
  description = "Public DNS name for Argo CD, passed straight through so the deploy workflow reads the Gateway host and OIDC base URL from one place."
}
