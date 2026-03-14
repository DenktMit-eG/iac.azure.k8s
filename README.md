# Azure AKS Cluster Setup

Minimal OpenTofu module that bootstraps an Azure AKS cluster. Everything past the cluster, network and identity wiring
is delegated to GitOps, not this module.

## TL;DR

```bash
make image                                # build the hardened aks-iac-toolbox image
make login                                # az login --use-device-code
make subscription SUB=<target-sub-id>     # az default + writes subscription_id/tenant_id to terraform.tfvars
make plan
make apply                                # ~10-15 min
./scripts/tofu.sh az aks get-credentials --resource-group denktmit-rg-acc --name denktmit-aks-acc \
  --file ~/.kube/config-acc               # fetch kubeconfig via Azure AD (static admin cert is disabled)
```

The cluster runs with `local_account_disabled = true` and `azure_rbac_enabled = true`: there is no static
cluster-admin cert, and Kubernetes-level authorization is driven by Azure RBAC role assignments on the cluster.
After `make apply`, grant yourself (and anyone else who needs access) two roles on the cluster resource:

```bash
CLUSTER_ID=$(./scripts/tofu.sh tofu output -raw cluster_id)
./scripts/tofu.sh az role assignment create --assignee <user-or-group-id> \
  --role "Azure Kubernetes Service Cluster User Role" --scope "$CLUSTER_ID"
./scripts/tofu.sh az role assignment create --assignee <user-or-group-id> \
  --role "Azure Kubernetes Service RBAC Cluster Admin" --scope "$CLUSTER_ID"
```

For details (narrower per-namespace roles, the Entra-group shortcut via `admin_group_object_ids`, recovery if
Azure AD breaks) see [`_backstage/docs/02_connect.md`](_backstage/docs/02_connect.md).

To override any other input (`prefix`, `stage`, `node_count`, ...) append the line to `terraform.tfvars` after
`make subscription` - see `variables.tf` for the full list.

Full step-by-step is in **[`_backstage/docs/01_getting_started.md`](_backstage/docs/01_getting_started.md)**.

## What this provisions

- one resource group
- one VNet + one AKS subnet (BYO networking; the auto-created `MC_*` RG is left alone)
- one AKS cluster: Free SKU control plane, 3 x `Standard_D8s_v5` worker nodes, Azure CNI Overlay, OIDC issuer +
  workload identity enabled
- a user-assigned managed identity for the control plane (with Network Contributor on the subnet)
- optional: `AcrPull` on a central ACR, plus user-assigned identities + federated credentials for ExternalDNS and
  cert-manager

**Not provisioned here** (lives in the GitOps manifest repo): ArgoCD, ExternalDNS, cert-manager, ingress controller,
application workloads.

## Structure

```
.
├── main.tf                       # resources: RG, VNet, subnet, UAI, cluster, roles, fed-credentials
├── variables.tf                  # every input + description + defaults
├── outputs.tf                    # cluster name/id, oidc issuer, dns workload-identity ids
├── versions.tf                   # tofu >= 1.8, azurerm ~> 4.65
├── backend.azure.tf.example      # remote-state config; rename to backend.tf to opt in
├── terraform.tfvars.example      # input template; copy to terraform.tfvars (gitignored)
│
├── docker/Dockerfile             # hardened aks-iac-toolbox image (Ubuntu 24.04, tofu + az + kubectl)
├── scripts/tofu.sh               # runs the aks-iac-toolbox image with this module bind-mounted
├── scripts/update-tfvars.sh      # sets subscription_id / tenant_id in tfvars (used by `make subscription`)
├── Makefile                      # make image / plan / apply / destroy / ...
│
└── _backstage/                   # documentation (Backstage TechDocs / MkDocs)
    ├── backstage.yaml            # Backstage Component descriptor
    ├── mkdocs.yml                # MkDocs Material site config
    └── docs/
        ├── index.md
        ├── 01_getting_started.md
        ├── 02_connect.md
        ├── 03_dns_handover.md
        ├── 04_cleanup.md
        └── 05_concepts.md
```

## In-depth documentation

The full guide lives under **[`_backstage/docs/`](_backstage/docs/)** and is rendered via Backstage TechDocs / MkDocs
Material. Preview locally:

```bash
cd _backstage
docker run --rm -it -p 8000:8000 -v ${PWD}:/docs squidfunk/mkdocs-material
# open http://localhost:8000/
```

Start with [`index.md`](_backstage/docs/index.md) and follow the numbered chapters.

## License

Apache License 2.0 - see [LICENSE](LICENSE). Copyright (c) 2026 DenktMit eG. This module is a generic starting point;
fork it per customer / cluster and set your own defaults in `terraform.tfvars`.
