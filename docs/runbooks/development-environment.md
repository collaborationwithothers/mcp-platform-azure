# Runbook: development environment

Short note on local toolchain versions and where the authoritative check
lives. Recorded 2026-07-12 from the S2 gateway work (ticket 3, PR #16).

## Match local tools to the repo pins

Local Terraform and tflint must match the versions the repo pins, or local
results mislead you:

- Terraform: the modules pin `required_version >= 1.15.8, < 2.0.0`
  (infra/terraform/modules/*/versions.tf), and CI runs Terraform 1.15.8
  (.github/workflows/ci.yml). A local Terraform older than 1.15.8 refuses to
  `init`/`validate` the modules at all.
- tflint: the repo's `.tflint.hcl` uses `call_module_type` and pins the
  azurerm ruleset to 0.32.0; CI installs the latest tflint. A local tflint
  too old to understand `.tflint.hcl` cannot lint the modules.
- checkov: CI runs it over the whole `infra` directory. Running checkov
  against a module that wraps an external module (for example apim-gateway
  wrapping the AVM API Management module) needs the external module
  downloaded first, or checkov skips it with a warning.

Observed during PR #16: a local Terraform at 1.14.0 was below the 1.15.8
floor, so `validate` had to be run against a version-relaxed copy of the
modules; a local tflint at 0.43.0 was too old for `.tflint.hcl` and could
not run at all. As a result a `terraform_unused_declarations` finding was
not caught locally and surfaced only in CI.

Install the pinned versions locally and run `terraform fmt`, `terraform
validate`, `tflint`, and `checkov` before pushing.

## CI is the merge authority

The `terraform-checks` and `dotnet-build` jobs are the required status
checks (CLAUDE.md, PROJECT MECHANICS). They run the pinned toolchain, so
they are the source of truth for whether a change passes. When local tools
are older than the pins and disagree with CI, CI is correct. Watch it with
`gh pr checks <N>` and fix until green before requesting review.
