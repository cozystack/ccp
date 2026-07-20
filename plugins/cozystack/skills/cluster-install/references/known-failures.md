# Known failure modes

Each entry: symptom → likely cause → recovery. Reference this when an HR is stuck or post-install verification fails. Don't guess — match the exact symptom string before applying a fix.

## Dashboard / Keycloak / flux-plunger stuck in OIDC chicken-and-egg

**Symptom**

After Platform Package apply, most HRs go Ready, but three (or a similar trio) stall indefinitely:

```text
NAMESPACE        NAME            READY  STATUS   MESSAGE
cozy-dashboard   dashboard       Unknown          Running 'install' action with timeout of 10m0s
                                                  then InstallFailed: context deadline exceeded
                                                  then retry, forever
cozy-keycloak    keycloak        similar
cozy-fluxcd      flux-plunger    False           dependency 'cozy-dashboard/dashboard' is not ready
```

Pod-level look:

```bash
kubectl --context $CTX -n cozy-dashboard get pods
# incloud-web-gatekeeper-...  CrashLoopBackOff

kubectl --context $CTX -n cozy-dashboard logs -l app.kubernetes.io/name=gatekeeper --tail=20
# Unable to fetch OIDC well-known: dial tcp <FQDN>:443: connection refused
# (or: x509: certificate signed by unknown authority)
```

**Cause**

cozy-dashboard ships gatekeeper (oauth2-proxy), which on startup does OIDC discovery against the **public FQDN** `https://keycloak.${HOST}/realms/cozy/.well-known/openid-configuration` — not an in-cluster service. Without a root ingress controller running, nothing listens on the public IP at 443, gatekeeper crashes, the dashboard HR can't reach Ready, and anything that depends on the dashboard HR (notably `cozy-fluxcd/flux-plunger`) is stuck on the dependency.

The root ingress controller doesn't start until `tenants.apps.cozystack.io/root` is patched with `spec.ingress: true`. The Platform Package does not apply that patch by itself — it's documented as a manual step in `cozystack/docs/cozystack-installation.md:160`.

This is a chicken-and-egg of the `isp-full*` variant + OIDC combination, not a bug in any single component:

- Platform Package does not patch `tenant root.spec.host` / `spec.ingress`.
- The cozystack dependency graph is built so gatekeeper can't come up before ingress, and dashboard can't come up before gatekeeper.
- But flux-plunger waits on dashboard, which waits on ingress, which waits on the missing manual patch.

**Primary avoidance (installer ≥ 1.5.0) — install OIDC-off, converge, THEN enable OIDC.** On 1.6.x, `authentication.oidc.enabled: true` switches the system bundle to the `oidc` engine variant, which makes the dashboard `dependsOn` Keycloak (`packages/core/platform/sources/cozystack-engine.yaml`). If OIDC is enabled at install the whole chain deadlocks before the root Tenant CR even appears, so patching the tenant cannot rescue it. `cozystack:cluster-install` therefore applies the Platform Package with OIDC **off**, lets every HR converge, patches `tenants/root` (`spec.host` + `spec.ingress=true`) inline as soon as the CR appears, waits for `root-ingress-controller` to be Available, and only THEN flips `authentication.oidc.enabled=true` (matches cozystack's own `hack/e2e-install-cozystack.bats`). The inline tenant patch is for correct public URLs and to unblock the later OIDC flip — it is not itself the deadlock fix. This is the installer_version ≥ 1.5.0 path; on v1.4.x the OIDC-off token-proxy dashboard is broken, so OIDC is enabled at install there instead (SKILL.md Phase 8 version gate). See SKILL.md Phase 8.

**Recovery on an install that has already stalled in Phase 8**

On 1.6.x the stall is almost always OIDC enabled at install, and the root Tenant CR never appeared — so patching the tenant is not the first step (the patch has nothing to target). Take OIDC back off in the Package first, so the dashboard-gated chain converges and the Tenant CR shows up:

```bash
# Only if authentication.oidc.enabled was set at install time.
kubectl --context $CTX patch package cozystack.cozystack-platform --type merge \
  --patch '{"spec":{"components":{"platform":{"values":{"authentication":{"oidc":{"enabled":false}}}}}}}'
# Disabling OIDC can strand keycloak-configure in Terminating; if that HR sticks,
# recover with the off->on toggle steps in SKILL.md Phase 8.
```

Then wait for the root Tenant CR and patch host + ingress:

```bash
kubectl --context $CTX --namespace tenant-root wait tenants.apps.cozystack.io/root \
  --for=jsonpath='{.metadata.name}'=root --timeout=600s

kubectl --context $CTX --namespace tenant-root patch tenants.apps.cozystack.io root \
  --type=merge --patch "{\"spec\":{\"ingress\":true,\"host\":\"${HOST}\"}}"
```

Within ~2 min of the patch:

- `root-ingress-controller` pods come up in `tenant-root-ingress` namespace.
- External IPs from the LB pool get the wildcard ingress.
- `dashboard.${HOST}` / `keycloak.${HOST}` become reachable from the public internet.
- the dashboard (token-proxy container) and the rest of the chain reach Ready; the cluster converges to `N/N Ready`.

Once every HR is Ready and `root-ingress-controller` is Available, re-enable OIDC exactly once (SKILL.md Phase 8 step 3) and wait for the `incloud-web-gatekeeper` rollout. If the cluster was already OIDC-off (the operator followed the skill and only the tenant patch was missing), skip the disable/re-enable steps and apply the tenant patch alone.

If gatekeeper still crashes after re-enabling OIDC, double-check:

1. DNS: `dig +short keycloak.${HOST}` returns the external IPs.
2. cert-manager certificate for `*.${HOST}` is Ready (gatekeeper rejects self-signed unless `insecureSkipVerify: true`).
3. Port 80 is reachable from the public internet (Let's Encrypt HTTP-01 needs this — without a valid cert, gatekeeper TLS verify still fails).

## CNPG webhook unreachable from the apiserver (Cilium host-BPF stale endpoint)

**Symptom**

During a fresh install on Cilium + KubeOVN, Keycloak and every postgres-backed HR stall. The apiserver rejects admission on the cnpg (cloudnative-pg) mutating webhook with `connection refused` to the webhook ClusterIP; the webhook's `failurePolicy: Fail` then blocks every `Cluster` create. The webhook is reachable from ordinary pods but NOT from the apiserver.

```bash
kubectl --context $CTX get events --all-namespaces | grep -i webhook
# ... failed calling webhook "...cnpg...": ... dial tcp <WEBHOOK_CIP>:443: connect: connection refused
```

**Cause**

The cnpg operator flaps on leader-election during early KubeOVN convergence and restarts with a new pod IP. Cilium's HOST-side service BPF keeps the stale (dead) backend for the webhook ClusterIP, so host-network clients (the apiserver) dial a dead endpoint while pod-network clients get the fresh one. Not a cnpg bug and not a config error — a Cilium host-BPF staleness window during install.

**Diagnostic** — the tell is host-network vs pod-network asymmetry. `nc` to the webhook ClusterIP SUCCEEDS from a normal pod but FAILS from a `hostNetwork` pod (the apiserver's path), while cert-manager's webhook ClusterIP and `10.96.0.1` both SUCCEED from that same host-network pod:

```bash
# WEBHOOK_CIP = ClusterIP of the cnpg webhook Service in cozy-postgres-operator.
kubectl --context $CTX run nc-pod --rm --stdin --tty --restart=Never \
  --image=busybox -- nc -zvw3 $WEBHOOK_CIP 443        # from pod network → OK
kubectl --context $CTX run nc-host --rm --stdin --tty --restart=Never \
  --overrides='{"spec":{"hostNetwork":true}}' \
  --image=busybox -- nc -zvw3 $WEBHOOK_CIP 443        # from host network → refused
```

**Recovery** — force endpoint churn so Cilium resyncs the host BPF:

```bash
kubectl --context $CTX rollout restart deploy/postgres-operator-cloudnative-pg \
  --namespace cozy-postgres-operator

# Verify the webhook answers from the apiserver's path again:
kubectl --context $CTX create --dry-run=server --filename - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: webhook-probe
  namespace: default
spec:
  instances: 1
  storage:
    size: 1Gi
EOF
# Expect: admitted (dry-run), not "connection refused".
```

If it recurs, the same restart clears it.

## LINSTOR: HR stuck with no storage pool registered

**Symptom**

`cozy-linstor` HelmRelease reaches Ready but the controller logs and the LINSTOR API show no storage pool:

```bash
kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- \
  linstor storage-pool list
# Empty body (only the DfltDisklessStorPool entry on each node)
```

`cozy-linstor-csi` driver pods may then fail to mount volumes; downstream HRs that depend on PVCs (anything in `paas`, monitoring) sit Pending.

**Cause**

One of:

- `cozystack:cluster-install` Phase 5.5 was skipped or aborted partway. The zpool was not created on the node, or `linstor storage-pool create zfs <node> <name> <zpool>` was not run after `linstor-controller` reached Ready.
- The zpool exists with one name on the node, but `linstor storage-pool create` was called with a different name. LINSTOR does a byte-comparison and silently never imports the pool.
- The zpool was destroyed (operator-side wipefs / disk swap) and the LINSTOR pool entry is stale.

**Recovery**

1. Re-check what is on the node:

   ```bash
   kubectl --context $CTX debug node/$NODE --image=alpine:3 --profile=sysadmin -- \
     chroot /host /bin/sh -c 'zpool list -H -o name,size,free,health'
   ```

2. Re-check what LINSTOR thinks:

   ```bash
   kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- \
     linstor storage-pool list
   ```

3. If the zpool exists on the node but LINSTOR doesn't know about it, register it:

   ```bash
   kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- \
     linstor storage-pool create zfs <node-name> data <zpool-name>
   ```

4. If the zpool does not exist, run the create commands from `references/storage-backends.md` inside `kubectl debug node`, then re-run step 3.

5. Bounce the satellite once after the registration lands:

   ```bash
   kubectl --context $CTX --namespace cozy-linstor rollout restart daemonset/linstor-satellite
   ```

6. Verify:

   ```bash
   kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- \
     linstor storage-pool list
   # Expect one row per node with the chosen pool name and a non-zero `Capacity`.
   ```

## KubeOVN: chart render fails with "No nodes found with label …"

**Symptom**

The `kubeovn` HelmRelease never goes Ready. `kubectl describe hr` shows:

```text
Reason: InstallFailed
Message: ... template: kube-ovn/templates/_helpers.tpl: error calling fail:
  No nodes found with label 'node-role.kubernetes.io/control-plane=true'.
  Please check your MASTER_NODES_LABEL configuration or ensure master nodes are properly labeled.
```

Or, when render succeeds but pods can't schedule, `ovn-central-*` pods sit in `Pending` and `kubectl describe` shows `0/N nodes are available`.

**Cause**

`node-checks.md` covers the mechanics in full. Short version: cozystack-platform's generic variant pins `MASTER_NODES_LABEL=node-role.kubernetes.io/control-plane=true` (literal value `true`). kubeadm sets that label with **empty** value; k3s and RKE2 set it to `true`. The chart's `fail` call fires when the value byte-comparison misses.

**Recovery**

Option 1 — relabel CP nodes (works on kubeadm, no reconciler fights back):

```bash
for n in $(kubectl --context $CTX get nodes \
  --selector node-role.kubernetes.io/control-plane \
  --output jsonpath='{.items[*].metadata.name}'); do
  kubectl --context $CTX label node "$n" \
    node-role.kubernetes.io/control-plane=true --overwrite
done
```

Then poke the HR:

```bash
kubectl --context $CTX --namespace cozy-system annotate helmrelease kubeovn \
  reconcile.fluxcd.io/requestedAt="$(TZ=UTC date +%s)" --overwrite
```

Option 2 — pin explicit IPs (safest for kubeadm and Cluster API / Rancher-managed clusters that reconcile labels):

```bash
kubectl --context $CTX patch package cozystack.cozystack-platform --type=merge --patch '
spec:
  components:
    platform:
      values:
        networking:
          kubeovn:
            MASTER_NODES: "10.0.0.10,10.0.0.11,10.0.0.12"
'
```

Source for the IPs: INTERNAL-IP column of `kubectl get nodes --output wide`. Comma-separated, no spaces.

## linstor-scheduler: InvalidImageName

**Symptom**

```text
kubectl --context $CTX -n cozy-linstor get pods
linstor-scheduler-...   0/1   InvalidImageName
```

**Cause**

k3s reports kubelet version as `v1.35.0+k3s1` — the `+` is illegal in Docker image tags. linstor-scheduler templates that tag into an image reference and the API server rejects it.

**Recovery**

Fixed in Cozystack v1.0.0+ — upgrade `--installer-version` to a release that has the fix. If pinned to an older release, patch the StatefulSet manually with a fixed tag (`docker.io/piraeusdatastore/...:vX.Y.Z`).

## Cilium: API server unreachable when CP1 dies (generic HA without extractedprism)

**Symptom**

Multi-CP generic Kubernetes (k3s / kubeadm / RKE2) loses Cilium control on every node a few minutes after CP1 reboots or crashes. Cilium pods log:

```text
level=fatal msg="Unable to connect to Kubernetes apiserver" error="Get https://<CP1_IP>:6443/api/v1/...: dial tcp <CP1_IP>:6443: connect: connection refused"
```

Other CP nodes are healthy and kube-apiserver is reachable on them at the same port, but Cilium was configured with `k8sServiceHost: <CP1_IP>` (or the cozystack-operator was started with `cozystack.apiServerHost: <CP1_IP>`), so it only dials CP1.

**Cause**

`cozystack:cluster-install` defaults the `cozystack.apiServerHost` for the generic variant to either CP1's internal IP (with `--no-extractedprism`) or `127.0.0.1` via extractedprism (default). On `--no-extractedprism` without a VIP / external LB, CP1 becomes a single point of failure for kube-apiserver routing on every other node — Cilium fails open when CP1 dies. Talos avoids this with its built-in `localhost:7445` KubePrism; generic Linux has no KubePrism equivalent unless something explicit (extractedprism / kube-vip / external LB) is installed.

**Recovery**

If extractedprism wasn't installed at bootstrap time and a CP went down:

1. Temporary fix — point the operator's apiServerHost at a live CP:

   ```bash
   kubectl --context $CTX --namespace kube-system get configmap cozystack \
     --output yaml | sed "s#<DEAD_CP_IP>#<LIVE_CP_IP>#g" \
     | kubectl --context $CTX apply --filename -
   kubectl --context $CTX --namespace cozy-system rollout restart deploy/cozystack-operator
   ```

2. Permanent fix — install extractedprism after the fact and re-point the operator. The chart's `endpoints` is a comma-separated string scalar (`values.schema.json` `type=string`); render it as a values file rather than relying on `--set`, which mangles the `:` and `,` characters in `host:port` lists:

   ```bash
   cat > /tmp/extractedprism-values.yaml <<EOF
   endpoints: "$CP1_IP:6443,$CP2_IP:6443,$CP3_IP:6443"
   EOF

   helm --kube-context $CTX upgrade --install extractedprism \
     oci://ghcr.io/lexfrei/charts/extractedprism \
     --version 0.2.0 \
     --namespace kube-system \
     --values /tmp/extractedprism-values.yaml \
     --wait --timeout 5m

   # Re-render cozy-installer with apiServerHost=127.0.0.1:7445
   helm --kube-context $CTX upgrade --reset-then-reuse-values cozy-installer \
     oci://ghcr.io/cozystack/cozystack/cozy-installer \
     --version $VERSION --namespace kube-system \
     --set cozystack.apiServerHost=127.0.0.1 \
     --set cozystack.apiServerPort=7445
   ```

   Cilium picks up the new endpoint on next pod restart.

Alternative permanent fixes:

- External L4 LB (HAProxy / cloud LB) in front of all CP IPs on 6443; set `cozystack.apiServerHost` to the LB IP.
- VIP via `kube-vip` or `keepalived`; same — set `apiServerHost` to the VIP.

`cozystack:cluster-install` defaults to extractedprism on generic because it does not require operator-side LB / VRRP infrastructure and mirrors the Talos KubePrism pattern symmetrically.

## Cilium: API server unreachable on single-node clusters

**Symptom**

```text
kubectl --context $CTX -n cozy-cilium logs ds/cilium
... level=fatal msg="Unable to connect to Kubernetes apiserver" ...
```

**Cause**

Cilium replaces kube-proxy, so it can't use the `kubernetes` Service to find the apiserver — there's no kube-proxy to route it. The chart needs an explicit `k8sServiceHost` / `k8sServicePort`. On multi-node clusters the operator infers these from `cozystack.apiServerHost`. On single-node bootstrap, the values may not have flowed through yet.

**Recovery**

Set them explicitly in the Platform Package:

```yaml
spec:
  components:
    networking:
      values:
        cilium:
          k8sServiceHost: "<INTERNAL_CP_IP>"
          k8sServicePort: "6443"
```

## Inotify limits exhausted

**Symptom**

Pods fail with `too many open files`, `inotify_add_watch failed`, or kubelet logs `Failed to start cAdvisor: inotify_add_watch ...`.

**Cause**

The required sysctl values (see `node-checks.md`) weren't applied or didn't persist across reboot.

**Recovery**

Drop `/etc/sysctl.d/99-cozystack.conf` (content in `node-checks.md`), `sysctl --system`, then reboot the affected node or restart kubelet.

## cozy-system namespace owned by another release

**Symptom**

```text
helm --kube-context $CTX install ... cozy-installer ...
Error: namespace "cozy-system" exists and cannot be imported into the current release: invalid ownership metadata
```

**Cause**

A previous failed install, or `kubectl create ns cozy-system` run by hand, left the namespace without Helm's ownership labels. The cozy-installer chart templates `Namespace cozy-system` itself and refuses to adopt an unmarked namespace.

**Recovery**

Adopt the namespace before re-running `helm install` (see the snippet in `values-template.md`). Or, if nothing meaningful lives in it yet, `kubectl delete namespace cozy-system` and retry.

If it's owned by a *different* helm release (different name/namespace in the annotation), refuse. The operator must decide whether to uninstall the conflicting release.

## ZFS unavailable on RHEL 10 / Rocky 10 / Alma 10

**Symptom**

LINSTOR storage-pool creation fails on Phase 5.5 with `zpool: command not found` or `kernel module zfs not found`.

**Cause**

OpenZFS does not ship a release RPM for the RHEL 10 family yet (Rocky 10, Alma 10 in 2026). Cozystack standardises on ZFS for the LINSTOR backend — there is no first-class fallback.

**Recovery**

Switch the affected nodes to RHEL 9 / Rocky 9 / Alma 9 (OpenZFS does ship there) or to Ubuntu / Debian / Talos. `cozystack:cluster-install` refuses to proceed without ZFS available on every storage node — the LVM / LVM-thin paths existed in earlier revisions of this skill and were removed because cozystack does not validate or document them. Operators who insist on LVM are on their own with the piraeus-operator CRD's `lvmPool` / `lvmThinPool` slots; this skill will not help.

## Iptables INPUT reject on cloud images (Ubuntu OCI)

**Symptom**

Inter-pod traffic broken; Cilium logs show drops on the INPUT chain.

**Cause**

Some cloud images (Ubuntu on OCI, Oracle Linux variants) ship with a restrictive `iptables -A INPUT -j REJECT` rule that fires before Cilium's chains.

**Recovery**

Flush the host iptables INPUT chain (`iptables -F INPUT`) and persist via the distro's iptables-persistent mechanism. The ansible-cozystack role has a `cozystack_flush_iptables: true` toggle that automates this — for click-ops users without ansible, document the manual fix and link to it.

## Where to escalate

If the failure doesn't match any entry above:

- Cozystack chart / operator runtime → `cozystack/cozystack` issues.
- Install docs ambiguous or missing a step → `cozystack/website` issues.
- Node prep automation missing a task → `cozystack/ansible-cozystack` issues.
- Bug in the cozy-installer chart itself (label `area/installer`) → `cozystack/cozystack` issues.

See `issue-templates.md` for ready-to-paste issue bodies that pull from the diagnostic bundle.
