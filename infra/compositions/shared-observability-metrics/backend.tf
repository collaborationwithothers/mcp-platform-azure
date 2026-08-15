# Metrics has an independent lifecycle. A metrics teardown must leave the core
# Log Analytics and Application Insights resources in place.
terraform {
  backend "azurerm" {
    use_oidc         = true
    use_azuread_auth = true
  }
}
