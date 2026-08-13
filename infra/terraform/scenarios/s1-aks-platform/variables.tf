# S1 AKS platform composition (epic 108 child (b), issue 110): instantiates
# private-network + mcp-aks-host + container-registry, and the workload
# identity the placeholder workload uses. Ships no application code; the
# placeholder workload is the proof this platform works. See
# docs/specs/v1-tracer-bullet.md, Delivery shape.

variable "resource_group_name" {
  type        = string
  description = "Name of the (out-of-band) resource group this composition deploys into."
}

variable "location" {
  type        = string
  description = "Azure region for every resource this composition creates."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource this composition creates."
  default     = {}
}

variable "name_prefix" {
  type        = string
  description = "Prefix applied to the virtual network, subnets, and network security groups (passed to private-network)."
  default     = "mcp-aks-platform"
}

variable "cluster_name" {
  type        = string
  description = "Name of the AKS cluster."
}

# Container registry names are GLOBAL (leftmost label of <name>.azurecr.io),
# same constraint api-center-registry and apim-gateway already document for
# their own global names; the caller is responsible for uniqueness (see
# those modules' READMEs for the ephemeral-vs-stable naming pattern this
# repo uses elsewhere).
variable "registry_name" {
  type        = string
  description = "Name of the container registry (globally unique, alphanumeric only)."
}

# See private-network/variables.tf for why this has no default and is never
# a literal elsewhere in this repo.
variable "runner_vnet_id" {
  type        = string
  description = "ARM resource ID of the existing GitHub Actions VNet runner network to peer this spoke to. Supplied out of band; see private-network/README.md."
}

variable "ingress_gateway_private_ip" {
  type        = string
  description = "Predetermined private IPv4 address for the Istio internal ingress gateway's load balancer (private-network validates it falls inside the dedicated ingress subnet)."
}

# Populated by the deploy-and-bootstrap workflow from the live OIDC
# principal's object id (the same `az ad sp show --id ... --query id` lookup
# ephemeral-env.yml already does for data_reader_principal_ids elsewhere in
# this repo), not hardcoded: the CI identity that pushes the placeholder
# image needs AcrPush on the registry this composition creates. Empty list
# (default) => no grant, matching every other *_principal_ids variable in
# this repo.
variable "acr_push_principal_ids" {
  type        = list(string)
  description = "Object ids of Entra principals (the CI identity that builds and pushes the placeholder image) to grant AcrPush on the registry."
  default     = []
}

# Subject system:serviceaccount:<placeholder_namespace>:<placeholder_service_account_name>,
# audience api://AzureADTokenExchange (issue 110 section 2, "Workload
# identity uses a user-assigned managed identity"). The placeholder
# workload's own Kubernetes manifests (in the separate
# mcp-platform-kubernetes-manifests repo, applied by Argo CD) must use these
# same two names, or the federated credential subject will not match.
variable "placeholder_namespace" {
  type        = string
  description = "Kubernetes namespace the placeholder workload's ServiceAccount lives in."
  default     = "mcp-platform-demo"
}

variable "placeholder_service_account_name" {
  type        = string
  description = "Name of the placeholder workload's Kubernetes ServiceAccount."
  default     = "mcp-platform-placeholder"
}
