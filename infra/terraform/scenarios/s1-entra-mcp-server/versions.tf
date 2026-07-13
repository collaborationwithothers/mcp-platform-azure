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
  # mcp-function-host's storage account has shared_access_key_enabled = false
  # (managed-identity-only access). The azurerm provider's default post-create
  # data-plane availability poll authenticates with the storage account key,
  # which then fails with KeyBasedAuthenticationNotPermitted. data_plane_available
  # = false skips that poll; safe here because this resource uses neither the
  # queue_properties nor static_website blocks (the two cases the flag doesn't
  # support). Flag introduced in azurerm provider v4.9.0, verified against the
  # provider's features-block guide, 2026-07-13.
  features {
    storage {
      data_plane_available = false
    }
  }

  use_oidc = true
}

# Required alongside mcp-function-host even though this composition's own
# resources are all azurerm: avm-res-web-site 0.22.0 depends on azapi
# internally, and Terraform resolves/locks provider requirements per root
# module, so the composition must configure it too (same reasoning as
# apim-gateway's versions.tf). The azapi provider schema has no `features`
# block (that is azurerm-specific; verified 2026-07-12 against the azapi
# provider's own schema reference, not assumed from its OIDC guide example).
provider "azapi" {
  use_oidc = true
}
