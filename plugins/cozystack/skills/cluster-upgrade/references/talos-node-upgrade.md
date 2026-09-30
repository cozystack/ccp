# Talos Node Upgrades Under Cozystack

Read this before upgrading Talos (or Kubernetes via machine config) on nodes of a running Cozystack cluster. The Cozystack `helm upgrade` in the main skill does not touch Talos; node upgrades are a separate, per-node rolling operation, and on DRBD-backed clusters most of the risk sits in the storage layer, not in Talos itself.

## Pick the target version (DRBD first)

The DRBD kernel module ships inside the `siderolabs/drbd` extension, so the Talos version decides the DRBD version. Check the extension before picking a Talos target:

| Talos | DRBD in extension | Notes |
| --- | --- | --- |
| 1.12.x | 9.2.16 | Bitmap race, see `linstor:recover` known upstream bugs |
| 1.13.0 | 9.3.1 | kTLS page-refcount bug ([siderolabs/talos#13316](https://github.com/siderolabs/talos/issues/13316), [LINBIT/drbd#134](https://github.com/LINBIT/drbd/issues/134)), fixed in 9.3.3 |
| 1.13.1–1.13.6 | 9.3.2 | Same kTLS bug; sender soft-lockup after a peer reboot (below) |
| 1.13.7–1.13.10 | 9.3.3 | kTLS fixed, no soft-lockup fix |
| 1.14.0–1.14.1 | 9.3.3 | No soft-lockup fix; needs the module change below |
| 1.14.2+ | 9.3.4 | Soft-lockup and two-phase-commit fixes; needs the module change below |

Verify the exact value for your target in `DRBD_DRIVER_VERSION` of `Pkgfile` at the matching tag of `siderolabs/extensions`.

**DRBD 9.3.2 soft-lockup.** After a peer reboots, the DRBD sender thread loops on `dtt_send_page ... sent=-32` (EPIPE) and pins a CPU. The kernel reports `rcu: INFO: rcu_preempt detected stalls on CPUs/tasks`, and everything that waits for an RCU grace period (runc, mounts, `accept`, `drbdsetup`) goes into D state with wchan `synchronize_rcu_expedited` / `__wait_rcu_gp`. Two-phase commits time out (`Two-phase commit ... timeout`, `rv = -21` / `-23`), `drbdsetup down` hangs, image pulls hang on layer extraction, and the node may reboot itself or need a hard reset. The [DRBD 9.3.4 ChangeLog](https://github.com/LINBIT/drbd/blob/drbd-9.3.4/ChangeLog) lists "Fix soft lockups: the sender thread pinning a CPU while its connection is down", many two-phase-commit fixes, a fix that ends a hanging `drbdadm disconnect`, and "Fix two nodes ending UpToDate with different data after a reconnect".

Recommendation for DRBD-backed clusters: skip 1.13.x and go 1.12 → 1.14.2+ directly. Talos 1.14 accepts upgrades from 1.12.0 (`MinimumHostUpgradeVersion` in `pkg/machinery/compatibility/talos114`), even though the Talos docs still recommend one minor at a time. A cluster already on 1.13.x should move to 1.14.2+ rather than to a later 1.13 patch.

## Machine-config changes before the first node upgrade

Apply these to every node before upgrading any of them. All three apply live, without a reboot.

### 1. Load `drbd_transport_tcp` explicitly (required for Talos 1.14)

Talos 1.14 builds the kernel with an empty modprobe path and a static usermode helper ([siderolabs/talos@e317d4b](https://github.com/siderolabs/talos/commit/e317d4b47239695f87a67e9b9484bb9aa4812fe7), from [siderolabs/pkgs#1565](https://github.com/siderolabs/pkgs/pull/1565)). The kernel can no longer load extension modules on demand through `request_module()`. DRBD used to autoload `drbd_transport_tcp` on the first `new-peer`; on 1.14 every LINSTOR adjust on the upgraded node fails with:

```text
drbdsetup new-peer ... Failure: (172) Failed to create transport (drbd_transport_xxx module missing?)
```

All resources on that node stay `Connecting` / `Unknown`, and the LINSTOR HA controller taints peers with `drbd.linbit.com/lost-quorum`. Tracked in [siderolabs/talos#14501](https://github.com/siderolabs/talos/issues/14501); the talm preset fix is [cozystack/talm#252](https://github.com/cozystack/talm/pull/252).

Detect:

```bash
talosctl --talosconfig "$CONFIG_DIR/talosconfig" --nodes "$NODE_IP" read /proc/sys/kernel/modprobe   # empty on 1.14, /sbin/modprobe on 1.13
talosctl --talosconfig "$CONFIG_DIR/talosconfig" --nodes "$NODE_IP" read /proc/modules | grep drbd   # drbd present, drbd_transport_tcp missing
```

Fix, next to the existing `drbd` entry:

```yaml
machine:
  kernel:
    modules:
      - name: drbd
        parameters:
          - usermode_helper=disabled
      - name: drbd_transport_tcp
```

The same applies to any other module that used to arrive through `request_module()` (extension modules, in-tree `=m` modules such as `dm-thin-pool` or `dm-multipath`): list it in `machine.kernel.modules`.

### 2. Disable kexec on bare metal

A kexec reboot during `talosctl upgrade` can hang bare-metal nodes: one ends powered off, another frozen with no console output. Disable kexec so Talos falls back to a firmware reboot:

```yaml
machine:
  sysctls:
    kernel.kexec_load_disabled: "1"
```

Talos then logs `kexec support is disabled via sysctl` and reboots through firmware. `talosctl upgrade --reboot-mode powercycle` also bypasses kexec for a single upgrade.

### 3. Pin the system disk

On nodes that host Talos tenant VMs, VM disks exposed on the host as loop devices or zvols carry the guest's META / BOOT / STATE partitions and can be picked as the host's SystemDisk. Talos stopped matching loop devices in 1.12.8 and 1.14.0 ([siderolabs/talos@3bae01a](https://github.com/siderolabs/talos/commit/3bae01ac11cd64265f0aaaa9e2e7f83e39bd7d73)); zvols are not covered. Right before each node upgrade:

```bash
talosctl --talosconfig "$CONFIG_DIR/talosconfig" --nodes "$NODE_IP" get systemdisk
talosctl --talosconfig "$CONFIG_DIR/talosconfig" --nodes "$NODE_IP" get disks   # match the serial of the real boot disk
```

Pin `machine.install.disk` to a `/dev/disk/by-id/...` path or use `machine.install.diskSelector.serial`: NVMe names (`nvme0n1` / `nvme1n1`) can swap between boots.

## Per-node procedure gotchas

| Situation | What happens | What to do |
| --- | --- | --- |
| `talosctl upgrade` (1.14 client) from a workstation behind an access proxy | The client cordons and drains through the kubeconfig endpoint, often an internal VIP that the workstation cannot reach: `error cordoning node ... Gateway Timeout` | Drain beforehand with `kubectl --context $CTX drain`, then pass `--drain=false` |
| Legacy upgrade path (old node API) with `--reboot-mode force` | Rejected by the legacy path | Use `default` or `powercycle` |
| Drain evicts the in-cluster agent of the access proxy the operator connects through | The running `kubectl drain` dies with an "agent is offline" error; a script keeps waiting on a drain that no longer runs | Reschedule the agent off the node before the drain, or drain over a path that does not go through that agent; verify the node is empty before rebooting |
| Counting leftover `virt-launcher` pods before reboot | Completed launchers of already-migrated VMs stay on the node | Count only `Running` / `Pending` pods |
| Talos 1.14 post-install reboot hangs | `ext-zfs-service` stays in `Stopping` after SIGKILL, stage stays `rebooting` | The installer already switched the boot slot. After about 3 minutes run `talosctl --nodes "$NODE_IP" reboot --mode force`; the node boots the new version |
| Automation discards command output | A failed `talosctl upgrade` or `kubectl drain` leaves nothing to diagnose | Never redirect operational output to `/dev/null`; log each step to a file |

## Gate between node reboots

Do not reboot the next node until storage has settled. A second reboot while a replica is still `Outdated` / `Connecting` can take quorum away from a resource.

```bash
kubectl --context $CTX get nodes --output custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key' | grep lost-quorum   # empty
kubectl --context $CTX exec --namespace cozy-linstor deploy/linstor-controller -- linstor resource list --faulty   # only SyncTarget, or empty
```

A `drbd.linbit.com/lost-quorum` NoSchedule taint also blocks pods with local PVs pinned to that node (for example tenant etcd members). If a resource loops in `Connecting` after the reboot, see `linstor:recover` ("missed finish" resync loop).

## Kubernetes minor upgrades via machine config

Changing the Kubernetes version in machine config (talm: `kubernetesVersion`) applies without a reboot, about 40 seconds per node. One `kube-controller-manager` restart with `bind: address already in use` on port 10257 during the static-pod swap is benign.

Before moving to a new Kubernetes minor, check:

- Cozystack's tested version: `hack/e2e-prepare-cluster.bats` in `cozystack/cozystack` pins e2e to a specific Kubernetes release and names the supported range.
- Cilium's tested range for the shipped Cilium version (Cilium 1.19 lists Kubernetes 1.32–1.35).
- KubeVirt on Kubernetes 1.36: VMI status updates loop on strict CRD format validation of the `checksum` fields ([kubevirt/kubevirt#17858](https://github.com/kubevirt/kubevirt/issues/17858)). KubeVirt 1.8.4 generates these fields as `int64`; older releases need the fix.

## Adding worker nodes

If `kube-controller-manager` runs with `--allocate-node-cidrs=false`, new nodes get no `spec.podCIDR`, and Cilium in IPAM mode `kubernetes` stays not ready with `required IPv4 PodCIDR not available`. Enabling `allocate-node-cidrs` is safe on a live cluster: the range allocator marks existing node CIDRs as used and does not reassign them.
