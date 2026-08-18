# Spoke virtual network for the epic 108 child (b) private-backend profile:
# an AKS node subnet, a dedicated subnet for the Istio internal ingress
# gateway, and a delegated subnet for APIM Standard v2 outbound VNet
# integration. See README.md for the address plan and its reasoning.
#
# Hand-authored azurerm (not an AVM wrapper): avm-res-network-virtualnetwork
# exists (Azure/avm-res-network-virtualnetwork/azurerm 0.22.1, confirmed via
# the Terraform registry at issue start), but this module's shape -- three
# purpose-specific subnets, one with a service delegation, one carrying a
# caller-pinned address, plus a two-sided peering link to the runner VNet --
# is small enough that a raw azurerm_virtual_network/azurerm_subnet pair is
# the whole
# module, not a fraction of one. The general fallback policy
# (docs/specs/v1-tracer-bullet.md, Terraform and state) treats dropping AVM
# from a whole module as an ADR moment only when AVM cannot express what the
# module needs; here it is a deliberate size choice, not a capability gap.

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.name_prefix}-vnet"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  address_space       = var.address_space
  tags                = var.tags
}

# One network security group per subnet, default rules only (no custom allow
# rules). AKS and the APIM outbound integration both manage the connectivity
# they need through Azure-managed control-plane paths, not through rules this
# module would author; an NSG with only Azure's defaults still satisfies the
# "every subnet has an NSG" posture check and gives a future PR a named place
# to add a rule instead of starting from nothing.
resource "azurerm_network_security_group" "aks_nodes" {
  name                = "${var.name_prefix}-nsg-aks-nodes"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = var.tags

  # Optional inbound public HTTP/HTTPS allow for a public ingress gateway on the
  # node subnet (issue 121, ADR-011: the Argo CD external Istio gateway). Off by
  # default so this module keeps its private-only posture; s1-aks-platform turns
  # it on. Why it is needed: the external gateway's public load balancer forwards
  # 80/443 to the gateway pods, which run on this node subnet, but the subnet
  # NSG's default rules deny inbound Internet traffic, so the public path would
  # otherwise time out at the NSG. This is the only inbound-from-Internet rule on
  # the platform. The internal ingress gateway uses an internal load balancer
  # with no public frontend, so it is unaffected, and the default
  # AllowAzureLoadBalancerInBound rule still permits the health probe.
  dynamic "security_rule" {
    for_each = var.public_https_ingress_enabled ? [1] : []
    content {
      name                       = "AllowPublicIngressInbound"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_ranges    = ["80", "443"]
      source_address_prefix      = "Internet"
      destination_address_prefix = var.node_subnet_cidr
    }
  }
}

resource "azurerm_network_security_group" "istio_ingress" {
  name                = "${var.name_prefix}-nsg-istio-ingress"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_network_security_group" "apim_outbound" {
  name                = "${var.name_prefix}-nsg-apim-outbound"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_subnet" "aks_nodes" {
  name                 = "${var.name_prefix}-snet-aks-nodes"
  resource_group_name  = data.azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.node_subnet_cidr]
}

resource "azurerm_subnet_network_security_group_association" "aks_nodes" {
  subnet_id                 = azurerm_subnet.aks_nodes.id
  network_security_group_id = azurerm_network_security_group.aks_nodes.id
}

# No delegation: the Istio internal ingress gateway's load balancer is a
# standard Azure internal load balancer, not a delegated PaaS integration.
resource "azurerm_subnet" "istio_ingress" {
  name                 = "${var.name_prefix}-snet-istio-ingress"
  resource_group_name  = data.azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.ingress_gateway_subnet_cidr]
}

resource "azurerm_subnet_network_security_group_association" "istio_ingress" {
  subnet_id                 = azurerm_subnet.istio_ingress.id
  network_security_group_id = azurerm_network_security_group.istio_ingress.id
}

# Delegated to Microsoft.Web/serverFarms: APIM's Standard v2/Premium v2
# outbound VNet integration reuses the same App Service network integration
# mechanism as Azure Functions/App Service VNet integration, and delegates its
# subnet the same way (Microsoft Learn, integrate-vnet-outbound prerequisites,
# verified at issue start; see COMPATIBILITY.md).
resource "azurerm_subnet" "apim_outbound" {
  name                 = "${var.name_prefix}-snet-apim-outbound"
  resource_group_name  = data.azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.apim_outbound_subnet_cidr]

  delegation {
    name = "apim-outbound-integration"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "apim_outbound" {
  subnet_id                 = azurerm_subnet.apim_outbound.id
  network_security_group_id = azurerm_network_security_group.apim_outbound.id
}

# Azure VNet peering is symmetric: a working connection needs a matching link
# on each side. Both sides are created by this module (Hari, 2026-08-13,
# correcting this module's original one-sided design): the runner VNet is in
# the same subscription as this platform, and the live-test environment's
# OIDC-federated identity already carries RBAC on that subscription, so there
# is no ownership boundary stopping this module from also managing the
# reverse link -- unlike a genuinely external subscription, which would be a
# real blast-radius violation. The runner's resource group and VNet name are
# parsed out of runner_vnet_id (already regex-validated in variables.tf)
# rather than taken as separate variables, so there is exactly one place a
# caller can get the runner network's identity wrong.
#
# allow_forwarded_traffic is true both ways because either side's path to the
# other may traverse more than one hop inside its own network;
# allow_gateway_transit and use_remote_gateways are both false because
# neither network is a gateway transit hub (no ExpressRoute/VPN gateway on
# either side of this peering).
locals {
  runner_vnet_id_parts   = split("/", var.runner_vnet_id)
  runner_resource_group  = local.runner_vnet_id_parts[4]
  runner_virtual_network = local.runner_vnet_id_parts[8]
}

resource "azurerm_virtual_network_peering" "to_runner_network" {
  name                         = "${var.name_prefix}-peer-to-github-actions-runner"
  resource_group_name          = data.azurerm_resource_group.this.name
  virtual_network_name         = azurerm_virtual_network.this.name
  remote_virtual_network_id    = var.runner_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "from_runner_network" {
  name                         = "peer-to-${var.name_prefix}-spoke"
  resource_group_name          = local.runner_resource_group
  virtual_network_name         = local.runner_virtual_network
  remote_virtual_network_id    = azurerm_virtual_network.this.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
