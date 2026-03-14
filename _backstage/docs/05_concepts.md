# Concepts

Quick reference. Skim once, come back when something in the other docs is unfamiliar.

## Azure

- **Subscription** - where the bill goes. Each cluster lives in exactly one subscription.
- **Tenant** - the Azure AD directory.
- **Resource Group (RG)** - folder for Azure resources; deleting it deletes contents. Our cluster: `denktmit-rg-acc`.
- **`MC_*` RG** - AKS auto-creates `MC_<cluster-rg>_<cluster-name>_<region>` for nodes, LB, NSGs, disks. Do not touch.

## Kubernetes

- **Control plane** - API server / scheduler / etcd. Azure runs it; the Free SKU is no SLA but no charge.
- **Node** - a worker VM. We have 3.
- **Node pool** - a group of identically-sized nodes. We have one (`system`).
- **Pod / Deployment / Service / Ingress** - the usual Kubernetes primitives. Rolling updates are the Deployment default
  and the recommended rollout strategy.
- **Namespace** - logical partition for resources, quotas, RBAC.

## Networking

- **Azure CNI Overlay** - nodes get VNet IPs, pods get IPs from a separate overlay range. Avoids burning VNet space.
- **Standard LB** - L4 load balancer in `MC_*`. SNATs pod egress and fronts the ingress controller.

## Identity

- **System-assigned managed identity** - the cluster's own identity for control-plane Azure calls.
- **Kubelet identity** - separate identity used to pull container images; grant `AcrPull` on the ACR.
- **OIDC issuer** - URL the cluster publishes signed SA tokens at. Exposed as `oidc_issuer_url`.
- **Workload identity** - federates a Kubernetes service account against Azure AD via the OIDC issuer, so pods can
  act as a managed identity / SP without a stored secret.

## Storage

AKS auto-provisions StorageClasses:

- `managed-csi` (default) - standard SSD managed disk
- `managed-csi-premium` - premium SSD
- `azurefile-csi(-premium)` - Azure Files (shared FS)

Satisfies the block-storage requirement with zero additional config. `PersistentVolumeClaim` -> CSI driver provisions a
`PersistentVolume` (managed disk) on demand.

## Installed later (not in this terraform)

- **ACR** - central Azure Container Registry; grant kubelet identity `AcrPull`.
- **ArgoCD** - per-cluster GitOps agent.
- **myks** - renders Helm/kustomize/jsonnet to plain YAML for the manifest repo.
- **Ingress controller** - nginx-ingress or similar; routes hostnames to Services.
- **ExternalDNS** - writes A/CNAMEs in the delegated zone; uses the workload identity.
- **cert-manager** - issues TLS certs via Let's Encrypt DNS-01; same workload identity story.

## FAQ

**Need a VNet?** No - AKS creates one. Bring your own only for peering or private endpoints.

**Public IPs?** Allocated by the standard LB in `MC_*`. Pre-reserve a static IP if you need a stable DNS target.

**User auth to the cluster?** `az aks get-credentials` (Azure AD, revocable) is the only path; the static
cluster-admin cert is disabled (`local_account_disabled = true` in `main.tf`). Flip it back + `tofu apply` to
re-enable in an emergency, see [Connect: Recovery if Azure AD breaks](02_connect.md#recovery-if-azure-ad-breaks).

**Scaling nodes?** Bump `node_count` and re-apply. For autoscale, add the relevant fields to `default_node_pool` (not
done by default).

**Data safe?** No - volatile until acceptance.
