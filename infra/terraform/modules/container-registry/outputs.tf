output "registry_id" {
  value       = module.registry.resource_id
  description = "ARM resource ID of the container registry."
}

output "registry_name" {
  value       = module.registry.name
  description = "Name of the container registry."
}

output "login_server" {
  value       = "${var.name}.azurecr.io"
  description = "Login server hostname for docker/helm login and image references. Constructed rather than read from an output because this module's login is by az acr login / role assignment, never the admin password, so no credential-bearing output exists to derive it from."
}
