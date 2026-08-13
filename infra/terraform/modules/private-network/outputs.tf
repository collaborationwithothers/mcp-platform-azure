output "vnet_id" {
  value       = azurerm_virtual_network.this.id
  description = "ARM resource ID of the spoke virtual network."
}

output "vnet_name" {
  value       = azurerm_virtual_network.this.name
  description = "Name of the spoke virtual network."
}

output "aks_node_subnet_id" {
  value       = azurerm_subnet.aks_nodes.id
  description = "ARM resource ID of the AKS node subnet, for mcp-aks-host's vnet_subnet_id input."
}

output "istio_ingress_subnet_id" {
  value       = azurerm_subnet.istio_ingress.id
  description = "ARM resource ID of the Istio internal ingress gateway subnet."
}

output "istio_ingress_subnet_name" {
  value       = azurerm_subnet.istio_ingress.name
  description = "Name of the Istio internal ingress gateway subnet, for the azure-load-balancer-internal-subnet Service annotation."
}

output "apim_outbound_subnet_id" {
  value       = azurerm_subnet.apim_outbound.id
  description = "ARM resource ID of the APIM Standard v2 outbound VNet integration subnet."
}
