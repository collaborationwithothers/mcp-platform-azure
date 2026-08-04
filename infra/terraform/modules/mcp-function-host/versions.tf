# Provider and Terraform version pins for this module. Kept in step with the
# pins recorded in docs/specs/v1-tracer-bullet.md (Terraform and state) and
# COMPATIBILITY.md.

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
