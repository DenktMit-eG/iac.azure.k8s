# DNS handover (ExternalDNS + cert-manager)

The customer (the team that owns the target subscription / DNS zone) hands over:

1. a delegated (sub-)domain (e.g. `acc.example.com`)
2. one identity for ExternalDNS (writes A/CNAME)
3. one identity for cert-manager (writes TXT for ACME DNS-01)

No client secret should change hands; workload identity replaces it.

Throughout this page, **we** = the cluster operator (the team running this module). **The customer** = the party that
owns the target Azure subscription and the DNS zone. Pick one of the three integration paths below depending on which
side holds the Azure role-assignment rights.

## Path A: Azure DNS + we (the operator) hold role-assignment rights

This is what `dns_zone_resource_id` is for. Set it in `terraform.tfvars`, `make apply`. OpenTofu provisions UAIs,
grants `DNS Zone Contributor`, and federates them against the cluster OIDC issuer.

Hand the resulting `client_id`s to the GitOps layer:

```bash
make output ARGS="dns_workload_identities"
```

## Path B: Azure DNS + the customer holds rights

Send the customer:

- `make output ARGS="-raw oidc_issuer_url"`
- the subjects `system:serviceaccount:external-dns:external-dns` and
  `system:serviceaccount:cert-manager:cert-manager`

The customer creates the federated credentials on their side. Then add their identity `client_id`s manually to the
Helm values.

## Path C: non-Azure DNS

Leave `dns_zone_resource_id` unset. Configure ExternalDNS / cert-manager via a plain Kubernetes Secret with provider
credentials.

---

## Pre-checks (run before installing anything)

```bash
# Zone delegated to Azure DNS?
./scripts/tofu.sh dig +trace acc.example.com NS
# Expect NS records ending in *.azure-dns.{com,net,org,info}.

# Does the customer's principal actually hold the role?
./scripts/tofu.sh az role assignment list \
  --assignee <client-id >--scope <dns-zone-resource-id >-o table
# Expect: DNS Zone Contributor (or narrower for cert-manager).
```

If either fails, escalate to the customer before going further.

## Smoke-test install (Helm direct; final state lives in the manifest repo)

ExternalDNS:

```bash
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
kubectl create namespace external-dns
helm install external-dns external-dns/external-dns \
  -n external-dns \
  --set provider=azure \
  --set azure.resourceGroup= <dns-zone-rg > \
--set azure.subscriptionId= <dns-zone-subscription > \
--set azure.tenantId= <tenant-id > \
--set azure.useWorkloadIdentityExtension=true \
  --set 'serviceAccount.annotations.azure\.workload\.identity/client-id=<client-id>' \
  --set 'podLabels.azure\.workload\.identity/use=true' \
  --set domainFilters[0]=acc.example.com
```

cert-manager:

```bash
helm repo add jetstack https://charts.jetstack.io
kubectl create namespace cert-manager
helm install cert-manager jetstack/cert-manager \
  -n cert-manager \
  --set crds.enabled=true \
  --set 'serviceAccount.annotations.azure\.workload\.identity/client-id=<client-id>' \
  --set 'podLabels.azure\.workload\.identity/use=true'
```

Then a `ClusterIssuer` pointing at Let's Encrypt DNS-01.

## Verify

Create an Ingress with a TLS hostname under the delegated zone. Within ~60s:

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -n 20
curl -v https:// <hostname>
```

In the Azure DNS portal you should see a new A record (ExternalDNS) and a short-lived TXT under `_acme-challenge.*`
(cert-manager).

## Troubleshooting

| Symptom                                                       | Likely cause                                               |
|---------------------------------------------------------------|------------------------------------------------------------|
| `failed to get token: oidc: ...` in pod logs                  | Federated credential `subject` does not match `<ns>:<sa>`. |
| `AuthorizationFailed` on `Microsoft.Network/dnsZones/A/write` | SP missing `DNS Zone Contributor`.                         |
| ExternalDNS silent, no records                                | `domainFilters` does not match the Ingress hostname.       |
| cert-manager `Pending` with `propagation check failed`        | DNS not propagated yet (wait 60s) or TXT in wrong zone.    |
| `dig` shows non-Azure NS                                      | Parent zone delegation missing.                            |
