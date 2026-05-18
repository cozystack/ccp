# Storage backend: ZFS (the only supported path)

Cozystack standardises on ZFS for LINSTOR storage pools. Other backends (LVM, LVM-thin) exist in piraeus-operator's CRD and `linstor physical-storage create-device-pool` supports them, but cozystack documentation and the upstream platform tooling assume ZFS — using anything else means leaving the supported path and dealing with edge cases the project hasn't validated.

Reference: `https://cozystack.io/docs/next/storage/disk-preparation/`.

This file is the source of truth for the commands `cozystack:cluster-install` Phase 5.5 runs in `kubectl debug` → `chroot /host` to provision the pool on each storage node.

## Prerequisites

- One dedicated unmounted block device per storage node (`/dev/nvme0n1`, `/dev/sdb`, …). Phase 2 lookup surfaces unmounted disks.
- `zfsutils-linux` (Ubuntu/Debian) or `zfs` (Talos via the cozystack-tuned image extension) installed on every storage node.
- Kernel module `zfs` loaded. On Talos this is in the cozystack-tuned image as `siderolabs/zfs:<ver>-<talos>`. On generic Linux ansible-cozystack's `prepare-ubuntu.yml` handles installation and module load.

## Default names

`cozystack:cluster-install` proposes these defaults; operator can override:

| Slot | Default | Notes |
|---|---|---|
| ZFS pool | `data` | Conventional cozystack name. |
| LINSTOR storage pool | `data` | What `linstor storage-pool list` shows; referenced by every StorageClass `parameters.linstor.csi.linbit.com/storagePool`. |

Names must be consistent between three places:

1. The on-disk artefact (`zpool list` shows the pool).
2. The `linstor storage-pool create zfs <node> <name> <zpool>` registration.
3. Any StorageClass that references the pool.

## Create command (per storage node, inside `chroot /host`)

```sh
set -euo pipefail
test -b "$DEVICE"

# Refuse if the device already has a zpool — operator must wipe first.
if zpool list -H -o name 2>/dev/null | grep -qx "$POOL_NAME"; then
  echo "zpool '$POOL_NAME' already exists on this node" >&2
  exit 1
fi

# ashift=12 — 4 KiB physical sector alignment; safe for SSD + HDD.
# atime=off, compression=lz4 — cozystack-conventional tuning.
zpool create -o ashift=12 "$POOL_NAME" "$DEVICE"
zfs set compression=lz4 "$POOL_NAME"
zfs set atime=off "$POOL_NAME"
```

For multi-disk pools (mirror / RAID-Z), the cozystack docs recommend a single `zpool create` with the vdev layout inline:

```sh
# Two-way mirror:
zpool create -o ashift=12 "$POOL_NAME" mirror "$DEVICE1" "$DEVICE2"

# RAID-Z (3+ disks, one parity):
zpool create -o ashift=12 "$POOL_NAME" raidz "$DEVICE1" "$DEVICE2" "$DEVICE3"
```

Phase 4 collects the layout per node (single / mirror / raidz) so the skill renders the right `zpool create` invocation.

## Register the pool with LINSTOR

The `LinstorSatelliteConfiguration` CRD has **no** `zfsPool` slot — ZFS pools are registered at runtime via the LINSTOR API. `cozystack:cluster-install` runs the registration **inside the Phase 8 watch loop**, gated on `linstor-controller` reporting at least one Ready replica — not on all HRs being Ready, because paas / monitoring HRs that request PVCs depend on the storage pool existing, so an all-HRs-Ready gate would deadlock. See SKILL.md Phase 8 for the implementation, not a forward-reference. The block:

```bash
yq --output-format=json '.cozystack.storage.nodes' "$STATE_FILE" \
  | jq --compact-output '.[]' \
  | while IFS= read -r entry; do
      NODE=$(jq --raw-output '.name' <<<"$entry")
      ZPOOL=$(jq --raw-output '.zpool' <<<"$entry")
      LINPOOL=$(jq --raw-output '.linstor_pool' <<<"$entry")
      # Idempotent: skip if already registered.
      if kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- \
           linstor storage-pool list --node "$NODE" --storage-pool "$LINPOOL" \
           --output-version v1 2>/dev/null | grep -q "$LINPOOL"; then
        continue
      fi
      kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- \
        linstor storage-pool create zfs "$NODE" "$LINPOOL" "$ZPOOL"
    done
```

The `while read -r` form is safer than `for entry in $(...)`: avoids word-splitting on whitespace inside JSON values, preserves quoting, and reads one JSON document per line as `jq -c` emits them.

The loop iterates every storage-providing node persisted in `state.cozystack.storage.nodes[]`, **not** only control-plane. Phase 5.5 writes that list with the per-node zpool and linstor_pool names.

## Verify

```sh
# On the node, after create:
zpool status "$POOL_NAME"
zpool list -H -o name,size,free,health "$POOL_NAME"

# From the workstation, after LINSTOR registration:
kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- \
  linstor storage-pool list
# Expect one ZFS row per storage node with the chosen name and non-zero Capacity.
```

## Backout (only on operator approval)

The skill never auto-destroys. If operator changes their mind:

```sh
# Inside chroot /host on the node:
zpool destroy "$POOL_NAME"
wipefs --all "$DEVICE"
```

`wipefs` clears the partition signature so a re-run of Phase 5.5 sees the device as truly empty.

## What about LVM / LVM-thin?

The piraeus-operator CRD has `lvmPool` and `lvmThinPool` slots and `linstor physical-storage create-device-pool` supports them. Cozystack itself does not validate or document these paths, the platform charts assume ZFS storage classes, and several troubleshooting playbooks in cozystack docs only cover ZFS. If an operator insists on LVM, the skill refuses to provision automatically and points at the upstream piraeus-operator docs — they're on their own for the integration.

## Talos path — privileged DaemonSet bootstrap (the actual mechanism)

`kubectl debug node/<name> --image=alpine:3 -- chroot /host zpool create` **does not work on Talos**. Three independent reasons:

1. The cozystack-tuned Talos image's `zpool` userspace lives at `/usr/local/sbin/zpool` and is glibc-linked, depending on `/lib64/ld-linux-x86-64.so.2`. Talos's host rootfs is musl-statically-linked and has no glibc loader; the loader is only present inside the `ext-zfs-service` system-extension namespace. Running `zpool` in a chroot to the host rootfs gets `relocation error: /lib64/ld-linux-x86-64.so.2: not found`.
2. `chroot /host /bin/sh` fails — `/bin/sh` does not exist in Talos rootfs. Talos's PID 1 is the `machined` Go binary, not a POSIX shell environment.
3. Pod Security Admission (`baseline` enforced on `default` and `kube-system` since k8s 1.25) rejects the privileged debug Pod that `--profile=sysadmin` creates. The pod gets refused before it can even attempt the chroot.

The real path: a one-shot privileged Pod from `ubuntu:24.04` in a dedicated namespace with PSA `privileged`. ubuntu installs `zfsutils-linux` via apt (the userspace ZFS 2.2.x is forward-compatible with the kernel ZFS 2.4.x the cozystack-tuned image ships), bind-mounts `/dev`, `/dev/zfs`, and the chosen target disk, and runs `sgdisk` + `zpool create` directly.

```bash
# 1) Bootstrap namespace with the right PSA label
kubectl --context $CTX create ns cozy-storage-bootstrap 2>/dev/null || true
kubectl --context $CTX label ns cozy-storage-bootstrap \
  pod-security.kubernetes.io/enforce=privileged --overwrite

# 2) Pod manifest — pinned to one node, hostPID for partprobe visibility
cat <<EOF | kubectl --context $CTX --namespace cozy-storage-bootstrap apply --filename -
apiVersion: v1
kind: Pod
metadata:
  name: zpool-create-$NODE
spec:
  nodeName: $NODE
  restartPolicy: Never
  hostPID: true
  hostNetwork: true
  containers:
    - name: bootstrap
      image: ubuntu:24.04
      command: ["/bin/bash", "-c"]
      args:
        - |
          set -euo pipefail
          export DEBIAN_FRONTEND=noninteractive
          apt-get update --quiet
          apt-get install --yes --no-install-recommends gdisk parted zfsutils-linux
          # Refuse on residual state
          if pvs --noheadings --options vg_name "$DEVICE" 2>/dev/null | grep -q .; then
            echo "DEVICE $DEVICE has an LVM VG; refuse" >&2; exit 1
          fi
          if zpool list -H -o name 2>/dev/null | grep -qx "$POOL_NAME"; then
            echo "zpool '$POOL_NAME' already exists" >&2; exit 1
          fi
          # Talos has no udev inside the pod; partition manually first
          sgdisk --zap-all "$DEVICE"
          sgdisk --new=1:0:0 --typecode=1:bf01 --change-name=1:cozystack-zpool "$DEVICE"
          partprobe "$DEVICE"; sleep 1
          test -b "${DEVICE}1"
          zpool create -o ashift=12 "$POOL_NAME" "${DEVICE}1"
          zfs set compression=lz4 "$POOL_NAME"
          zfs set atime=off "$POOL_NAME"
          zpool status "$POOL_NAME"
          zpool list -H -o name,size,free,health "$POOL_NAME"
      securityContext:
        privileged: true
      volumeMounts:
        - name: dev
          mountPath: /dev
        # /dev/zfs comes through the /dev mount above — devtmpfs is shared.
        # A separate hostPath for the char device would nest inside an
        # already-mounted volume and mask one of the two.
  volumes:
    - name: dev
      hostPath: { path: /dev }
EOF

# 3) Wait for the one-shot pod to terminate (Succeeded), capture logs, clean up.
# Use phase=Succeeded, NOT condition=Ready — Ready is False once a one-shot pod
# terminates, so --for=condition=Ready hangs the full timeout on every successful
# run.
kubectl --context $CTX --namespace cozy-storage-bootstrap wait pod/zpool-create-$NODE \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s \
  || { kubectl --context $CTX --namespace cozy-storage-bootstrap describe pod/zpool-create-$NODE
       kubectl --context $CTX --namespace cozy-storage-bootstrap logs pod/zpool-create-$NODE
       exit 1; }
kubectl --context $CTX --namespace cozy-storage-bootstrap logs pod/zpool-create-$NODE
kubectl --context $CTX --namespace cozy-storage-bootstrap delete pod/zpool-create-$NODE
```

After every storage-providing node completes successfully, delete the bootstrap namespace:

```bash
kubectl --context $CTX delete ns cozy-storage-bootstrap
```

### Why not `talosctl` from `nsenter` into `ext-zfs-service`

Theoretically possible, but `ext-zfs-service` is a service-namespace not designed for ad-hoc command execution, the API isn't stable across Talos minor versions, and the `talosctl read` / `talosctl get` surface only exposes read-only Resource APIs (no shell-out). The privileged Pod path is the supported one.

### Multi-disk on Talos (mirror / raidz)

The bootstrap Pod above is single-device only. For mirror or raidz on Talos, the operator extends the pod manifest with additional `volumeMounts` for each `${DEVICE_N}`, runs `sgdisk` per disk, and ends with `zpool create ... mirror|raidz ${DEVICE1}1 ${DEVICE2}1 ${DEVICE3}1`. The skill does not auto-generate this path in v1 — surface as "multi-disk Talos requires manual Pod manifest, see this section for the shape".
