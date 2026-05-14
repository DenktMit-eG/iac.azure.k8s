# Getting started

Literal checklist from `git clone` to a running cluster. Tick top-to-bottom.

## 0. Install Docker or Podman on the host

```bash
docker --version || podman --version
```

That is the only prerequisite. OpenTofu, Azure CLI, kubectl all live in the image we build next.

## 1. Build the aks-iac-toolbox image

From the module root:

```bash
make image
```

Builds `aks-iac-toolbox:local` from `docker/Dockerfile`. Runs as a non-root user matching your host UID/GID.

## 2. Log into Azure (device-code, no browser)

```bash
make login
```

Wraps `az login --use-device-code` inside the container. Session persists in `~/.azure` on the host.

## 3. Pick the subscription (writes `terraform.tfvars`)

```bash
make subscription SUB= <target-subscription-id>
```

This single target does two things:

1. Runs `az account set --subscription <SUB>` inside the container so any ad-hoc `az ...` you run next defaults to
   that subscription.
2. Sets `subscription_id` and `tenant_id` in `terraform.tfvars`. If the file doesn't exist yet, it's copied from
   `terraform.tfvars.example` first (so you inherit the commented overrides documented there). The two lines are
   then set/replaced in place; every other line in the file is preserved.

If `terraform.tfvars` **already exists**, the target prints the current subscription/tenant lines, shows what
it's about to set, and asks before touching them:

```
==> terraform.tfvars exists. Current subscription/tenant lines:
subscription_id = "11111111-..."
tenant_id       = "..."

==> Will set in place (every other line preserved):
  subscription_id = "22222222-..."
  tenant_id       = "..."
Overwrite subscription_id and tenant_id in place? [y/N]
```

Hitting `y` rewrites just those two lines; anything else aborts. Use `make subscription SUB=<id> FORCE=1` to skip the
prompt (handy in scripts; required when stdin isn't a tty). Hand-added overrides (`prefix`, `node_count`, `tags`, …)
are untouched.

Don't have the subscription UUID handy? After `make login`, list everything your user can see:

```bash
./scripts/tofu.sh az account list -o table
```

The `SubscriptionId` column is what you paste into `SUB=`.

### Optional overrides

Append any other `variables.tf` knob to `terraform.tfvars` if you want it set explicitly:

- `prefix`, `stage` - resource-name prefix and stage. Defaults give RG `denktmit-rg-acc`, cluster `denktmit-aks-acc`
- `kubernetes_version_prefix` - `"1.35"` by default; bump only if Azure has dropped it in your region
- `node_count`, `node_vm_size` - defaults: 3 nodes, 8 vCPU + 32 GiB per node

Leave `acr_*` and `dns_zone_resource_id` until the customer hands those over (steps 9-10). `admin_group_object_ids`
is an optional Kubernetes-side shortcut to cluster-admin (any listed Entra group is bound to the `cluster-admin`
ClusterRole); leave it empty if you prefer to manage access via Azure RBAC role assignments only (see step 7).

### Who picks the subscription at apply time?

Layered priority in the `azurerm` provider:

1. `subscription_id` in `terraform.tfvars` (the line we just wrote)
2. `ARM_SUBSCRIPTION_ID` environment variable
3. Active `az` CLI subscription (changed by step 1 above too)

So even if `az account set` somehow drifts later, the `subscription_id` in tfvars keeps `tofu plan` / `tofu apply`
deterministic.

## 4. Init

```bash
make init
```

Local state by default (`./terraform.tfstate`, gitignored). For remote state, see "Remote state" at the bottom.

## 5. Plan

```bash
make plan
```

Expected:

```
Plan: 6 to add, 0 to change, 0 to destroy.
  + azurerm_resource_group.this
  + azurerm_virtual_network.this
  + azurerm_subnet.aks
  + azurerm_user_assigned_identity.aks
  + azurerm_role_assignment.aks_network_contributor
  + azurerm_kubernetes_cluster.this
```

(One extra role assignment if `acr_name` is set; three more resources per DNS controller if `dns_zone_resource_id`
is set.)

## 6. Apply

```bash
make apply
```

~10-15 minutes. AKS provisioning dominates.

## 7. Fetch credentials and verify

The cluster runs with `local_account_disabled = true`, so the only login path
is Azure AD. `make kubeconfig` reads `resource_group_name` and `cluster_name`
from tofu outputs and runs `az aks get-credentials` inside the toolbox; the
file lands at `~/.kube/config-<cluster_name>` on the host (via the bind-mounted
`~/.kube`). The kubeconfig itself has no embedded secret: it carries an `exec`
snippet that asks `az` / `kubelogin` for a fresh OAuth token on every call.

```bash
make kubeconfig
export KUBECONFIG="$HOME/.kube/config-denktmit-aks-acc"   # path printed by make kubeconfig
kubectl get nodes                                          # expect 3 Ready
kubectl get storageclass                                   # expect managed-csi (default)
```

See [Connect](02_connect.md) for the auth flow in detail and how to recover
if AAD breaks.

## 8. Ask the customer for DNS handover details

Expect a delegated (sub-)domain plus identities for ExternalDNS + cert-manager. Ask whether the zone is **Azure DNS**
or a third party (Cloudflare, Route53, ...).

## 9. Wire DNS (one of three paths)

- **Azure DNS, we (the operator) hold role-assignment rights** -> set `dns_zone_resource_id` in `terraform.tfvars`,
  then `make apply` and `make output ARGS="dns_workload_identities"`.
- **Azure DNS, the customer holds rights** -> send them `make output ARGS="-raw oidc_issuer_url"` plus the SA subjects
  (`system:serviceaccount:external-dns:external-dns`, `system:serviceaccount:cert-manager:cert-manager`).
- **Non-Azure DNS** -> leave `dns_zone_resource_id` unset. Use a Kubernetes Secret with provider credentials in the
  Helm values.

Details: [DNS handover](03_dns_handover.md).

## 10. Configure ACR pull (once the customer names the registry)

```hcl
acr_name                = "<your-central-acr-name>"
acr_resource_group_name = "<your-acr-resource-group>"
```

`make apply` adds the `AcrPull` role assignment to the kubelet identity.

## 11. Hand off to GitOps (everything else lives there, not here)

This module stops at: cluster + network + optional ACR pull + optional DNS workload identities.

The following are deployed via ArgoCD + myks in the manifest repo, *not* this terraform:

- ingress controller
- ArgoCD itself
- ExternalDNS + cert-manager (with the workload-identity values from step 9)
- application workloads

---

## Remote state (optional, for shared use across operators)

By default this module uses local state. To switch:

1. Bootstrap the storage account once:

   ```bash
   ./scripts/tofu.sh az group create -n denktmit-rg-acc-tf-state -l germanywestcentral
   ./scripts/tofu.sh az storage account create \
     -g denktmit-rg-acc-tf-state -n denktmitacctfstate -l germanywestcentral \
     --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2
   ./scripts/tofu.sh az storage container create \
     --account-name denktmitacctfstate -n tfstate --auth-mode login
   ```

2. Enable the backend:

   ```bash
   mv backend.azure.tf.example backend.tf
   ```

3. Migrate state:

   ```bash
   ./scripts/tofu.sh tofu init -migrate-state \
     -backend-config="resource_group_name=denktmit-rg-acc-tf-state" \
     -backend-config="storage_account_name=denktmitacctfstate" \
     -backend-config="container_name=tfstate" \
     -backend-config="key=aks-cluster.tfstate"
   ```

After migration the local `terraform.tfstate*` files can be deleted; the state lives in the blob from then on.

## Tear-down

Cluster data is volatile until acceptance:

```bash
make destroy
rm -f terraform.tfstate* # local state only
```

ExternalDNS-created records do *not* garbage-collect on cluster destroy; see [Cleanup](04_cleanup.md).
