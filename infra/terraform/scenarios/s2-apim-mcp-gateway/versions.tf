# Provider and Terraform version pins, matching the modules this composition
# calls (see docs/specs/v1-tracer-bullet.md, Terraform and state, and
# COMPATIBILITY.md). Root-module provider configuration lives here: OIDC-only,
# no client secret, no subscription or tenant id committed. tenant_id,
# client_id, and subscription_id come from the ARM_TENANT_ID, ARM_CLIENT_ID,
# and ARM_SUBSCRIPTION_ID environment variables the live-test workflow sets
# from its OIDC-federated GitHub Actions identity (verified against the
# azurerm and azapi provider "Authenticating via OpenID Connect" guides,
# 2026-07-12).

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

provider "azurerm" {
  features {}

  use_oidc = true
}

# apim-mcp-server and api-center-registry are hand-authored azapi modules;
# this configures the same provider instance they inherit implicitly as
# descendants of this root module. The azapi provider schema has no
# `features` block (that is azurerm-specific; verified 2026-07-12 against the
# azapi provider's own schema reference, not assumed from its OIDC guide
# example).
provider "azapi" {
  use_oidc = true
}
