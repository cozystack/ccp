# Post-upgrade Checks

Read this when on Step 7. Run **general** checks always; add **targeted** checks based on the change-risk summary from Step 1.

## General checks (always run)

```bash
# 1. Versions match target
kubectl -n cozy-system get deployment cozystack-operator \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n cozy-system get configmap cozystack-version -o yaml 2>/dev/null

# 2. Full readiness (must be all-green)
bash <cozystack-repo>/hack/check-readiness.sh
kubectl get hr -A | grep -v True                          # empty
kubectl get packages.cozystack.io -A | grep -v True       # empty
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'   # empty

# 3. No new suspensions introduced by upgrade
for k in helmreleases kustomizations; do
  kubectl get "$k" -A -o json | jq -r ".items[] | select(.spec.suspend==true) | \"$k: \(.metadata.namespace)/\(.metadata.name)\""
done

# 4. Tenant control planes reachable, versions match
kubectl get tenantcontrolplane -A

# 5. Storage backend still healthy
alias linstor='kubectl exec -n cozy-linstor deploy/linstor-controller -ti -- linstor'
linstor node list
linstor resource list --faulty
```

## Targeted checks (map from change-risk summary)

Add one check per "heavily changed" area identified in Step 1. Representative examples:

| Changed area | Check command |
|---|---|
| MySQL → MariaDB rename | `kubectl get hr -A \| grep -E 'mysql-\|mariadb-'` — only `mariadb-*` should remain; workloads using old `mysql-*-primary.<ns>.svc` DNS need updating |
| vm-instance / vm-disk split | `kubectl get vmdisks,vminstances -A`; PVCs for old VMs retained |
| `running` → `runStrategy` on VMs | `kubectl get vminstances -A -o json \| jq '.items[] \| select(.spec.runStrategy == null)'` — empty |
| Monitoring `monitoring` → `monitoring-system` | `kubectl get hr -A \| grep monitoring` — new names, old gone or adopted |
| VPC subnets map→array | `kubectl get vpcs -A -o json \| jq '.items[].spec.subnets \| type'` — all `array` |
| MongoDB users restructure | Per MongoDB CR's spec matches new format; pods Ready |
| Tenant `isolated` flag removed | `kubectl get tenants.apps.cozystack.io -A -o json \| jq '.items[] \| select(.spec.isolated != null)'` — empty. Verify `CiliumNetworkPolicies` present and pods that need apiserver/etcd access carry labels `policy.cozystack.io/allow-to-apiserver="true"` / `allow-to-etcd="true"` |
| Cilium policy changes | `kubectl get ciliumnetworkpolicies -A \| grep allow-to-apiserver` |
| FerretDB removed | `kubectl get hr -A \| grep ferretdb` — empty (user confirmed data backed up pre-upgrade) |
| Kamaji bump | `kubectl -n cozy-kamaji get deploy kamaji -o jsonpath='{.spec.template.spec.containers[0].image}'`; `TenantControlPlane` INSTALLED VERSION matches spec |
| CRD API version change | `kubectl get crd <name> -o jsonpath='{.spec.versions[*].name}'`; existing CRs still readable |
| `values.schema.json` tightened | `kubectl get packages.cozystack.io -A` all Ready (validation failures surface here as `False`) |
| Chart rename / renamed HR prefix | Check old HR names are gone, new present; check service DNS dependencies |
| Ingress controller bump | `kubectl get pods -n cozy-ingress`; test a known ingress URL responds |

If the change-risk summary listed something not in this table, invent a check by following the template: **"what observable state proves the migration completed?"**

## Tenant cluster sanity

For every managed tenant Kubernetes cluster, verify its apiserver responds and workloads are healthy:

```bash
for tcp_ns_name in $(kubectl get tenantcontrolplane -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}'); do
  ns="${tcp_ns_name%/*}"; name="${tcp_ns_name#*/}"
  echo "=== $ns/$name ==="
  tmp_kubeconfig=$(mktemp)
  kubectl -n "$ns" get secret "${name}-admin-kubeconfig" -o jsonpath='{.data.admin\.conf}' | base64 -d > "$tmp_kubeconfig"
  KUBECONFIG="$tmp_kubeconfig" kubectl get nodes
  KUBECONFIG="$tmp_kubeconfig" kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'
  rm "$tmp_kubeconfig"
done
```

Expect: tenant nodes Ready, no non-Running pods (or only known-good ones).

## Producing the final report (Step 8)

Summarize for the user in this shape:

```text
Upgrade v1.1.1 → v1.2.0: SUCCESS

Cluster:   3/3 nodes Ready · 178 pods Running · 48 namespaces Active
HRs:       112/112 Ready
Packages:  70/70 Ready
TCPs:      2/2 Ready (versions match spec)

Targeted checks:
  ✓ MongoDB users restructure — 3/3 instances in new format
  ✓ VPC subnets array — 1/1 converted
  ✓ Kamaji v0.7→v0.8 — both TCPs reconciled successfully

Outstanding:
  (none)  -- or --  1 pod with high restart count: cozy-foo/bar (investigate if persists)
```
