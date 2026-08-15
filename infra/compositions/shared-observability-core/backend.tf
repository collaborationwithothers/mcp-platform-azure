# This state is intentionally separate from metrics. Metrics can be torn down
# and recreated without deleting the shared Log Analytics or Application
# Insights resources that S1 and S2 use.
terraform {
  backend "azurerm" {
    use_oidc         = true
    use_azuread_auth = true
  }
}
