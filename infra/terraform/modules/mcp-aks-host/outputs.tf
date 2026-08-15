output "cluster_id" {
  value       = module.aks.resource_id
  description = "ARM resource ID of the AKS cluster."
}

output "cluster_name" {
  value       = module.aks.name
  description = "Name of the AKS cluster."
}

output "oidc_issuer_url" {
  value       = module.aks.oidc_issuer_profile_issuer_url
  description = "OIDC issuer URL, for a workload's federated identity credential (subject system:serviceaccount:<namespace>:<serviceaccount>, audience api://AzureADTokenExchange)."
}

output "cluster_identity_principal_id" {
  value       = module.aks.identity_principal_id
  description = "Principal id of the cluster's own system-assigned identity (used by AKS control-plane components), for role assignments the composition grants it -- for example Network Contributor on the node/ingress subnets when using a bring-your-own VNet."
}

output "node_resource_group_name" {
  value       = module.aks.node_resource_group_name
  description = "Name of the AKS-managed node resource group. The Istio ingress gateway's load balancer and public IP resources land here, not in resource_group_name."
}

# Passed through without deconstructing individual keys: the AVM module's own
# docs describe this as an object "including clientId, objectId, and
# resourceId" without stating their exact casing, and this module does not
# assert a shape it has not verified. The container-registry AcrPull role
# assignment (owned by the scenario composition, not this module) reads
# whichever key is correct at plan time.
output "kubelet_identity" {
  value       = module.aks.kubelet_identity
  description = "The kubelet identity of the managed cluster (clientId, objectId, resourceId per the AVM module's own description), for the composition's AcrPull role assignment to the container registry."
}

output "managed_prometheus_data_collection_rule_id" {
  value       = try(azurerm_monitor_data_collection_rule.managed_prometheus[0].id, null)
  description = "ARM resource ID of the managed Prometheus data collection rule, or null when managed Prometheus is disabled."
}
