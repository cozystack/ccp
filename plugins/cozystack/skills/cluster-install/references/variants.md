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
PaaS-only on top of a managed Kubernetes (EKS / GKE / AKS / DOKS) or any vanilla cluster where Cozystack should not manage networking/storage/VMs. No Cilium override, no Kube-OVN, no LINSTOR, no KubeVirt. Bundles: `paas` and `naas` on by default; `system` and `iaas` off.

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

Surface the chosen recommendation as the first option in the AskUserQuestion. Always allow override.

## Bundles inside a variant

Independently of variant, bundles are flags:

| Bundle | Default for variant | Contains |
| ----------- | ----------- | ----------- |
| `system` | on for `isp-full*`, off for `isp-hosted` | Cilium, Kube-OVN, LINSTOR, ingress-nginx, cert-manager, KubeVirt — the platform infra. |
| `iaas` | on for `isp-full*`, off for `isp-hosted` | Cluster API, Kamaji (managed k8s for tenants), VM provisioning. |
| `paas` | on everywhere | MariaDB / PostgreSQL / Redis / RabbitMQ / Kafka / Grafana / VictoriaMetrics operators. |
| `naas` | on everywhere | Network-as-a-Service for tenants. |

`enabledPackages` / `disabledPackages` override individual packages inside whichever bundle they belong to.

## Source of truth

- `~/git/github.com/cozystack/cozystack/packages/core/installer/values.yaml` — variant key for the operator.
- `~/git/github.com/cozystack/cozystack/packages/core/platform/values-isp-full.yaml`, `values-isp-full-generic.yaml`, `values-isp-hosted.yaml` — what each platform variant turns on.
- `https://cozystack.io/docs/v1.3/install/kubernetes/generic/` — canonical generic flow.
