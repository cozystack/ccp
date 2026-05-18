# Canonical values for cozy-installer and the Platform Package

## Installer chart values

The cozy-installer Helm release lives in `kube-system` (the chart itself templates `Namespace cozy-system`, so the release secret can't live there). Two keys matter at install time:

```yaml
cozystackOperator:
  variant: generic        # or talos / hosted
cozystack:
  apiServerHost: ""       # see the table below
  apiServerPort: ""       # see the table below
```

`apiServerHost` / `apiServerPort` resolution by variant:

| Variant | `apiServerHost` | `apiServerPort` | Source |
|---|---|---|---|
| `talos` | `localhost` | `7445` | Talos KubePrism, built into machine-config. Hard-coded in `values-isp-full.yaml` for Cilium. |
| `generic` (default) | `127.0.0.1` | `7445` | extractedprism DaemonSet installed in Phase 5.6, proxies to a healthy CP endpoint. See the [extractedprism](#extractedprism-generic-kube-apiserver-ha) section below. |
| `generic` with `--no-extractedprism` | `<operator-supplied IP>` | `6443` | Operator passes `--api-host=<ip>`; that IP is a CP, a VIP, or an external LB. Single CP IP is a SPOF — see `known-failures.md`. |
| `hosted` | not set | not set | Managed provider handles kube-apiserver HA. |

Install command shape:

```bash
helm --kube-context $CTX upgrade --install cozy-installer \
  oci://ghcr.io/cozystack/cozystack/cozy-installer \
  --version $INSTALLER_VERSION \
  --namespace kube-system \
  --set cozystackOperator.variant=$INSTALLER_VARIANT \
  --set cozystack.apiServerHost=$API_HOST \
  --set cozystack.apiServerPort=$API_PORT \
  --wait --timeout 10m
```

If `cozy-system` already exists, the chart refuses with `invalid ownership metadata`. Adopt it first:

```bash
kubectl --context $CTX patch namespace cozy-system --type=merge --patch '{
  "metadata": {
    "labels": {"app.kubernetes.io/managed-by": "Helm"},
    "annotations": {
      "meta.helm.sh/release-name": "cozy-installer",
      "meta.helm.sh/release-namespace": "kube-system"
    }
  }
}'
```

(Skip adoption if the namespace doesn't exist; `--create-namespace` would conflict with the chart's own `Namespace` template, so don't pass it.)

## Platform Package CR

The Package is **cluster-scoped** (`cozystack.io/v1alpha1 / Package`). Apply once the operator deployment is Available and the `packages.cozystack.io` CRD is Established.

```yaml
apiVersion: cozystack.io/v1alpha1
kind: Package
metadata:
  name: cozystack.cozystack-platform
spec:
  variant: isp-full-generic        # or isp-full / isp-hosted / default
  components:
    platform:
      values:
        bundles:
          system:
            enabled: true
          iaas:
            enabled: true
          paas:
            enabled: true
          naas:
            enabled: true
        networking:
          podCIDR: "10.244.0.0/16"      # cozystack default, from packages/core/platform/values.yaml
          podGateway: "10.244.0.1"      # first IP of podCIDR
          serviceCIDR: "10.96.0.0/16"   # cozystack default
          joinCIDR: "100.64.0.0/16"     # cozystack default
          kubeovn:
            MASTER_NODES: ""            # comma-separated CP IPs; leave empty to let Helm lookup find them
        publishing:
          host: "example.com"
          apiServerEndpoint: "https://api.example.com:6443"
          exposedServices:
            - api
            - dashboard
          externalIPs:
            - 192.0.2.10
          exposure: externalIPs         # or "loadBalancer"
```

## extractedprism (generic kube-apiserver HA)

On the `generic` variant, `cozystack:cluster-install` Phase 5.6 installs the extractedprism DaemonSet **before** the cozy-installer chart so the operator's apiServerHost already resolves to a healthy CP endpoint when cozystack-operator starts dialing.

Chart: `oci://ghcr.io/lexfrei/charts/extractedprism` (BSD-3-Clause; source `https://github.com/lexfrei/extractedprism`).

Default values the skill passes via a rendered file under `<config-dir>/extractedprism-values.yaml` (this is the canonical artifact the orchestrator advertises and the sops opt-in encrypts):

```yaml
# <config-dir>/extractedprism-values.yaml
endpoints: "10.0.0.1:6443,10.0.0.2:6443,10.0.0.3:6443"
```

```bash
helm --kube-context $CTX upgrade --install extractedprism \
  oci://ghcr.io/lexfrei/charts/extractedprism \
  --version 0.2.0 \
  --namespace kube-system \
  --values "$CONFIG_DIR/extractedprism-values.yaml" \
  --wait --timeout 5m
```

`endpoints` is a **single string scalar** (chart `values.schema.json` `type=string`) holding a comma-separated list of every control-plane node's `<InternalIP>:6443`. A YAML list shape (`endpoints: [...]`) is rejected by helm schema validation. The chart's defaults are sane for cozystack:

- `bindAddress: 127.0.0.1` + `bindPort: 7445` — same shape as Talos KubePrism so `cozystack.apiServerHost=127.0.0.1` / `cozystack.apiServerPort=7445` in the cozy-installer values just works.
- `hostNetwork: true` — pod listens on the node's loopback.
- `priorityClassName: system-node-critical` — survives eviction storms.
- `tolerations: [{operator: Exists}]` — runs on every node regardless of taints; this proxy is critical infra.

Skip on:

- `talos` variant (built-in KubePrism at `localhost:7445`).
- `hosted` variant (managed provider handles HA).
- `--no-extractedprism` flag — operator supplied `--api-host=<ip>` (single CP, VIP, or external LB) and accepts the trade-off.

## LINSTOR storage pool registration (ZFS, runtime via CLI)

Cozystack standardises on ZFS for LINSTOR storage pools. The `LinstorSatelliteConfiguration` CRD does **not** have a `zfsPool` slot — ZFS pools are registered at runtime via the LINSTOR API once `linstor-controller` reaches Ready in Phase 8. There is no declarative-CR path the skill emits up front; instead it queues a per-node `linstor storage-pool create zfs` invocation.

The skill stores the per-node mapping in `<config-dir>/.state.yaml` under `cozystack.storage.nodes[]` so the Phase-8 hook knows what to register:

```bash
# Run once linstor-controller is Ready (Phase 8 hook).
# Iterates over every node listed in state.cozystack.storage.nodes[].
for entry in $STORAGE_NODES; do
  node="${entry%%:*}"
  zpool="${entry##*:}"
  kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- \
    linstor storage-pool create zfs "$node" data "$zpool"
done
```

Where `data` is the LINSTOR pool name and the zpool name defaults to `data` (collected in Phase 4, overridable per node).

After registration, verify:

```bash
kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- \
  linstor storage-pool list
# Expect one ZFS row per storage node with non-zero Capacity.
```

Schema source for the CRD that `LinstorSatelliteConfiguration` does support (for non-ZFS adventurers — not the cozystack path): `~/git/github.com/cozystack/cozystack/packages/system/piraeus-operator-crds/templates/crds.yaml`.

## CIDR defaults from cozystack source

Cozystack pins its own platform-level CIDRs in `~/git/github.com/cozystack/cozystack/packages/core/platform/values.yaml`. These are the values the Platform Package CR expects, regardless of the underlying distribution's default Pod / Service CIDRs:

| Field | Cozystack default |
| ----------- | ----------- |
| `podCIDR` | `10.244.0.0/16` |
| `serviceCIDR` | `10.96.0.0/16` |
| `joinCIDR` | `100.64.0.0/16` |

The defaults the cluster distribution itself uses are **not** what cozystack wants — cozystack runs Kube-OVN over the host's CNI shape, so the `podCIDR` cozystack expects is the Kube-OVN-managed range, not the distro's. Specifically:

- k3s defaults to `10.42.0.0/16 / 10.43.0.0/16`, but on a cozystack install Kube-OVN overlays `10.244.0.0/16 / 10.96.0.0/16` on top — the distro defaults become irrelevant.
- kubeadm defaults to `10.244.0.0/16 / 10.96.0.0/16` (coincidentally the same as cozystack's).
- RKE2 defaults to `10.42.0.0/16 / 10.43.0.0/16` — same story as k3s.

For cozystack purposes always use cozystack's defaults. Change only if they overlap with host routing or another in-network range; on conflict, pick non-overlapping `/16`s and document.

`wizard` Phase 4 reads the canonical values from `packages/core/platform/values.yaml` (see `wizard/SKILL.md` for the resolution order) and surfaces the source path alongside the value so the operator knows which file informed the default.

## When the user has no domain

Use `nip.io` dash notation: if the LB IP is `192.0.2.10`, set `publishing.host: "192-0-2-10.nip.io"`. Every subdomain resolves to that IP without DNS provisioning. Spell this out — click-ops users don't always know the trick.

## After Package apply

If `system` bundle is on and `cozystack_tenant_root_ingress` semantics are desired, patch the root tenant after the operator creates it:

```bash
kubectl --context $CTX wait tenants.apps.cozystack.io/root --namespace tenant-root \
  --for=jsonpath='{.metadata.name}'=root --timeout=300s
kubectl --context $CTX --namespace tenant-root patch tenants.apps.cozystack.io root \
  --type=merge --patch '{"spec":{"ingress":true}}'
```

This is what creates the `IngressClass` and brings up `ingress-nginx`.

## Per-variant overlay files in upstream

- `~/git/github.com/cozystack/cozystack/packages/core/platform/values-isp-full.yaml`
- `~/git/github.com/cozystack/cozystack/packages/core/platform/values-isp-full-generic.yaml`
- `~/git/github.com/cozystack/cozystack/packages/core/platform/values-isp-hosted.yaml`

These describe **only** the bundle deltas. Use the merged values from `packages/core/platform/values.yaml` plus the variant overlay as the baseline for what the user is editing in Phase 4.
