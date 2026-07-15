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
    # Required transitively by the api-center-registry module for its
    # destroy-time settle (time_sleep). Declared here so this composition's
    # lock file pins it. No provider configuration block is needed.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}

provider "azurerm" {
  features {
    api_management {
      # Never attempt to recover (undelete) a soft-deleted API Management
      # service on create. This composition does not rely on soft-delete
      # restore: like the API Center registry name, the APIM name is made
      # unique per deployment instance (apim_name_unique in main.tf), so a
      # create never needs to reclaim a prior tombstone. With the azurerm
      # default (recover_soft_deleted = true), a create that hit a same-named
      # tombstone attempts an undelete; for a tombstone whose original resource
      # group was deleted out of band (the ephemeral gate's belt-and-braces
      # `az group delete`, which soft-deletes APIM without purging it), that
      # undelete fails and the create hangs for over an hour before timing out
      # (observed at the s2 live gate 2026-07-14: 400 ServiceUndeleteNotPossible,
      # "Unable to undelete service"). Failing fast on a fresh create is the
      # correct behaviour here. Soft-delete/restore is documented as supported
      # for all tiers incl. Basic v2, but the resource-group-deleted precondition
      # behind ServiceUndeleteNotPossible is NOT documented; see COMPATIBILITY.md.
      recover_soft_deleted = false
    }
  }

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
