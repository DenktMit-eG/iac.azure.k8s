# Computed names + toggles. Single source of truth for resource naming and
# whether the optional ACR-pull / DNS-workload-identity blocks fire.
locals {
  # Resource names derived from prefix/stage. Change either variable and
  # every resource follows.
  rg_name      = "${var.prefix}-rg-${var.stage}"  # e.g. denktmit-rg-acc
  cluster_name = "${var.prefix}-aks-${var.stage}" # e.g. denktmit-aks-acc
  dns_prefix   = "${var.prefix}-${var.stage}"     # used in the AKS API server's FQDN

  # Feature toggles. Each requires both halves of its config so partial
  # state can never produce a half-broken resource.
  acr_enabled = var.acr_name != null && var.acr_resource_group_name != null
  dns_enabled = var.dns_zone_resource_id != null

  # Map iterated by the three DNS-related resources below. Using a map keys
  # each resource by controller name so addresses read as
  # azurerm_user_assigned_identity.dns["external_dns"].
  dns_identities = local.dns_enabled ? {
    external_dns = {
      namespace       = var.external_dns_namespace
      service_account = var.external_dns_service_account
    }
    cert_manager = {
      namespace       = var.cert_manager_namespace
      service_account = var.cert_manager_service_account
    }
  } : {}
}

# Resolves "1.35" to the latest patch Azure offers in `location`. Avoids
# pinning a static patch that goes stale on every Azure CVE roll-up.
data "azurerm_kubernetes_service_versions" "selected" {
  location       = var.location
  version_prefix = var.kubernetes_version_prefix
}

# Look up the central ACR by name+RG so we can grant AcrPull below. Only
# evaluated when both acr_* variables are set.
data "azurerm_container_registry" "central" {
  count = local.acr_enabled ? 1 : 0

  name                = var.acr_name
  resource_group_name = var.acr_resource_group_name
}

# Top-level resource group. Holds the VNet, the cluster, and managed
# identities. AKS auto-creates a SECOND "node RG" named
# MC_<this>_<cluster>_<region> for nodes/LB/disks; leave it alone.
resource "azurerm_resource_group" "this" {
  name     = local.rg_name
  location = var.location
  tags     = var.tags
}

# Bring-your-own VNet so future peering / private endpoints / NSG audits
# don't depend on AKS' opaque MC_* default networking.
resource "azurerm_virtual_network" "this" {
  name                = "${local.cluster_name}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = var.vnet_address_space
  tags                = var.tags
}

# Subnet that holds the AKS node NICs. With Azure CNI Overlay each node
# uses ONE IP here; pods get IPs from the overlay range (var.pod_cidr)
# instead of the subnet, so this can stay small.
resource "azurerm_subnet" "aks" {
  name                 = "${local.cluster_name}-snet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = var.aks_subnet_prefixes
}

# User-assigned managed identity for the AKS control plane. UAI is the
# right choice when bringing your own subnet: we can pre-grant Network
# Contributor on the subnet (next resource) without needing Owner on the
# whole subscription, which SystemAssigned would otherwise demand for the
# implicit grant.
resource "azurerm_user_assigned_identity" "aks" {
  name                = "${local.cluster_name}-id"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

# Pre-grant the cluster identity the right to manage the subnet (attach
# NICs, configure NSGs). AKS provisioning blocks without this when using a
# pre-existing subnet.
resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                = azurerm_subnet.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# The cluster itself. Azure runs the control plane (API server, scheduler,
# etcd, controller-manager) on the Free SKU; no SLA but no charge either.
# We bring: networking, identity, the node pool spec, and the workload-
# identity toggles needed for the DNS handover later.
resource "azurerm_kubernetes_cluster" "this" {
  name                = local.cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  # Becomes part of the API server FQDN: <dns_prefix>-<hash>.<region>.azmk8s.io.
  dns_prefix = local.dns_prefix

  # Latest patch in the requested minor, resolved by the data source above.
  kubernetes_version = data.azurerm_kubernetes_service_versions.selected.latest_version

  # Free = no uptime SLA, no charge. Switch to "Standard" if/when you need
  # the SLA.
  sku_tier = "Free"

  # Disable the static cluster-admin certificate path. Without this, anyone
  # with `Microsoft.ContainerService/managedClusters/listClusterAdminCredential/action`
  # on the subscription can pull a long-lived admin cert and bypass Azure AD
  # entirely (no audit trail, no per-user revocation). With it disabled the
  # API server rejects that cert; every login has to go through Azure AD via
  # `az aks get-credentials`. Recovery (if AAD ever breaks): flip to false,
  # `tofu apply`, get the cert, fix AAD, flip back. Requires Owner/Contributor
  # on the cluster, and the property change is audit-visible in the activity log.
  local_account_disabled = true

  # Required for Azure Workload Identity (federating Kubernetes service accounts
  # against an Azure AD identity). Used by the DNS handover below and by
  # any future workload that needs Azure API access without a stored secret.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # The system pool runs cluster add-ons (CoreDNS, kube-proxy, metrics-
  # server, CSI drivers) and on a small cluster also your workloads. Add
  # more user pools later for workload isolation.
  default_node_pool {
    name           = "system"
    node_count     = var.node_count
    vm_size        = var.node_vm_size
    vnet_subnet_id = azurerm_subnet.aks.id

    # Roll one extra node during upgrades. Without surge, Azure tears down
    # a node before replacing it, briefly dropping a third of capacity.
    upgrade_settings {
      max_surge = "10%"
    }
  }

  # Use the UAI declared above. The kubelet (separate identity AKS creates
  # automatically) is referenced later for AcrPull.
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  # Azure AD integration is always on (required by `local_account_disabled =
  # true`). `azure_rbac_enabled = true` puts authorization on Azure RBAC role
  # assignments, i.e. who-can-do-what in the cluster is controlled by Azure
  # roles on the cluster resource (e.g. "Azure Kubernetes Service RBAC Cluster
  # Admin"), not by Kubernetes RoleBindings. `admin_group_object_ids` is an
  # optional shortcut: any Entra group listed here is bound to the built-in
  # `cluster-admin` Kubernetes ClusterRole. Empty list (the default) is fine;
  # access is then managed entirely via Azure role assignments.
  azure_active_directory_role_based_access_control {
    tenant_id              = var.tenant_id
    admin_group_object_ids = var.admin_group_object_ids
    azure_rbac_enabled     = true
  }

  # Azure CNI Overlay: nodes get IPs from the VNet subnet, pods get IPs
  # from a separate overlay range that does not consume VNet space.
  # outbound_type=loadBalancer SNATs pod egress through the standard LB's
  # public IP; simplest model for an internet-facing cluster.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
  }

  # Only the disk CSI driver is enabled; Azure Files and Blob CSI are off
  # to shrink the attack surface. Re-enable if a workload demands one.
  storage_profile {
    disk_driver_enabled         = true
    file_driver_enabled         = false
    blob_driver_enabled         = false
    snapshot_controller_enabled = true
  }

  tags = var.tags

  # Subnet role must be in place before AKS tries to attach node NICs to
  # it, otherwise provisioning races and fails.
  depends_on = [azurerm_role_assignment.aks_network_contributor]
}

# Grant the kubelet (separate AKS-managed identity used for image pulls)
# the AcrPull role on the central ACR so pods can pull without
# imagePullSecrets. Skipped when the acr_* variables are null.
resource "azurerm_role_assignment" "acr_pull" {
  count = local.acr_enabled ? 1 : 0

  scope                = data.azurerm_container_registry.central[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

# --- DNS workload identity (optional, fires when dns_zone_resource_id set)
# One trio of resources per controller (ExternalDNS, cert-manager): a UAI,
# a role assignment on the zone, and a federated credential trusting the
# cluster OIDC issuer for a specific Kubernetes ServiceAccount. The federated
# credential's `subject` must match the Kubernetes SA exactly:
# system:serviceaccount:<ns>:<sa>.

# One user-assigned managed identity per controller. Named with a slug
# derived from the map key (external-dns, cert-manager).
resource "azurerm_user_assigned_identity" "dns" {
  for_each = local.dns_identities

  name                = "${local.cluster_name}-${replace(each.key, "_", "-")}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

# Each controller's identity gets DNS Zone Contributor on the zone so it
# can write A/CNAME/TXT records.
resource "azurerm_role_assignment" "dns_zone_contributor" {
  for_each = local.dns_identities

  scope                = var.dns_zone_resource_id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.dns[each.key].principal_id
}

# Federated credential: tells Azure AD to accept tokens minted by this
# cluster's OIDC issuer for the listed Kubernetes SA as proof of identity. The
# field was named `parent_id` before azurerm 4.65; renamed to
# `user_assigned_identity_id` since.
resource "azurerm_federated_identity_credential" "dns" {
  for_each = local.dns_identities

  name                      = each.key
  resource_group_name       = azurerm_resource_group.this.name
  user_assigned_identity_id = azurerm_user_assigned_identity.dns[each.key].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
}
