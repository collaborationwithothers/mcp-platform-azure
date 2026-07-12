# Provider and Terraform version pins for this module. Kept in step with the
# pins recorded in docs/specs/v1-tracer-bullet.md (Terraform and state) and
# COMPATIBILITY.md. azapi is required here (not used directly by this
# module's own resources) because Azure/avm-res-apimanagement-service/azurerm
# 0.9.0 depends on it internally; Terraform resolves and locks provider
# requirements per validated directory, so the calling module must declare
# it too.

terraform {
  required_version = ">= 1.15.8, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.80"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.10"
    }
  }
}
