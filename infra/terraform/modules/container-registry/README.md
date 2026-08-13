# container-registry

Wraps [`Azure/avm-res-containerregistry-registry/azurerm` 0.8.0](https://registry.terraform.io/modules/Azure/avm-res-containerregistry-registry/azurerm/0.8.0)
to provision the Azure Container Registry the placeholder workload's image
pipeline pushes to and the AKS cluster pulls from (issue 110, task 4). Admin
account disabled; every consumer authenticates by role assignment.

No deployment happens in this ticket: the module is proven by `terraform
fmt`, `init -backend=false`, `validate`, and `checkov` only.

## Issue-start AVM capability check (2026-08-13)

Verified directly against the module's published documentation (Terraform
MCP registry tools, module id
`Azure/avm-res-containerregistry-registry/azurerm/0.8.0`):

- `admin_enabled` (bool) defaults to `false` already; this module sets it
  explicitly so the intent is not implicit, per Microsoft Learn's direct
  discouragement of the admin account (COMPATIBILITY.md).
- `role_assignments` (map) is a first-class input, accepting a built-in role
  NAME directly in `role_definition_id_or_name` (no GUID lookup needed). This
  module builds that map from `acr_pull_principal_ids` and
  `acr_push_principal_ids`.
- `sku` defaults to `Premium`; this module overrides to `Standard` (see
  variables.tf) because none of Premium's differentiators (geo-replication,
  private endpoints, customer-managed keys) are in scope for the placeholder
  workload. `zone_redundancy_enabled` (module default `true`, Premium-only)
  is set `false` to match.

No fallback needed: every capability this module uses is directly expressed
by the AVM module's inputs.

## What this module does not do

- No private endpoint. The private-network path this epic adds is scoped to
  APIM-to-AKS-backend only (AGENTS.md GOVERNANCE, epic 108 child (b)
  exception); the registry is reached over its public endpoint, gated by
  role assignment, not network isolation.
- No image itself. The placeholder image and its build/push pipeline are
  issue 110 task 9's job, not this module's.
