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

# The migration target gets its own subject. It must not reuse the placeholder
# subject because the two workloads have different lifecycles and permissions.
variable "mcp_namespace" {
  type        = string
  description = "Kubernetes namespace for the migrated MCP server workload identity subject."
  default     = "mcp-platform"
}

variable "mcp_service_account_name" {
  type        = string
  description = "Kubernetes ServiceAccount name for the migrated MCP server workload identity subject."
  default     = "mcp-server"
}

# The Orders API shares the platform namespace but has a separate ServiceAccount
# and identity. The values form the GitOps handoff contract for issue 183.
variable "orders_namespace" {
  type        = string
  description = "Kubernetes namespace for the Orders API workload identity subject."
  default     = "mcp-platform"
}

variable "orders_service_account_name" {
  type        = string
  description = "Kubernetes ServiceAccount name for the Orders API workload identity subject."
  default     = "orders-api"
}

variable "mcp_server_application_client_id" {
  type        = string
  description = "Application (client) id of the existing MCP server Entra application. Terraform reads the app to attach the AKS ServiceAccount federation used for OBO; the account-specific identifier is supplied out of band."
}

variable "shared_observability_core_remote_state" {
  type = object({
    storage_account_name = string
    container_name       = string
    key                  = string
  })
  description = "AzureRM backend coordinates for the shared-observability-core state. This composition reads the replacement Log Analytics workspace ID through OIDC-authenticated remote state."
}

variable "shared_observability_metrics_remote_state" {
  type = object({
    storage_account_name = string
    container_name       = string
    key                  = string
  })
  description = "AzureRM backend coordinates for the shared-observability-metrics state. This composition reads the Azure Monitor workspace ID through OIDC-authenticated remote state."
}

variable "managed_prometheus_enabled" {
  type        = bool
  description = "Whether the AKS managed Prometheus add-on and collection attachment are enabled. Metrics teardown sets this to false before destroying the metrics state."
  default     = true
}

# --- Argo CD public entry point (issue 121, ADR-011) ---------------------------
# The external Istio gateway itself is enabled inside mcp-aks-host. This
# composition owns the two Azure-boundary resources that make it reachable: the
# pinned public IP and the Cloudflare DNS record. The Kubernetes objects
# (cert-manager, Gateway, VirtualService, argocd config) are applied by the
# deploy workflow, not Terraform, matching how this repo already draws the
# Terraform-stops-at-Azure line for the internal gateway.

variable "argocd_hostname" {
  type        = string
  description = "Public DNS name for the Argo CD UI/API (ADR-011 fixes this to argocd.consultwithcloud.com). Used as the Cloudflare A record name and, in the deploy workflow, as the Istio Gateway host and the Argo CD OIDC base URL."
  default     = "argocd.consultwithcloud.com"
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare zone id for consultwithcloud.com (Hari owns the domain on Cloudflare). Supplied out of band as a live-test environment variable; a zone id is not a secret but is account-specific, so it is never a literal in this repo."
}

variable "cloudflare_api_token" {
  type        = string
  description = "Cloudflare API token scoped to DNS edit on the consultwithcloud.com zone, for the cloudflare provider to manage the Argo CD A record. The repo's one permitted non-OIDC credential (AGENTS.md Hard-safety carve-out); injected from a live-test environment secret, never committed."
  sensitive   = true
}

variable "argocd_oidc_client_id" {
  type        = string
  description = "Application (client) id of the dedicated Argo CD Entra app registration (issue 121, ADR-011). Created out of band (see the runbook) and only read here to attach a federated identity credential so argocd-server can use workload identity for its OIDC token exchange instead of a client secret. A client id is a public identifier, not a secret, but is account-specific, so it is never a literal in this repo."
}

variable "argocd_namespace" {
  type        = string
  description = "Kubernetes namespace Argo CD is installed in. Used to build the federated identity credential subject; must match the namespace the deploy workflow installs the Argo CD chart into."
  default     = "argocd"
}

variable "argocd_server_service_account_name" {
  type        = string
  description = "Name of the argocd-server Kubernetes ServiceAccount. Used to build the federated identity credential subject (system:serviceaccount:<argocd_namespace>:<this>); it must match the ServiceAccount the argocd-server pod runs as, which the workload-identity pod label and annotation in the Helm values also target."
  default     = "argocd-server"
}
