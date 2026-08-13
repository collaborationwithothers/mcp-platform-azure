# Provider and Terraform version pins, matching the modules this composition
# calls (see docs/specs/v1-tracer-bullet.md, Terraform and state, and
# COMPATIBILITY.md). Root-module provider configuration lives here: OIDC-only,
# no client secret, no subscription or tenant id committed.

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
    # Required transitively by mcp-aks-host's wrapped AVM module (Terraform
    # Registry "Provider Dependencies": modtm ~> 0.3, random ~> 3.5).
    # Declared here so this composition's lock file pins them; no provider
    # configuration block is needed for either, same pattern s2 already uses
    # for its own transitive "time" dependency.
    modtm = {
      source  = "azure/modtm"
      version = "~> 0.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "azurerm" {
  features {}
  use_oidc = true
}

# mcp-aks-host is azapi-backed (via its wrapped AVM module); this configures
# the same provider instance it inherits implicitly as a descendant of this
# root module.
provider "azapi" {
  use_oidc = true
}
