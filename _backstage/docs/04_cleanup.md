# Cleanup

Cluster data is volatile until acceptance.

## Tear down

```bash
make destroy
```

~5 minutes. Removes the AKS cluster, the `MC_*` sibling RG (nodes, LB, PVCs, disks), and `denktmit-rg-acc`.

Things tofu does *not* clean up:

- DNS records ExternalDNS created in the delegated zone
- federated identity credentials added later by hand
- orphan public IPs you reserved manually

## Reset (local state)

```bash
make destroy
rm -f terraform.tfstate terraform.tfstate.backup
make init && make apply
```

## Migrating local -> remote state

Bootstrap the storage account (see [Getting started](01_getting_started.md), section "Remote state"), then:

```bash
./scripts/tofu.sh tofu init -migrate-state \
  -backend-config="resource_group_name=denktmit-rg-acc-tf-state" \
  -backend-config="storage_account_name=denktmitacctfstate" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=aks-cluster.tfstate"
```

After this, `./terraform.tfstate` is no longer used.
