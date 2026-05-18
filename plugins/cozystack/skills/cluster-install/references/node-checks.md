# Node readiness checks

Run from the workstation against each node via `kubectl debug node/<name> --profile=sysadmin --image=alpine:3 -it -- chroot /host /bin/sh`. For sysadmin profile to mount /host, the cluster must support ephemeral containers (default in k8s 1.25+).

For homogeneous clusters, check one sample node and warn that the rest are assumed identical. For heterogeneous (mixed OS, mixed arch, control-plane vs worker), check every node.

## Pattern

For non-interactive runs, drive the debug pod via `-- chroot /host /bin/sh -c '<command>'` and parse the output. The `chroot /host` step pivots into the node's real root filesystem — without it, `lsmod`, `systemctl`, `sysctl` see the alpine container, not the node.

`kubectl debug` leaves an ephemeral pod on the node. Delete it after checks:

```bash
kubectl --context $CTX delete pod --field-selector=spec.nodeName=$NODE -n default \
  -l 'debug.kubernetes.io/component=ephemeral' --ignore-not-found
```

Better: run all checks in one `chroot /host /bin/sh -c '...'` invocation so the pod exits immediately after.

## Checks

### Kernel modules

Cozystack needs these loaded (the chart fails opaquely otherwise):

```sh
lsmod | awk '{print $1}' | grep -Ex 'overlay|br_netfilter|nf_conntrack|ip_tables|iptable_nat'
```

Required: `overlay`, `br_netfilter`, `nf_conntrack`, `ip_tables`, `iptable_nat`.

For Kube-OVN (non-hosted): `openvswitch`, `geneve` (autoloaded by ovs userspace — soft check).

For DRBD storage (non-hosted): either `drbd` already in `lsmod` or a buildable kernel headers tree (`/usr/src/linux-headers-$(uname -r)`) so piraeus-operator can compile in-cluster. Ubuntu Secure Boot needs `drbd-dkms` pre-installed and signed — `lsmod | grep drbd` must succeed before install.

### Required services (systemd)

```sh
systemctl is-active iscsid multipathd
```

Both must return `active`. If `inactive` or `not-found`, install + enable them:

```sh
apt-get install -y nfs-common open-iscsi multipath-tools
systemctl enable --now iscsid multipathd
```

(Or distro equivalents — `dnf install` + `iscsi-initiator-utils` + `device-mapper-multipath` on RHEL family.)

Skip this check on Talos and on hosted/managed (no SSH-style node prep there).

### sysctl values

```sh
for k in \
  fs.inotify.max_user_watches \
  fs.inotify.max_user_instances \
  fs.inotify.max_queued_events \
  fs.file-max \
  fs.aio-max-nr \
  net.ipv4.ip_forward \
  net.ipv4.conf.all.forwarding \
  net.bridge.bridge-nf-call-iptables \
  net.bridge.bridge-nf-call-ip6tables \
  vm.swappiness; do
  printf '%s = %s\n' "$k" "$(sysctl -n $k 2>/dev/null || echo MISSING)"
done
```

Required minimums (from `docs/v1.3/install/kubernetes/generic.md`):

| Key | Required value |
| ----------- | ----------- |
| `fs.inotify.max_user_watches` | `>= 524288` |
| `fs.inotify.max_user_instances` | `>= 8192` |
| `fs.inotify.max_queued_events` | `>= 65536` |
| `fs.file-max` | `>= 2097152` |
| `fs.aio-max-nr` | `>= 1048576` |
| `net.ipv4.ip_forward` | `= 1` |
| `net.ipv4.conf.all.forwarding` | `= 1` |
| `net.bridge.bridge-nf-call-iptables` | `= 1` |
| `net.bridge.bridge-nf-call-ip6tables` | `= 1` |
| `vm.swappiness` | `<= 1` |

If any value is missing or below minimum, the fix is `/etc/sysctl.d/99-cozystack.conf` + `sysctl --system`.

### Multipath blacklist

```sh
test -f /etc/multipath/conf.d/cozystack-drbd-blacklist.conf && echo PRESENT || echo MISSING
```

If `MISSING` and storage is part of the chosen variant, instruct user to add the file with content:

```conf
blacklist {
    devnode "^drbd[0-9]+"
}
```

Then `systemctl reload multipathd`.

### Storage discovery (for LINSTOR — non-hosted only)

This is a Phase 2 lookup, **before** Phase 5.5 provisioning. Cozystack standardises on ZFS — see `references/storage-backends.md`. Run the three checks per node and surface the result so the operator picks devices in Phase 4 with context.

Unmounted block devices:

```sh
lsblk --noheadings --output NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE | awk '$3=="disk" && $4=="" && $5==""'
```

Pick the largest unmounted disk per node and surface it to the user for confirmation in Phase 4. Don't auto-pick — operator must own the choice (especially for mirror / raidz layouts).

Existing zpools (Phase 4 pre-fills defaults from whatever is already there):

```sh
zpool list -H -o name,size,free,health 2>/dev/null
```

Empty output is fine (means nothing yet — Phase 5.5 will create). Non-empty output is a signal: either reuse (the skill takes the name as default) or refuse to touch (if the pool is already serving data).

ZFS tooling availability:

```sh
command -v zpool zfs
zfs version 2>/dev/null | head -1
```

Both binaries must be present and the kernel module loadable. If missing on non-Talos, the install command per distro:

- Ubuntu / Debian: `apt-get install -y zfsutils-linux` (ansible-cozystack's `prepare-ubuntu.yml` does this).
- RHEL 9 / Rocky 9 / Alma 9: install OpenZFS from `zfsonlinux.org` repo.
- RHEL 10 / Rocky 10 / Alma 10: **not supported** — OpenZFS does not publish for the RHEL 10 family yet. See `references/known-failures.md`.
- Talos: built into the cozystack-tuned image as the `siderolabs/zfs` extension. If `lsmod | grep zfs` returns nothing, the image is not cozystack-tuned — see Phase 3 Talos gate below.

Skip the whole storage section on hosted variant.

### Talos cozystack-tuned image — Phase 3 gate (Talos only)

If Phase 2 detected Talos on any node, run these four checks. **All four must pass on every Talos node**, otherwise Phase 3 STOP GATE 1 fails with `cozystack:cluster-install` refusing to continue and pointing at `/cozystack:talos-bootstrap`.

```sh
# Kernel modules (cozystack-tuned image ships these as extensions; vanilla Talos does not)
lsmod | awk '{print $1}' | grep -Ex 'drbd|zfs|openvswitch'
```

All three names must appear in the output.

```sh
# LVM filter — cozystack-tuned machine-config writes this verbatim
grep -E '^\s*global_filter\s*=' /etc/lvm/lvm.conf | grep -E 'drbd|zd|dm-'
```

The cozystack filter is `global_filter = [ "r|^/dev/drbd.*|", "r|^/dev/dm-.*|", "r|^/dev/zd.*|" ]` — the grep returns a non-empty line on a tuned image and nothing on vanilla.

`talosctl` on the workstation (used by the operator if they need to fix things — not by the skill itself):

```bash
talosctl version --client
```

If `talosctl` is missing, the install path is `brew install siderolabs/tap/talosctl` or downloading from `https://github.com/siderolabs/talos/releases`.

Skip the whole Talos gate on non-Talos clusters.

### Cluster-domain (cluster-wide, not per-node)

```bash
kubectl --context $CTX --namespace kube-system get configmap coredns --output jsonpath='{.data.Corefile}' | grep -E 'kubernetes\s+\S+' || true
```

Must contain `kubernetes cozy.local`. If it shows `cluster.local` or anything else, refuse — see `requirements.md`.

### Control-plane node label (cluster-wide) — KubeOVN compatibility gate

KubeOVN's chart looks nodes up by a key=value pair from `MASTER_NODES_LABEL`. **The expected pair depends on the platform variant** (`~/git/github.com/cozystack/cozystack/packages/core/platform/templates/bundles/system.yaml`):

| Platform variant | Expected label and value |
| ----------- | ----------- |
| `isp-full` (Talos) | `node-role.kubernetes.io/control-plane=""` (empty value — Talos default) |
| `isp-full-generic` (k3s / kubeadm / RKE2) | `node-role.kubernetes.io/control-plane=true` (literal string `true`) |
| `isp-hosted` | not used — KubeOVN is not deployed |
| `default` | not used unless the operator hand-rolls KubeOVN |

The lookup compares the value byte-for-byte. If it doesn't match exactly, the chart `fail`s with:

```text
No nodes found with label 'node-role.kubernetes.io/control-plane=true'.
Please check your MASTER_NODES_LABEL configuration or ensure master nodes are properly labeled.
```

The trap: **kubeadm** sets the label with an empty value, but the generic platform variant expects `=true`. k3s and RKE2 set it to `=true` and pass. Talos sets it to `=""` and passes only with `isp-full`. Mixing variants and distributions is the failure path.

Check (returns `name=value` per node — value is empty when the label has no value):

```bash
kubectl --context $CTX get nodes \
  --output jsonpath='{range .items[*]}{.metadata.name}={.metadata.labels.node-role\.kubernetes\.io/control-plane}{"\n"}{end}'
```

Parse the output and match against the variant's expected value. Treat a node as a CP node when the label exists at all (key present), regardless of value — but for the KubeOVN gate, the value must match the variant.

If the value does **not** match what the variant expects, surface two recovery paths to the user (let them pick):

1. **Relabel** — fast, but only safe when the cluster's own label management won't fight back. kubeadm leaves user labels alone; k3s preserves them across reboots; some operators (Cluster API, Rancher) reconcile labels.

   ```bash
   # For isp-full-generic on kubeadm — set value to literal "true":
   kubectl --context $CTX label node $CP_NODE \
     node-role.kubernetes.io/control-plane=true --overwrite
   ```

2. **Pin explicit IPs via `MASTER_NODES`** — bypasses the lookup entirely. Collect the CP nodes' internal IPs (`kubectl get nodes -o wide`, INTERNAL-IP column) and set `networking.kubeovn.MASTER_NODES` to the comma-separated list in the values collected in Phase 4. This is the safest choice for kubeadm.

Gate: do not apply the Platform Package until **either** the label matches the variant's expected value on at least one node, **or** `MASTER_NODES` is set explicitly in the collected values. Skip this gate on `isp-hosted`.

### CNI conflict (cluster-wide)

```bash
kubectl --context $CTX --namespace kube-system get pods --output name | \
  grep -Ei 'calico|flannel|weave|kube-flannel|aws-node|azure-cni'
```

Empty output is the only safe result for non-hosted. On hosted variant, the provider CNI is expected and OK.

### Pod CIDR / Service CIDR

```bash
# Pod CIDR from node specs
kubectl --context $CTX get nodes --output jsonpath='{.items[*].spec.podCIDR}'

# Service CIDR — best-effort: read the apiserver flag, else first IP of kubernetes Service
kubectl --context $CTX --namespace kube-system get pod --selector component=kube-apiserver --output yaml 2>/dev/null \
  | grep -oE -- '--service-cluster-ip-range=[^ ]+' | head -1
kubectl --context $CTX get service kubernetes --output jsonpath='{.spec.clusterIP}'
```

On managed k8s the apiserver pod is invisible — fall back to the clusterIP of `default/kubernetes` and infer the CIDR (typically the IP's /16 or /12 base).

### Conflicting workloads

```bash
kubectl --context $CTX get deploy,daemonset --all-namespaces \
  --output jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
  | grep -Ei 'ingress-nginx|cert-manager|metrics-server|kube-proxy|traefik|servicelb' || true
```

Any hit (other than the managed-k8s provider's own copies) is a blocker. Either remove the workload or refuse install.
