output "resource_group_name" {
  description = "Name of the resource group holding the VNet, cluster, and identities. AKS auto-creates a sibling RG MC_<this>_<cluster>_<region> for nodes/LB/disks; that one is managed by AKS, not by tofu."
  value       = azurerm_resource_group.this.name
}

output "cluster_name" {
  description = "AKS cluster name. Pass to `az aks get-credentials --name`."
  value       = azurerm_kubernetes_cluster.this.name
}

output "cluster_id" {
  description = "Full Azure resource id of the AKS cluster. Useful as a target for role assignments or for `terraform_remote_state` consumers."
  value       = azurerm_kubernetes_cluster.this.id
}

output "cluster_fqdn" {
  description = "Public FQDN of the Kubernetes API server, e.g. denktmit-acc-<hash>.germanywestcentral.azmk8s.io."
  value       = azurerm_kubernetes_cluster.this.fqdn
}

output "selected_kubernetes_version" {
  description = "Patch version resolved from kubernetes_version_prefix at plan time (the version Azure currently offers for that minor in `location`)."
  value       = data.azurerm_kubernetes_service_versions.selected.latest_version
}

output "current_kubernetes_version" {
  description = "Version actually running on the cluster control plane. May lag `selected_kubernetes_version` between a plan that picks a newer patch and the rolling upgrade completing."
  value       = azurerm_kubernetes_cluster.this.current_kubernetes_version
}

output "node_pool" {
  description = "Sizing snapshot of the default (system) node pool: count and VM SKU. Useful when consumed by another tofu config as `terraform_remote_state` (e.g. capacity planning)."
  value = {
    count   = var.node_count
    vm_size = var.node_vm_size
  }
}

output "oidc_issuer_url" {
  description = "URL where the cluster publishes signed ServiceAccount tokens. Hand this to the customer so they (or you) can federate the ExternalDNS / cert-manager identities against it. Required input for `azurerm_federated_identity_credential.issuer`."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  description = "Object id of the kubelet's managed identity (the one used to pull container images). When acr_name is set, AcrPull on the central ACR is granted to this id automatically; otherwise grant it by hand with `az role assignment create --assignee <this> --role AcrPull --scope <acr-id>`."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "dns_workload_identities" {
  description = "Per-controller workload-identity details to drop into the ExternalDNS and cert-manager Helm values: client_id, principal_id, and the federated credential subject. Empty map when dns_zone_resource_id is unset."
  value = {
    for key, identity in azurerm_user_assigned_identity.dns : key => {
      client_id    = identity.client_id
      principal_id = identity.principal_id
      subject      = azurerm_federated_identity_credential.dns[key].subject
    }
  }
}

# `kube_config` (the raw cluster-admin kubeconfig) is intentionally NOT exposed
# as an output. The cluster sets `local_account_disabled = true`, so the cert
# would not authenticate anyway; keeping it out of outputs also keeps the
# admin client cert + private key out of `terraform.tfstate`. Use
# `az aks get-credentials` (Azure AD) for every login.
