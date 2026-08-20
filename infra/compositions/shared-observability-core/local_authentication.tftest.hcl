mock_provider "azurerm" {}

run "disables_application_insights_local_authentication" {
  command = plan

  variables {
    resource_group_name = "rg-shared-observability-test"
    location            = "swedencentral"
  }

  assert {
    condition     = azurerm_application_insights.this.local_authentication_enabled == false
    error_message = "Application Insights local authentication must stay disabled."
  }
}
