# Variant picker

Two variant axes:

1. **Installer variant** — `cozystackOperator.variant` in the cozy-installer Helm chart. Picks how the controller wires itself to the cluster.
2. **Platform variant** — `spec.variant` in the `cozystack.cozystack-platform` Package CR. Picks which bundle of system/IaaS/PaaS components is rendered.

They must match per the table in `requirements.md`.

## What each variant gives you

### `talos` / `isp-full`
Full Cozystack stack on Talos Linux: Cilium + Kube-OVN, LINSTOR storage, KubeVirt, Cluster API, full PaaS (databases, applications), monitoring. The platform owns the OS too — Talos machine-config carries the kernel modules, sysctl, services. `cozystack:cluster-install` only deploys onto an already-bootstrapped Talos cluster — it doesn't bootstrap Talos itself.

### `generic` / `isp-full-generic`
Same stack as `isp-full`, but for generic Linux (kubeadm / k3s / RKE2). Requires the user to have prepared the OS (kernel modules, sysctl, iscsid, multipathd) themselves. `cozystack:cluster-install` checks for OS readiness via `kubectl debug node` and refuses if anything is missing.

Requires the internal IP of the API server (`cozystack.apiServerHost`) — the operator needs to reach kube-apiserver to read state for things like KubeOVN's `MASTER_NODES` lookup.

### `hosted` / `isp-hosted`
PaaS-only on top of a managed Kubernetes (EKS / GKE / AKS / DOKS) or any vanilla cluster where Cozystack should not manage networking/storage/VMs. No Cilium override, no Kube-OVN, no LINSTOR, no KubeVirt. Bundles: `paas` and `naas` on, `iaas` off and refused. `system` is off in the preset up to v1.6.x and on (with a noop networking Package) from v1.7.0.

### `talos` / `isp-slim`, `generic` / `isp-slim-generic`, `hosted` / `isp-hosted-slim`
Minimal counterparts of the three variants above, for small installs such as arm64 boards and labs. Only the base platform is installed: engine, API and dashboard, tenants, ingress, gateway, and LINSTOR on `isp-slim` / `isp-slim-generic` (none on `isp-hosted-slim`). Every paas/naas application and operator, monitoring, backups, etcd, SeaweedFS, metrics-server and VPA are opt-in through `bundles.enabledPackages`; MetalLB and Multus too on `isp-slim` / `isp-slim-generic` (on `isp-hosted-slim` they are not rendered at all). An opt-in package does not pull in its `dependsOn`: the whole chain has to be listed (for example monitoring needs `cozystack.monitoring-application`, `cozystack.grafana-operator` and `cozystack.postgres-operator`, plus `cozystack.monitoring-agents`, `cozystack.metrics-server` and `cozystack.vertical-pod-autoscaler` for the agents that feed it). Entries are full Package names with the `cozystack.` prefix; a bare name matches nothing.

- The `iaas` bundle is refused (no KubeVirt, no managed Kubernetes).
- Networking on `isp-slim` / `isp-slim-generic` is Cilium alone — no Kube-OVN, so `MASTER_NODES` and the `networking.podCIDR` / `podGateway` / `serviceCIDR` / `joinCIDR` values are ignored; pod CIDRs come from `node.spec.podCIDR`, which Talos and k3s allocate by default (kubeadm needs `--pod-network-cidr`).
- On `isp-slim` / `isp-slim-generic` MetalLB is off by default (opt-in `cozystack.metallb`): `LoadBalancer` Services get addresses from Cilium L2 announcements through an admin-created `CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy`, or use `publishing.externalIPs`. On `isp-hosted-slim` the provider's load balancer serves them.
- `networking.encryption.enabled` is refused on `isp-slim` / `isp-slim-generic` (ignored on `isp-hosted-slim`, like on `isp-hosted`); `monitoring.rootEnabled` is `false` in the slim presets.
- Available only on Cozystack releases whose operator registers them. Before offering one, check that `cmd/cozystack-operator/main.go` at the target `installer_version` tag mentions `isp-slim`: in the local clone (`git -C ~/git/github.com/cozystack/cozystack grep --quiet isp-slim <tag> -- cmd/cozystack-operator/main.go` after `fetch --tags`), or at `https://raw.githubusercontent.com/cozystack/cozystack/<tag>/cmd/cozystack-operator/main.go`. If the file does not mention it, or neither source can be read, offer the full variant. After the operator is installed, confirm with `kubectl --context $CTX get packagesource cozystack.cozystack-platform --output jsonpath='{.spec.variants[*].name}'` before applying the Platform Package.

### `default`
Bare minimum — operator + PackageSource + reconciler. No bundles enabled. The operator can later be steered by hand-rolled Package CRs. Power-user territory; rarely the right pick for click-ops.

## Recommendation logic for `cozystack:cluster-install`

Drive it off cluster lookups in this order:

1. Any node has `feature.node.kubernetes.io/system-os_release.ID=talos` or `nodeInfo.osImage` starts with `Talos`?
   → recommend `talos` + `isp-full`.
2. Provider label on any node (`eks.amazonaws.com/*`, `gke.io/*`, `aks.io/*`, `kubernetes.azure.com/cluster`, `node.kubernetes.io/instance-type` matches a known managed pattern), or apiserver hostname looks managed?
   → recommend `hosted` + `isp-hosted`.
3. Any node has `nodeInfo.kubeletVersion` ending in `+k3s*`, `+rke2*`, or `osImage` matches Ubuntu/Debian/RHEL family?
   → recommend `generic` + `isp-full-generic`.
4. Otherwise:
   → recommend `default`, but warn that the user is on their own.

Then pick full vs slim: when the operator does not need VMs or managed Kubernetes (small or arm64 nodes make slim the better default, but a stated need for VMs wins), recommend the slim counterpart (`isp-slim` / `isp-slim-generic` / `isp-hosted-slim`); the packages to opt in are collected by the Phase 4 `enabledPackages` slot. Otherwise recommend the full variant.

Surface the chosen recommendation as the first option in the AskUserQuestion. Always allow override.

## Bundles inside a variant

Independently of variant, bundles are flags:

| Bundle | Default for variant | Contains |
| ----------- | ----------- | ----------- |
| `system` | on for every `isp-*` variant, except `isp-hosted` up to v1.6.x (`isp-hosted*` swap the data plane for a noop networking Package) | Cilium, Kube-OVN (not on slim), LINSTOR, cert-manager, the engine and the application catalog. |
| `iaas` | on for `isp-full*`; off and refused on `isp-hosted*` and `isp-slim*` | Cluster API, Kamaji (managed k8s for tenants), VM provisioning. |
| `paas` | on everywhere (every package opt-in on slim) | MariaDB / PostgreSQL / Redis / RabbitMQ / Kafka / Grafana / VictoriaMetrics operators. |
| `naas` | on everywhere (every package opt-in on slim) | Network-as-a-Service for tenants. |

`enabledPackages` / `disabledPackages` override individual packages inside whichever bundle they belong to.

## Source of truth

- `~/git/github.com/cozystack/cozystack/packages/core/installer/values.yaml` — variant key for the operator.
- `~/git/github.com/cozystack/cozystack/packages/core/platform/values-isp-full.yaml`, `values-isp-full-generic.yaml`, `values-isp-hosted.yaml`, `values-isp-slim.yaml`, `values-isp-slim-generic.yaml`, `values-isp-hosted-slim.yaml` — what each platform variant turns on.
- `https://cozystack.io/docs/v1.3/install/kubernetes/generic/` — canonical generic flow.
