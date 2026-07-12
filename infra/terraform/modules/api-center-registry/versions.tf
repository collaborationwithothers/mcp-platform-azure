# Provider and Terraform version pins for this module. Kept in step with the
# pins recorded in docs/specs/v1-tracer-bullet.md (Terraform and state) and
# COMPATIBILITY.md. Hand-authored azapi only: API Center has no native azurerm
# resource (provider issue hashicorp/terraform-provider-azurerm#26200, still
# open, confirmed 2026-07-12), so every resource here is azapi. The one
# non-API-Center resource, the API Management Service Reader role assignment
# the managed identity needs to read APIM, is also authored via azapi to keep
# this module single-provider.

terraform {
  required_version = ">= 1.15.8, < 2.0.0"

  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.10"
    }
  }
}
