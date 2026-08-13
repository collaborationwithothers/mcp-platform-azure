# Provider and Terraform version pins for this module. Kept in step with the
# pins recorded in docs/specs/v1-tracer-bullet.md (Terraform and state) and
# COMPATIBILITY.md. The Azure/avm-res-containerservice-managedcluster/azurerm
# module this module wraps declares azapi and random as its own provider
# dependencies (Terraform Registry, "Provider Dependencies", checked at issue
# start); azapi is pinned to this repo's existing ~> 2.10 line rather than the
# module's own ~> 2.9 floor, since every other module in this repo already
# pins azapi ~> 2.10 and a single shared constraint keeps one lock file
# resolution across the whole tree.

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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}
