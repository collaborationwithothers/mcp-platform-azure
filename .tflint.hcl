# tflint configuration for the MCP-on-Azure platform.
#
# The bundled "terraform" ruleset enforces core Terraform language and style
# checks. The "azurerm" ruleset adds Azure provider-aware linting for the
# azurerm resources that live under infra/. Both are installed by
# "tflint --init" (see .github/workflows/ci.yml). Plugin versions are pinned
# so lint results stay reproducible.
#
# Verified against tflint docs and the ruleset release feed on 2026-07-11:
# - https://github.com/terraform-linters/tflint/blob/master/docs/user-guide/config.md
# - https://github.com/terraform-linters/tflint-ruleset-azurerm/releases

config {
  # Inspect calls into local modules (default). Remote modules are not
  # inspected because CI runs terraform init with -backend=false and does
  # not download module sources.
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "azurerm" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}
