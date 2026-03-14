# Connect to the cluster and verify

## Kubeconfig

The cluster sets `local_account_disabled = true`, so the static cluster-admin
certificate path is closed. Azure AD is the only way in.

```bash
./scripts/tofu.sh az aks get-credentials \
  --resource-group denktmit-rg-acc --name denktmit-aks-acc --file ~/.kube/config-acc
export KUBECONFIG=~/.kube/config-acc
```

The kubeconfig contains **no secret**. Instead it has an `exec` snippet telling kubectl: *"before every call, run
`az` / `kubelogin` to get me a fresh OAuth token"*. Authentication flow on every `kubectl ...` call:

```
kubectl  --[ exec az / kubelogin ]-->  Azure AD
              "user.name@example.com wants a token for AKS"
              "Here is an OAuth token, valid ~1 hour"
kubectl  --[ HTTPS, Bearer <token> ]-->  AKS API server
              "Bearer token says user.name@example.com"
              "OK - check what marius is allowed to do (RBAC)"
```

Identity is **your** Azure AD user; tokens are short-lived and silently refreshed.

### Why no static admin cert?

The alternative, the cluster-admin X.509 certificate embedded in a kubeconfig,
is a long-lived shared secret. Anyone who copies the file is permanent
cluster-admin; revoking a single user means rotating the cluster CA. With Azure
AD every login is your real user, tokens expire in ~1 hour, and a user can be
revoked in Entra without touching the cluster. The Azure-AD path also leaves a
real audit trail in the API server logs (`user.name@example.com did it` instead
of `clusterAdmin did it`).

### Recovery if Azure AD breaks

The escape hatch is to edit `main.tf` and set `local_account_disabled = false`
on `azurerm_kubernetes_cluster.this`, re-run `tofu apply`, then pull the static
admin cert with `az aks get-credentials --admin`. This requires:

- Azure ARM access (Owner or Contributor on the cluster RG), the same role you
  need to manage the cluster anyway.
- A successful tofu apply, which itself goes through Azure ARM, not the
  Kubernetes API. So a broken AAD does not block recovery.

After fixing whatever broke, flip the line back to `true` and apply again.
Every flip is visible in the Azure activity log.

## Granting cluster access (Azure RBAC)

The cluster runs with `azure_rbac_enabled = true`, so **authorization inside
Kubernetes is driven by Azure role assignments on the cluster resource**, not
by Kubernetes `RoleBinding`s. To let someone in, give them two roles on the
cluster (or its parent RG):

| Role                                          | What it grants                               |
|-----------------------------------------------|----------------------------------------------|
| `Azure Kubernetes Service Cluster User Role`  | Lets the user call `az aks get-credentials`. |
| `Azure Kubernetes Service RBAC Cluster Admin` | Full admin inside Kubernetes. Use sparingly. |

For day-to-day work prefer the narrower roles: `Azure Kubernetes Service RBAC
Admin` (namespace-scoped), `... RBAC Writer`, `... RBAC Reader`.

```bash
./scripts/tofu.sh az role assignment create \
  --assignee <user-or-group-object-id > \
--role "Azure Kubernetes Service Cluster User Role" \
  --scope $(./scripts/tofu.sh tofu output -raw cluster_id)

./scripts/tofu.sh az role assignment create \
  --assignee <user-or-group-object-id > \
--role "Azure Kubernetes Service RBAC Cluster Admin" \
  --scope $(./scripts/tofu.sh tofu output -raw cluster_id)
```

If you'd rather pin cluster-admin to a named Entra group, set
`admin_group_object_ids = ["<group-object-id>"]` in `terraform.tfvars` and
re-apply; members of that group are then bound to the Kubernetes
`cluster-admin` ClusterRole directly, no Azure RBAC role assignment needed
for the admin level (they still need `Cluster User Role` to fetch the
kubeconfig stub).

## Sanity checks

```bash
kubectl get nodes # 3 Ready, same Kubernetes version
kubectl get pods -A # 10-20 kube-system pods, all Running
kubectl get storageclass # managed-csi (default), managed-csi-premium, azurefile-csi
kubectl get nodes -o wide # each node has an INTERNAL-IP from the auto-created subnet
```

## DNS + outbound

```bash
kubectl run debug --rm -it --image=busybox:1.36 -- sh
# inside:
nslookup kubernetes.default
wget -qO- https://www.google.com | head -n 1
```

Both should work. Pod auto-deletes on exit.

## Storage (PVC smoke test)

```yaml
# pvc-test.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-test
spec:
  accessModes: [ "ReadWriteOnce" ]
  resources:
    requests:
      storage: 1Gi
```

```bash
kubectl apply -f pvc-test.yaml
kubectl get pvc pvc-test -w # Bound within ~60s
kubectl delete pvc pvc-test
```

## Azure portal landmarks

- `denktmit-rg-acc` - the AKS resource itself
- `MC_denktmit-rg-acc_denktmit-aks-acc_germanywestcentral` - nodes, LB, VNet, public IPs, NSG
- AKS resource > Insights - built-in CPU/memory/pod metrics (Azure Monitor)

## Next

1. DNS handover from the customer - see [DNS handover](03_dns_handover.md).
2. Install ingress controller, ArgoCD, and apply workloads via GitOps. Out of scope for this terraform.
