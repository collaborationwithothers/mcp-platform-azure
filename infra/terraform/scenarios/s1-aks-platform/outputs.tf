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
