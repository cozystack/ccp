# Cluster requirements matrix

Source of truth: `https://cozystack.io/docs/v1.3/install/kubernetes/generic/` and `packages/core/installer/values.yaml` in the upstream cozystack monorepo. Pin the doc URL to the major version that matches `--installer-version`.

## Kubernetes distribution & version

| Distribution | Minimum version | Notes |
| ----------- | ----------- | ----------- |
| k3s | v1.32+ | `--flannel-backend=none --disable=traefik,servicelb,local-storage,metrics-server --disable-network-policy --disable-kube-proxy --cluster-domain=cozy.local` |
| kubeadm | v1.28+ | `dnsDomain: cozy.local` in ClusterConfiguration; KubeProxyConfiguration `mode: "none"`; `--skip-phases=addon/kube-proxy` |
| RKE2 | v1.28+ | `cni: none`, `disable: [rke2-ingress-nginx, rke2-metrics-server]`, `cluster-domain: cozy.local`, `disable-kube-proxy: true` |
| Talos | matched by talm | Use `cozystack:cluster-install` only on already-bootstrapped Talos. Bootstrap itself is out of scope. |
| Managed k8s (EKS / GKE / AKS / DOKS) | provider's current default | Hosted variant only — no LINSTOR, no KubeVirt, no Kube-OVN. |

## Cluster-wide configuration (hard requirements)

- **Cluster domain**: `cozy.local`. The Package chart enforces this in `networking.clusterDomain` and components assume it. If kube-apiserver was bootstrapped with `cluster.local` (or anything else), `cozystack:cluster-install` must refuse — re-bootstrap of the cluster is the only fix.
- **podCIDR / serviceCIDR**: must match what kube-apiserver and kubelet were started with. Mismatched values silently break service routing.
- **CNI**: none installed. Cozystack ships Cilium + Kube-OVN. If any other CNI pod (Calico, Flannel, Weave, AWS VPC CNI) is running in `kube-system`, refuse with explanation. Exception: managed/hosted variant — provider CNI stays.
- **kube-proxy**: disabled. Cilium replaces it. If kube-proxy DaemonSet exists, the install will conflict.
- **Ingress controller**: none installed. Cozystack ships ingress-nginx (`cozy-ingress-nginx`).
- **cert-manager**: none installed. Cozystack ships its own (`cozy-cert-manager`).
- **Storage provisioner**: none installed (for non-hosted). Cozystack ships LINSTOR (piraeus-operator).
- **metrics-server**: none installed. VictoriaMetrics covers metrics.

## Per-node prerequisites (generic variant — Ubuntu/Debian)

- OS: Ubuntu 22.04+ or Debian 12+ (kernel 5.x+, systemd).
- Arch: amd64 or arm64.
- Packages installed: `nfs-common`, `open-iscsi`, `multipath-tools` (or distro equivalents).
- Services enabled and running: `iscsid`, `multipathd`.
- Kernel module loaded: `br_netfilter` (persisted via `/etc/modules-load.d/`).
- sysctl values (see `node-checks.md` for the full list and exact thresholds).
- Secure Boot on Ubuntu: pre-install `drbd-dkms` from the LINBIT PPA before deploy — piraeus-operator's in-cluster compile path is rejected by kernel lockdown. See [Ubuntu + Secure Boot](https://cozystack.io/docs/v1.3/install/kubernetes/ubuntu-secure-boot/).

## Per-node prerequisites for storage (LINSTOR — non-hosted)

- One unmounted secondary block device per node (≥100 GB recommended; for prod sizes, see hardware requirements doc).
- Multipath blacklist file at `/etc/multipath/conf.d/cozystack-drbd-blacklist.conf` blocking `drbd*` devices.
- ZFS-on-Linux available **or** opt out of ZFS (LVM fallback) on distros where ZFS is unsupported (Rocky/Alma 10, etc.).

## Hardware (per node, minimum)

- Control plane: 4+ vCPU, 8+ GiB RAM.
- Worker: 4+ vCPU, 8+ GiB RAM (more if running VMs via KubeVirt).
- Node count: minimum 3 for production (1 CP + 2 workers); 1-node k3s sandbox works but no replicated storage.

## Network

- All nodes in the same L2 segment (or KubeSpan with RTT < 10 ms).
- LB IP range or external IPs reserved and routable.
- DNS: either real FQDN under operator's control, or `<LB-IP-with-dashes>.nip.io` for sandbox.
- L2 anti-spoofing disabled on the upstream switch if MetalLB L2 mode is used.

## Installer variant ↔ platform variant mapping

The cozy-installer Helm chart has its own variant (`cozystackOperator.variant`) — this picks how the operator deploys and which extra wiring it expects. The Platform Package CR has its own `spec.variant`. The two must match.

| Installer variant | Platform variant | When to pick |
| ----------- | ----------- | ----------- |
| `talos` | `isp-full` (or `distro-full`) | Talos Linux nodes — full IaaS + PaaS. |
| `generic` | `isp-full-generic` | kubeadm / k3s / RKE2 — full IaaS + PaaS on generic Linux. Requires `cozystack.apiServerHost` (internal IP of CP node). |
| `hosted` | `isp-hosted` | Managed k8s — PaaS only (no VMs, no LINSTOR). |
| any | `default` | Bare minimum — controller only, no bundles. Power-user / development. |

## Where this is enforced

- Chart values defaults: `~/git/github.com/cozystack/cozystack/packages/core/installer/values.yaml`.
- Platform defaults: `~/git/github.com/cozystack/cozystack/packages/core/platform/values.yaml`.
- Variant overlays: `packages/core/platform/values-isp-full*.yaml`, `values-isp-hosted.yaml`.
- Ansible reference: `~/git/github.com/cozystack/ansible-cozystack/roles/cozystack/{defaults,tasks}/main.yml` — read this when in doubt about a value's required form.
