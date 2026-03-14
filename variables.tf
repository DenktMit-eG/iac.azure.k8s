variable "subscription_id" {
  type        = string
  default     = null
  description = "Azure subscription id the cluster lives in. null = fall back to ARM_SUBSCRIPTION_ID env var or the active `az` context."
}

variable "tenant_id" {
  type        = string
  default     = null
  description = "Azure AD tenant id. null = use the tenant from the active Azure context."
}

variable "location" {
  type        = string
  default     = "germanywestcentral"
  description = "Azure region for the resource group, VNet, and AKS cluster. Pick a region close to consumers; latency matters for the API server."
}

variable "prefix" {
  type        = string
  default     = "denktmit"
  description = "Short prefix used in resource names. Joined with `stage` to produce e.g. <prefix>-rg-<stage>, <prefix>-aks-<stage>."
}

variable "stage" {
  type        = string
  default     = "acc"
  description = "Stage / cluster identifier joined into resource names alongside `prefix`."
}

variable "kubernetes_version_prefix" {
  type        = string
  default     = "1.35"
  description = "AKS Kubernetes minor version. Resolved at plan time to the latest patch Azure offers in `location`. Bump when Azure drops the current minor."
}

variable "node_count" {
  type        = number
  default     = 3
  description = "Number of worker nodes in the default system pool."

  validation {
    condition     = var.node_count >= 1
    error_message = "node_count must be at least 1."
  }
}

variable "node_vm_size" {
  type        = string
  default     = "Standard_D8s_v5"
  description = "VM SKU for worker nodes. 8 vCPU / 32 GiB RAM each (Standard_D8s_v5). Changing this replaces the node pool."
}

variable "tags" {
  type = map(string)
  default = {
    Owner   = "DenktMit eG"
    Project = "Azure AKS Cluster Setup"
    Source  = "opentofu"
  }
  description = "Azure resource tags propagated to every taggable resource. Used for cost reports and ownership filtering in the portal."
}

# --- Network ----------------------------------------------------------------
# Bring-your-own VNet + subnet so AKS' opaque MC_* defaults do not leak into
# decisions later (peering, private endpoints, NSG audits).
#
# CIDRs deliberately sit in the 10.15x range to avoid the heavily collided
# 10.0/10.42/10.43/10.244/192.168 blocks (Cilium, k3s, flannel, Calico, AWS
# VPC, home routers). VNet / pod / service CIDRs must be non-overlapping
# with each other and with anything the customer will peer into the VNet later.

variable "vnet_address_space" {
  type        = list(string)
  default     = ["10.151.0.0/16"]
  description = "Address space of the cluster VNet. /16 leaves room for future subnets (jumpbox, private endpoints, peered services)."
}

variable "aks_subnet_prefixes" {
  type        = list(string)
  default     = ["10.151.0.0/22"]
  description = "Subnet AKS nodes get IPs from. With Azure CNI Overlay each node uses one subnet IP; /22 supports ~1000 nodes (plenty)."
}

variable "pod_cidr" {
  type        = string
  default     = "10.153.0.0/16"
  description = "Overlay range pod IPs come from. Virtual: does not consume VNet space. Must not overlap VNet or service CIDR."
}

variable "service_cidr" {
  type        = string
  default     = "10.152.0.0/16"
  description = "Virtual range Kubernetes Service ClusterIPs come from. Must not overlap VNet or pod CIDR."
}

variable "dns_service_ip" {
  type        = string
  default     = "10.152.0.10"
  description = "Cluster-internal CoreDNS Service IP. Must sit inside `service_cidr`; AKS enforces this at apply time."
}

# --- Optional integrations --------------------------------------------------

variable "acr_name" {
  type        = string
  default     = null
  description = "Name of an existing central Azure Container Registry. When both `acr_name` and `acr_resource_group_name` are set, the kubelet identity is granted AcrPull so pods can pull images without imagePullSecrets. Leave null to skip."
}

variable "acr_resource_group_name" {
  type        = string
  default     = null
  description = "Resource group of the ACR named in `acr_name`. Both must be set together; the data lookup needs the RG."
}

variable "admin_group_object_ids" {
  type        = list(string)
  default     = []
  description = "Optional Microsoft Entra (Azure AD) group object ids bound to the Kubernetes `cluster-admin` ClusterRole. AAD integration itself is always on (required by `local_account_disabled = true`); leaving this empty means access is managed purely via Azure RBAC role assignments on the cluster (`Azure Kubernetes Service RBAC Cluster Admin` etc.) instead of via a hard-coded admin group. Add an Entra group id here only if you want a Kubernetes-side shortcut to cluster-admin."
}

variable "dns_zone_resource_id" {
  type        = string
  default     = null
  description = "Full resource id of an Azure DNS zone delegated to this cluster. When set, tofu creates user-assigned managed identities for ExternalDNS and cert-manager, grants them DNS Zone Contributor, and federates them against the cluster's OIDC issuer. Leave null for non-Azure DNS providers (Cloudflare, Route53, ...) and supply credentials via a Kubernetes Secret instead."
}

variable "external_dns_namespace" {
  type        = string
  default     = "external-dns"
  description = "Kubernetes namespace ExternalDNS will be installed into. Forms part of the federated credential subject (system:serviceaccount:<ns>:<sa>); must match the eventual Helm install."
}

variable "external_dns_service_account" {
  type        = string
  default     = "external-dns"
  description = "Kubernetes ServiceAccount name ExternalDNS will run as. Default matches the upstream Helm chart when installed with release name `external-dns`."
}

variable "cert_manager_namespace" {
  type        = string
  default     = "cert-manager"
  description = "Kubernetes namespace cert-manager will be installed into. Matches the Jetstack chart's documented install."
}

variable "cert_manager_service_account" {
  type        = string
  default     = "cert-manager"
  description = "Kubernetes ServiceAccount name cert-manager will run as. Matches the Jetstack chart default."
}
