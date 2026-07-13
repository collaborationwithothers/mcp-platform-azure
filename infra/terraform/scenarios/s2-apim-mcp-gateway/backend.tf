# Remote state on an azurerm backend, OIDC-only (docs/specs/v1-tracer-bullet.md,
# Terraform and state). Deliberately partial: storage_account_name,
# container_name, and key are supplied via -backend-config by
# .github/workflows/ephemeral-env.yml at real-init time, so no account name,
# container, or state key is committed here. This composition's key is
# distinct from s1-entra-mcp-server's (key-per-composition isolation); it
# reads THAT composition's state read-only via the terraform_remote_state
# data source in main.tf, using the same storage account but a different key.
# PR CI only ever runs `init -backend=false` and never reaches this block;
# only the gated live-test workflow does.
#
# use_oidc and use_azuread_auth are both required together for OIDC auth to
# the state storage account (verified 2026-07-12 against the Terraform azurerm
# backend documentation) -- one without the other does not authenticate.

terraform {
  backend "azurerm" {
    use_oidc         = true
    use_azuread_auth = true
  }
}
