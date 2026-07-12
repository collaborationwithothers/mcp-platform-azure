# Provider and Terraform version pins for this module. Kept in step with the
# pins recorded in docs/specs/v1-tracer-bullet.md (Terraform and state) and
# COMPATIBILITY.md. Hand-authored azapi only: the APIM MCP server and its
# policies have no native azurerm resource (confirmed 2026-07-12,
# https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api).

terraform {
  required_version = ">= 1.15.8, < 2.0.0"

  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.10"
    }
  }
}
