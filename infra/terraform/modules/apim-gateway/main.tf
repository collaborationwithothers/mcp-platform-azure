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
