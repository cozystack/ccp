# Pre-flight Checks

Read this when on Step 2. Run every check. Any `False`, stuck, or suspended resource must be fixed before upgrading (see known-failures.md for recovery).

## Cluster sanity

```bash
echo "KUBECONFIG: $KUBECONFIG"       # confirm with user before proceeding
kubectl cluster-info
kubectl get nodes                     # all Ready, versions consistent
```

## Cozystack readiness

```bash
# From cozystack repo — checks Packages, ArtifactGenerators, ExternalArtifacts, HRs
bash <cozystack-repo>/hack/check-readiness.sh
```

If you don't have the repo locally, the equivalent inline:

```bash
kubectl get packages.cozystack.io -A                       | grep -v True
kubectl get artifactgenerators.source.extensions.fluxcd.io -A | grep -v True
kubectl get externalartifacts.source.toolkit.fluxcd.io -A  | grep -v True
kubectl get hr -A                                          | grep -v True
```

Any output = blocker.

## Suspended flux resources

Suspended HRs will NOT apply the new chart on upgrade. Un-suspending is usually required first — but ask user why each is suspended before resuming.

```bash
for k in helmreleases kustomizations gitrepositories helmrepositories ocirepositories buckets artifactgenerators; do
  kubectl get "$k" -A -o json 2>/dev/null | \
    jq -r ".items[] | select(.spec.suspend==true) | \"$k: \(.metadata.namespace)/\(.metadata.name)\""
done
```

## Workload health

```bash
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'
kubectl get tenantcontrolplane -A      # STATUS=Ready, VERSION==INSTALLED VERSION (no version drift)
kubectl get tenants.apps.cozystack.io -A   # READY=True
```

## Storage — LINSTOR

```bash
alias linstor='kubectl exec -n cozy-linstor deploy/linstor-controller -ti -- linstor'
linstor node list              # all Online
linstor storage-pool list      # no Err
linstor resource list --faulty   # empty
```

## Network — Kube-OVN (if used)

```bash
alias ovn-appctl='kubectl -n cozy-kubeovn exec deploy/ovn-central -c ovn-central -- ovn-appctl'
ovn-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound | grep -E "Role|Status"
ovn-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound | grep -E "Role|Status"
# Server count must match control-plane node count, no duplicate IPs
kubectl get node -o wide -l node-role.kubernetes.io/control-plane=
```

## etcd (if tenants use kamaji with etcd datastore)

```bash
kubectl -n tenant-root get hr etcd                  # Ready=True
kubectl -n tenant-root get sts etcd                  # 3/3 Ready
kubectl get datastores.kamaji.clastix.io             # endpoints resolve
# DNS resolution of etcd service from inside cluster:
kubectl -n tenant-root get svc etcd
```

If etcd is gone or HR is stuck, see known-failures.md #1 (stuck uninstall) and #2 (apiserver crashloop).

## Resource quota headroom

Upgrade may bump resource limits. Make sure tenant namespaces aren't already at quota.

```bash
kubectl get resourcequota -A
```

## When to stop

If any check fails, **stop** — do NOT proceed. Either fix the issue first (see known-failures.md for recovery paths), or escalate to the user with a clear summary of what's broken. Upgrading over broken state is how small problems become outages.
