# Wrapper over Azure/avm-res-containerregistry-registry/azurerm 0.8.0. The
# AVM module is the swappable implementation; this wrapper is the stable
# thick interface the private-backend composition depends on. See README.md
# for the issue-start AVM capability check this main.tf depends on, and
# COMPATIBILITY.md for the pin.

locals {
  # role_assignments is a single map keyed by a stable slug so a later PR can
  # add a role without restructuring this merge: pull grants keyed
  # "pull-<idx>", push grants keyed "push-<idx>". Both role names are
  # well-known built-in role NAMES accepted directly by this module's
  # role_definition_id_or_name (no GUID lookup needed, matching how this
  # module's role_assignments passthrough is documented).
  role_assignments = merge(
    { for idx, principal_id in var.acr_pull_principal_ids : "pull-${idx}" => {
      role_definition_id_or_name = "AcrPull"
      principal_id               = principal_id
    } },
    { for idx, principal_id in var.acr_push_principal_ids : "push-${idx}" => {
      role_definition_id_or_name = "AcrPush"
      principal_id               = principal_id
    } },
  )
}

module "registry" {
  source  = "Azure/avm-res-containerregistry-registry/azurerm"
  version = "0.8.0"

  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  enable_telemetry    = false
  tags                = var.tags

  sku = var.sku

  # Admin account disabled (Microsoft Learn discourages it directly; see
  # COMPATIBILITY.md): every consumer of this registry authenticates by role
  # assignment (AcrPull/AcrPush below), never a shared admin credential. This
  # is the module's own default; set explicitly so the intent is not
  # implicit.
  admin_enabled = false

  # Zone redundancy needs Premium; this module's own default (true) would
  # conflict with sku = "Standard" above, so it is turned off explicitly
  # rather than left at the module default.
  zone_redundancy_enabled = false

  role_assignments = local.role_assignments
}
