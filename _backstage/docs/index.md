# Azure AKS Cluster Setup

Minimal OpenTofu module that bootstraps an Azure AKS cluster.

## What this builds

A single AKS cluster with:

- managed control plane (Free tier)
- 3 worker nodes, 8 vCPU / 32 GiB RAM each (`Standard_D8s_v5`)
- explicit VNet + subnet, Azure CNI Overlay (pod IPs do not consume VNet space)
- Azure Managed Disks via the built-in CSI driver
- standard Load Balancer (public)
- OIDC issuer + workload identity enabled, ready for the DNS handover
- optional: AcrPull on a central ACR, workload identities for ExternalDNS + cert-manager

What is **not** in this module (deployed via GitOps later): ArgoCD, ExternalDNS, cert-manager, ingress controller,
application workloads.

## Read in this order

1. [Getting started](01_getting_started.md) - the literal checklist from `git clone` to a running cluster
2. [Connect](02_connect.md) - point `kubectl` at the new cluster and verify it works
3. [DNS handover](03_dns_handover.md) - what to do when the customer hands you the ExternalDNS / cert-manager identities
4. [Cleanup](04_cleanup.md) - tear it back down (cluster data should be treated as volatile until final acceptance)
5. [Concepts](05_concepts.md) - reference glossary; come back when you hit unfamiliar jargon

## Mental model

```
          you (host)
              |
              | docker, scripts/tofu.sh
              v
   +----------------------------+
   |  Azure subscription        |
   |                            |
   |  RG: denktmit-rg-acc       |
   |    +---------------+       |
   |    | AKS control   |       |  <- Azure runs this. You never SSH in.
   |    | plane (Free)  |       |
   |    +-------+-------+       |
   |            |               |
   |    +-------v-------+       |
   |    | 3 worker VMs  |       |  <- your pods run here,
   |    | D8s_v5        |       |     in our VNet's AKS subnet
   |    +---------------+       |
   |                            |
   |  RG: MC_denktmit-rg-acc_...|  <- AKS auto-creates this for LB, NSG, disks
   +----------------------------+
```

Unfamiliar term? See the [Concepts](05_concepts.md) page.

## Previewing this documentation locally

This site is rendered with [MkDocs Material](https://squidfunk.github.io/mkdocs-material/) inside the Backstage
TechDocs flow. Preview from the `_backstage` directory:

```bash
cd _backstage
docker run --rm -it -p 8000:8000 -v ${PWD}:/docs squidfunk/mkdocs-material
```

Open <http://localhost:8000/>; the preview live-reloads as you edit.
