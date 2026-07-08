# Manual Talos bootstrap steps

These are the commands `cozystack:talos-bootstrap` v1 hands to the operator to run. The skill substitutes IPs from `inventory` and the cozystack-tuned image tag from the live profile file, then waits for the operator to come back with "done".

Reference docs:

- `https://cozystack.io/docs/v1.3/install/talos/`
- `https://github.com/cozystack/boot-to-talos`
- `https://github.com/cozystack/talm`

## Step 1 — Get the right Talos image on every node

Two supported paths in v1; the operator picks one based on what they have:

### Path A — boot-to-talos (existing Linux on the nodes)

For each node currently running Linux (bare-metal, VPS, cloud VM):

```bash
ssh root@<NODE_IP> '
  curl -fsSL https://github.com/cozystack/boot-to-talos/releases/latest/download/boot-to-talos-linux-amd64 \
    -o /usr/local/bin/boot-to-talos
  chmod +x /usr/local/bin/boot-to-talos

  boot-to-talos \
    -image ghcr.io/cozystack/cozystack/talos:<COZYSTACK_TUNED_TAG> \
    -disk /dev/sda \
    -mode install \
    -yes
'
```

`-mode install` writes Talos to `/dev/sda` and reboots into it. Pick `-mode boot` instead if Secure Boot is disabled and the operator wants a kexec'd Talos that doesn't touch the disk (useful for testing, but won't survive reboot).

### Path B — fresh ISO / PXE / cloud image

Download the cozystack-tuned installer image, write to USB or serve via PXE:

```bash
docker pull ghcr.io/cozystack/cozystack/talos:<COZYSTACK_TUNED_TAG>
# Extract the metal-amd64.raw.xz artefact from the OCI image — see Cozystack docs.
```

Cloud images: use the `nocloud` profile from `~/git/github.com/cozystack/cozystack/packages/core/talos/images/talos/profiles/nocloud.yaml` as a base.

Either way: every node should boot into Talos with the cozystack-tuned extensions before Step 2.

## Step 2 — Generate machine-config with talm

```bash
mkdir -p ~/cozystack-cluster && cd ~/cozystack-cluster

# Set the right cozystack preset version
helm repo add cozystack https://charts.cozystack.io
helm repo update

# Generate cluster-wide secrets and per-node configs
talm init \
  --preset cozystack \
  --endpoint https://<CP1_IP>:6443 \
  --output-dir ./
```

`talm init` walks the operator through:

- Cluster name, network CIDRs (must match what `cluster-install` will use later — Pod 10.244.0.0/16 if kubeadm-compatible CIDRs, or whatever the operator picks).
- Node discovery — `talm` reaches out to maintenance Talos and reads NIC / disk / NUMA info.
- Output: per-node YAML files under `./nodes/<NODE>.yaml` and a cluster-wide `secrets.yaml`.

## Step 3 — Review and edit per-node configs

```bash
$EDITOR nodes/cp1.yaml
$EDITOR nodes/cp2.yaml
$EDITOR nodes/w1.yaml
```

Things to verify (the `cozystack` preset sets sensible defaults, but verify anyway):

- `machine.install.image` points at `ghcr.io/cozystack/cozystack/talos:<TAG>`.
- `machine.kernel.modules` lists drbd / zfs / spl / openvswitch / vfio_pci / vfio_iommu_type1.
- `machine.files` contains `/etc/lvm/lvm.conf` overwrite with the cozystack global_filter.
- For CP nodes: `machine.type: controlplane`, with optional `machine.network.interfaces[].vip` for HA.

## Step 4 — Apply machine-config

```bash
for n in cp1 cp2 cp3 w1; do
  talm apply -f nodes/$n.yaml --mode=auto
done
```

`--mode=auto` lets talm pick the safest reboot mode per node (try / staged / reboot). On first apply every node will reboot into the final configuration.

## Step 5 — Bootstrap etcd (CP1 only, first time only)

```bash
talosctl --talosconfig ./talosconfig --nodes <CP1_IP> bootstrap
```

This brings up etcd and Kubernetes on CP1; the other CPs join automatically.

## Step 6 — Fetch kubeconfig

```bash
talosctl --talosconfig ./talosconfig --nodes <CP1_IP> kubeconfig ~/.kube/cozystack-lab.yaml
kubectl --kubeconfig ~/.kube/cozystack-lab.yaml get nodes
```

When all nodes show `Ready`, return to `cozystack:talos-bootstrap` and say "done". The skill runs Phase 5 verification and writes `status.talos-bootstrap.completed_at`.

## Working nodes/<name>.yaml shape (cozystack v1.12+)

The cozystack talm preset auto-emits `HostnameConfig` and `LinkConfig` as v1alpha1 multidoc fragments, not legacy `machine.network.interfaces[]` / `machine.network.hostname` keys. Mixing the two shapes makes `talm template` fail with one of:

```text
the multi-doc renderer cannot translate legacy machine.network.interfaces[] from the running MachineConfig.
Move the interfaces, vlans, and addresses below into per-node body overlays as v1.12 typed documents
(LinkConfig, VLANConfig, BondConfig, RouteConfig)
```

```text
static hostname is already set in v1alpha1 config — talm.discovered.hostname auto-emits HostnameConfig
```

Working anchor body for a node that needs a static hostname + a VLAN-tagged interface for the VIP overlay (typical cozystack OCI / metal setup):

```yaml
# nodes/node0.yaml — multidoc, no legacy keys
machine:
  # Required: which interface to install Talos to.
  install:
    disk: /dev/sda
    # CVE-2026-53359: disable KVM nested virtualization (guest-to-host escape mitigation).
    # On Talos >=1.12 pin grubUseUKICmdline false so the args land on the built
    # cmdline. Takes effect on `talm upgrade` (installer re-run), not `talm apply`.
    grubUseUKICmdline: false
    extraKernelArgs:
    - kvm_intel.nested=0
    - kvm_amd.nested=0
---
apiVersion: v1alpha1
kind: HostnameConfig
name: hostname
spec:
  hostname: node0
---
apiVersion: v1alpha1
kind: LinkConfig
name: ens5
spec:
  name: ens5
  up: true
  mtu: 9000
  addresses:
    - 10.17.100.10/24
```

Three things that trip operators porting from legacy schema:

- **No `machine.network.hostname`** — talm chart auto-emits `HostnameConfig` from the preset's `talm.discovered.hostname` (which the operator's `values.yaml` overrides per-node). Setting it again under `machine.network.*` is a duplicate.
- **No `machine.network.interfaces[]`** — every interface is its own `LinkConfig` document. `VLANConfig`, `BondConfig`, `RouteConfig` follow the same multidoc shape.
- **`apiVersion: v1alpha1`** on every multidoc fragment. Skipping it makes talm reject the document silently in some versions.

The preset's `_helpers.tpl` is the source of truth; check it when in doubt.

## talm flags: explicit -e / -n every time

`talm apply` parses the `endpoints=[...]` modeline at the top of `nodes/<name>.yaml`. `talm template -i` (insecure / pre-machineconfig) does **not** — it needs explicit `--endpoints` and `--nodes` flags, otherwise it fails with `failed to determine endpoints`.

The skill always passes `-e`/`-n` explicitly rather than relying on modeline auto-resolution. Pattern:

```bash
talm template \
  --insecure \
  --talosconfig "$CONFIG_DIR/talosconfig" \
  --endpoints "$NODE_IP" \
  --nodes "$NODE_IP" \
  --file "$CONFIG_DIR/nodes/$NODE_NAME.yaml"
```

If the talm error message says `failed to determine endpoints` and the operator already has reachable nodes, the answer is not `--offline` — it's explicit `-e/-n`.

## TALOSCONFIG env doesn't persist between commands

`export TALOSCONFIG=...` in one shell invocation doesn't carry over to the next. Skills running through Claude's Bash tool spawn a fresh shell per call, so the env variable disappears.

Always pass `--talosconfig "$CONFIG_DIR/talosconfig"` explicitly on every `talm` / `talosctl` invocation. The skill does this throughout; if you're running commands manually for debugging, do the same.

## Common pitfalls

- **Wrong image tag** — `talm` default points at upstream `ghcr.io/siderolabs/installer:<X>`, **not** at the cozystack-tuned image. The `cozystack` preset overrides this; double-check `machine.install.image` if you used a different preset.
- **Cluster domain ≠ `cozy.local`** — Cozystack hard-codes it. talm cozystack preset sets it; verify `cluster.discovery.registries` if you customised.
- **HA quorum** — embedded etcd needs an odd CP count (1, 3, 5). Don't run two-CP "HA".
- **Floating IP** — the `cozystack` preset supports a Layer-2 VIP. Set it in `values.yaml` before `talm init` to avoid having to re-render configs.

## When v2 of this skill ships

v2 will:

- Drive `boot-to-talos` per node over SSH.
- Drive `talm init` / `talm apply` programmatically.
- Manage the talosconfig file alongside `state.yaml`.

Until then, this checklist is the contract.
