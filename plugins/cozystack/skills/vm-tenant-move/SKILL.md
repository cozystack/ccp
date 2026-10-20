---
name: vm-tenant-move
description: Move a Cozystack virtual machine (VMInstance plus its VMDisks) from one tenant namespace to another without copying disk data. The PersistentVolume stays where it is and is re-bound to a new PVC in the target namespace; a VMDisk created in the target is paused, its blank DataVolume is replaced by one over the moved PVC, and CDI adopts the PVC through the cdi.kubevirt.io/storage.populatedFor annotation. Keeps the VM's kube-ovn IP and MAC by moving its ip.kubeovn.io record. Needs cluster-admin (PersistentVolumes are cluster-scoped). Read-only lookups run freely; every mutation is shown and confirmed per step.
argument-hint: "--context=<kube-context> --from=<source-namespace> --to=<target-namespace> --vm=<vminstance-name>"
---

# cozystack:vm-tenant-move

Work in reasoning mode. Use the phrasing `cozystack:vm-tenant-move`. Announce phase transitions: `cozystack:vm-tenant-move Phase N — <name>`.

> **Note on language in this SKILL.md** — every operator-facing prompt below is written in English for clarity. At runtime the skill matches the operator's natural language detected from prior conversation messages. Code identifiers, commands, file paths, and any text destined for GitHub stay canonical regardless of operator language.

## When to use this skill

The operator wants an existing VM to live in another tenant: a customer reorganised its tenants, a VM was created in the wrong one, or a workload is handed to another team. The disks are large enough that copying them is not attractive, and a short downtime is acceptable.

**Not for**:

- Copying a VM while the original keeps running → restore a backup into another namespace instead (see *Fallback* at the end).
- Moving between clusters → backup and restore only.
- Renaming a VM inside the same namespace → out of scope.

## How it works

Disk data is never copied. Each disk's PersistentVolume keeps its data and only changes which PVC points at it:

1. In the target namespace, create the `VMDisk` first, wait for its blank DataVolume, suspend its HelmRelease, and delete the blank DataVolume.
2. Stop the source VM, set its PVs to `Retain`, delete the source `VMInstance` and `VMDisk`. The PVCs go away; the PVs stay `Released` with the data.
3. In the target namespace, create a PVC `vm-disk-<disk>` with `spec.volumeName` and the annotation `cdi.kubevirt.io/storage.populatedFor: vm-disk-<disk>`, and replace the PV's old `claimRef` with a reference to it. The PV itself is not deleted.
4. Re-create the DataVolume over that PVC with the same Helm metadata the chart gave it, then resume the HelmRelease.
5. Move the VM's `ip.kubeovn.io` record, create the `VMInstance` halted, check its IP/MAC, start it.

Why `populatedFor` is enough: CDI v1.66.1 lets a PVC exist before its DataVolume when `pvc.Annotations["cdi.kubevirt.io/storage.populatedFor"] == dv.Name` (`pkg/controller/common/util.go`, `ClaimMayExistBeforeDataVolume`). The DataVolume webhook then accepts the DataVolume, the controller skips import/clone (`pvcRequiresWork`), marks the DataVolume `storage.prePopulated` and takes ownership of the PVC. No feature gate and no CDI configuration change is needed. `cdi.kubevirt.io/allowClaimAdoption` does **not** work on a PVC — CDI reads it from the DataVolume only — which is why older Cozystack procedures that put it on the PVC had to disable the CDI webhooks.

The same PV re-bind is what Cozystack itself does in `internal/migrationcontroller/handoff.go` (VM import), and the IP/MAC move follows platform migration `packages/core/platform/images/migrations/migrations/29`.

Names: `VMDisk <d>` → HelmRelease, DataVolume and PVC `vm-disk-<d>`; `VMInstance <vm>` → HelmRelease and VirtualMachine `vm-instance-<vm>`.

## What changes for the VM owner

Tell the owner before Phase 3:

- Downtime lasts from Phase 3 until Phase 8.
- IP and MAC are kept (Phase 6) if both namespaces use the same kube-ovn subnet. The external LoadBalancer IP changes unless the cluster uses MetalLB and Phase 7's optional step is taken.
- **cloud-init runs as on a first boot.** The vm-instance chart derives the firmware UUID from the namespace (`stableUuid` in `packages/apps/vm-instance/templates/_helpers.tpl`), and KubeVirt passes it to the guest as the cloud-init instance-id. Expect new SSH host keys and user-data applied again.
- Service DNS name, network policies, quotas and backups are now the target tenant's. Old `Backup` objects stay in the source namespace; `Plan`s must be re-created.

## Core principles

- Match the operator's natural language.
- Every `kubectl` call carries an explicit `--context "$CTX"`. Never switch the kubeconfig's current context.
- Read-only lookups run freely. Every mutating command is printed and runs only after the operator confirms that step.
- Do not advance past a step until its **Done when** criterion holds. On any mismatch, stop and report — do not improvise a fix that deletes something.
- Never delete a PV. Never return a PV to `Delete` before Phase 9.
- Keep `$WORK` (saved manifests and `pv-map.txt`): it is the only input for a rollback.

## Phase 1 — Scope, checks and snapshot

```bash
export CTX='<kube-context>'
export SRC='tenant-<source>'
export DST='tenant-<target>'
export VM='<vminstance-name>'
export DISKS="$(kubectl --context "$CTX" -n "$SRC" get vminstance "$VM" -o jsonpath='{.spec.disks[*].name}')"
export WORK="$HOME/vm-move-$VM"; mkdir -p "$WORK"

kubectl --context "$CTX" auth can-i patch persistentvolumes            # yes
kubectl --context "$CTX" -n "$SRC" get vminstance "$VM" -o jsonpath='{.spec.networks}{"\n"}'
kubectl --context "$CTX" -n "$DST" get vminstance,vmdisk               # $VM and $DISKS must not exist here
kubectl --context "$CTX" -n "$DST" describe resourcequota               # room for the disks and the VM

kubectl --context "$CTX" -n "$SRC" get vminstance "$VM" -o yaml > "$WORK/src-vminstance.yaml"
kubectl --context "$CTX" get ip.kubeovn.io "vm-instance-$VM.$SRC" -o jsonpath='{.spec.ipAddress} {.spec.macAddress} {.spec.subnet}' > "$WORK/src-ovn-ip.txt"
kubectl --context "$CTX" -n "$SRC" get svc "vm-instance-$VM" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' > "$WORK/src-ext-ip.txt"
: > "$WORK/pv-map.txt"
for d in $DISKS; do
  kubectl --context "$CTX" -n "$SRC" get vmdisk "$d" -o yaml > "$WORK/src-vmdisk-$d.yaml"
  PV=$(kubectl --context "$CTX" -n "$SRC" get pvc "vm-disk-$d" -o jsonpath='{.spec.volumeName}')
  REQ=$(kubectl --context "$CTX" -n "$SRC" get pvc "vm-disk-$d" -o jsonpath='{.spec.resources.requests.storage}')
  POLICY=$(kubectl --context "$CTX" get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')
  echo "$d $PV $REQ $POLICY" >> "$WORK/pv-map.txt"
done
cat "$WORK/pv-map.txt"
```

Also check that no other VMInstance in `$SRC` lists the same disks.

**Done when** `pv-map.txt` has one `<disk> <pv> <size> <policy>` line per disk and `$DST` has nothing with the same names. If the VM has `networks`, the same NetworkAttachmentDefinitions must exist in `$DST`, or the operator decides to drop them from the VMInstance in Phase 7.

If the cluster has Velero and a BackupClass, offer a `BackupJob` of the VMInstance before Phase 3 as insurance.

## Phase 2 — Prepare the VMDisks in the target and pause them

No downtime yet. For each disk create a `VMDisk` with the same `storage`, `storageClass`, `optical` and `bindImmediately` as in `src-vmdisk-<d>.yaml`, **without `source`**:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: VMDisk
metadata:
  name: <d>
  namespace: <DST>
spec:
  storage: <as in the source>
  storageClass: <as in the source>     # must match the PV's StorageClass
  optical: false
  bindImmediately: true
```

```bash
kubectl --context "$CTX" apply -f "$WORK/dst-vmdisk-$d.yaml"
kubectl --context "$CTX" -n "$DST" wait dv "vm-disk-$d" --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m
kubectl --context "$CTX" -n "$DST" patch hr "vm-disk-$d" --type merge -p '{"spec":{"suspend":true}}'
kubectl --context "$CTX" -n "$DST" get dv "vm-disk-$d" -o yaml > "$WORK/dst-dv-$d.yaml"
kubectl --context "$CTX" -n "$DST" delete dv "vm-disk-$d"
kubectl --context "$CTX" -n "$DST" wait pvc "vm-disk-$d" --for=delete --timeout=5m
```

**Done when** every HelmRelease `vm-disk-<d>` in `$DST` has `suspend: true`, its DataVolume YAML is saved, and the blank DataVolume and PVC are gone. The blank PV goes with them because its policy is still the class default.

## Phase 3 — Stop the source VM and protect its volumes

Downtime starts here.

```bash
kubectl --context "$CTX" -n "$SRC" patch vminstance "$VM" --type merge -p '{"spec":{"runStrategy":"Halted"}}'
kubectl --context "$CTX" -n "$SRC" wait vmi "vm-instance-$VM" --for=delete --timeout=5m
while read d PV REQ POLICY; do
  kubectl --context "$CTX" patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
done < "$WORK/pv-map.txt"
```

**Done when** the VMI is gone and every PV in `pv-map.txt` shows `Retain`. **Do not continue without `Retain`**: Phase 4 would delete the data.

## Phase 4 — Delete the VM and disks in the source tenant

```bash
kubectl --context "$CTX" -n "$SRC" delete vminstance "$VM"
for d in $DISKS; do
  kubectl --context "$CTX" -n "$SRC" delete vmdisk "$d"
  kubectl --context "$CTX" -n "$SRC" wait pvc "vm-disk-$d" --for=delete --timeout=5m
done
while read d PV REQ POLICY; do kubectl --context "$CTX" get pv "$PV"; done < "$WORK/pv-map.txt"
```

**Done when** every PV still exists, `Released`, `Retain`. Never delete a PVC by hand while its DataVolume exists: CDI may re-create it empty.

## Phase 5 — Put the old PV under the target VMDisk

The PVC copies `accessModes`, `volumeMode` and `storageClassName` from the PV. Pre-binding through `volumeName` skips the `volumeMode` match check, so a wrong mode binds and only fails at mount time.

```bash
while read d PV REQ POLICY; do
  SC=$(kubectl --context "$CTX" get pv "$PV" -o jsonpath='{.spec.storageClassName}')
  MODE=$(kubectl --context "$CTX" get pv "$PV" -o jsonpath='{.spec.volumeMode}')
  ACCESS=$(kubectl --context "$CTX" get pv "$PV" -o jsonpath='{.spec.accessModes}')
  kubectl --context "$CTX" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vm-disk-$d
  namespace: $DST
  annotations:
    cdi.kubevirt.io/storage.populatedFor: vm-disk-$d
spec:
  accessModes: $ACCESS
  volumeMode: ${MODE:-Filesystem}
  storageClassName: $SC
  volumeName: $PV
  resources:
    requests:
      storage: $REQ
EOF
  # The PV is not deleted: its old claimRef is replaced by a reference to the new PVC
  kubectl --context "$CTX" patch pv "$PV" --type json -p "[{\"op\":\"replace\",\"path\":\"/spec/claimRef\",\"value\":{\"apiVersion\":\"v1\",\"kind\":\"PersistentVolumeClaim\",\"namespace\":\"$DST\",\"name\":\"vm-disk-$d\"}}]"
  kubectl --context "$CTX" -n "$DST" wait pvc "vm-disk-$d" --for=jsonpath='{.status.phase}'=Bound --timeout=2m
done < "$WORK/pv-map.txt"
```

Removing the `claimRef` outright (`[{"op":"remove","path":"/spec/claimRef"}]`) also works, but for a moment the PV is `Available` and any pending PVC of the same class can take it. Replacing it leaves no such window.

Then, per disk, re-create the DataVolume from `dst-dv-<d>.yaml`. Keep `metadata.name`, `namespace`, `labels`, the `meta.helm.sh/*` and `vm-disk.cozystack.io/*` annotations and the whole `spec`. Drop `uid`, `resourceVersion`, `creationTimestamp`, `managedFields`, `status`, `ownerReferences` and every `cdi.kubevirt.io/*` annotation except `storage.bind.immediate.requested`:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: vm-disk-<d>
  namespace: <DST>
  labels:
    app.kubernetes.io/instance: vm-disk-<d>
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: vm-disk-<d>
    meta.helm.sh/release-namespace: <DST>
    vm-disk.cozystack.io/source: "{}"
    vm-disk.cozystack.io/storage-class: "<as in the saved file>"
    vm-disk.cozystack.io/optical: "false"
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"   # only if present in the saved file
spec:
  # spec from dst-dv-<d>.yaml, unchanged (blank source, storage)
```

```bash
kubectl --context "$CTX" apply -f "$WORK/new-dv-$d.yaml"
kubectl --context "$CTX" -n "$DST" get dv "vm-disk-$d" -o jsonpath='{.status.phase} {.metadata.annotations.cdi\.kubevirt\.io/storage\.prePopulated}{"\n"}'
kubectl --context "$CTX" -n "$DST" get pvc "vm-disk-$d" -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
kubectl --context "$CTX" -n "$DST" get pods | grep -E 'importer|upload|clone' || echo "no CDI worker pods"
```

**Done when** the DataVolume is `Succeeded` with `prePopulated=vm-disk-<d>`, the PVC is owned by a `DataVolume`, and no importer/upload/clone pod exists.

- Webhook rejects with `Destination PVC … already exists` → the PVC lacks `populatedFor` or it names something else. Fix the annotation and apply again.
- An `importer-*` pod appears → stop, delete nothing, and report.

Resume the HelmRelease:

```bash
kubectl --context "$CTX" -n "$DST" patch hr "vm-disk-$d" --type merge -p '{"spec":{"suspend":false}}'
kubectl --context "$CTX" -n "$DST" wait hr "vm-disk-$d" --for=condition=Ready --timeout=5m
```

The chart finds the existing DataVolume and renders its `spec` as is (`packages/apps/vm-disk/templates/dv.yaml`, the `$existingDV` branch), so nothing is re-created.

## Phase 6 — Move the IP and MAC (kube-ovn)

kube-ovn keeps the VM's address in the cluster-scoped `ip.kubeovn.io` object `vm-instance-<vm>.<namespace>`. When the vm-instance chart renders, it looks that object up for its own namespace and, if found, puts its IP and MAC into the `ovn.kubernetes.io/ip_address` and `ovn.kubernetes.io/mac_address` annotations of the VM template (`packages/apps/vm-instance/templates/vm.yaml`). Creating the record under the new name before the VMInstance exists is therefore enough.

This only works if the target namespace is in the same subnet. By default every tenant uses `ovn-default`; if the namespace carries `ovn.kubernetes.io/logical_switch`, it must equal `$OVN_SUBNET`. If not, skip this phase and tell the owner the IP and MAC will change.

```bash
read OVN_IP OVN_MAC OVN_SUBNET < "$WORK/src-ovn-ip.txt"
kubectl --context "$CTX" get ns "$DST" -o jsonpath='{.metadata.annotations.ovn\.kubernetes\.io/logical_switch}{"\n"}'

kubectl --context "$CTX" apply -f - <<EOF
apiVersion: kubeovn.io/v1
kind: IP
metadata:
  name: vm-instance-$VM.$DST
  labels:
    $OVN_SUBNET: ""
    ovn.kubernetes.io/ip_reserved: "true"
    ovn.kubernetes.io/subnet: $OVN_SUBNET
spec:
  ipAddress: "$OVN_IP"
  v4IpAddress: "$OVN_IP"
  v6IpAddress: ""
  macAddress: "$OVN_MAC"
  namespace: "$DST"
  podName: "vm-instance-$VM"
  podType: "VirtualMachine"
  subnet: "$OVN_SUBNET"
  attachIps: []
  attachMacs: []
  attachSubnets: []
EOF

# Delete the old record if kube-ovn did not remove it with the VM
kubectl --context "$CTX" delete ip.kubeovn.io "vm-instance-$VM.$SRC" --ignore-not-found
```

**Done when** `ip.kubeovn.io/vm-instance-$VM.$DST` shows the old IP and MAC and `vm-instance-$VM.$SRC` is gone. Between Phase 4 and this phase the address is free and could in theory go to another pod, so run Phases 4–6 back to back.

## Phase 7 — Create the VMInstance halted

Copy the whole `spec` from `src-vminstance.yaml`. Two differences only: `runStrategy: Halted`, and `networks` adjusted if the operator decided so in Phase 1.

```bash
{ printf 'apiVersion: apps.cozystack.io/v1alpha1\nkind: VMInstance\nmetadata:\n  name: %s\n  namespace: %s\n' "$VM" "$DST"
  sed -n '/^spec:/,/^status:/p' "$WORK/src-vminstance.yaml" | sed '/^status:/d'; } > "$WORK/dst-vminstance.yaml"
# set runStrategy: Halted in dst-vminstance.yaml and show it to the operator before applying
kubectl --context "$CTX" apply -f "$WORK/dst-vminstance.yaml"
kubectl --context "$CTX" -n "$DST" wait hr "vm-instance-$VM" --for=condition=Ready --timeout=5m
kubectl --context "$CTX" -n "$DST" get vm "vm-instance-$VM" -o jsonpath='{.spec.template.metadata.annotations}{"\n"}'
```

**Done when** the VM template carries `ovn.kubernetes.io/ip_address` and `ovn.kubernetes.io/mac_address` with the old values (if Phase 6 ran). If they are missing, the chart did not find the record from Phase 6: check its name.

Optional, MetalLB only (`metallb.io/loadBalancerIPs`, present in the MetalLB v0.16.1 Cozystack ships) — keep the external IP:

```bash
kubectl --context "$CTX" -n "$DST" annotate svc "vm-instance-$VM" metallb.io/loadBalancerIPs="$(cat "$WORK/src-ext-ip.txt")"
```

## Phase 8 — Start and verify

```bash
kubectl --context "$CTX" -n "$DST" patch vminstance "$VM" --type merge -p '{"spec":{"runStrategy":"Always"}}'
kubectl --context "$CTX" -n "$DST" wait vmi "vm-instance-$VM" --for=condition=Ready --timeout=10m
virtctl --context "$CTX" -n "$DST" ssh <user>@vm/vm-instance-$VM -c 'ip a; df -h; cloud-init status'
```

Use the original `runStrategy` from `src-vminstance.yaml` if it was not `Always`.

**Done when** the guest booted, the data is there and the network is up. A new SSH host key is expected.

No network on an Ubuntu guest without `cloudInit` and `sshKeys`: cloud-init did not re-run and netplan is still bound to the old MAC, so the MAC was not kept — re-check Phase 6, otherwise fix netplan from `virtctl console`.

## Phase 9 — Close

Only after the VM owner confirms the VM works. Return every PV to the policy recorded in Phase 1 (usually `Delete`):

```bash
while read d PV REQ POLICY; do
  kubectl --context "$CTX" patch pv "$PV" -p "{\"spec\":{\"persistentVolumeReclaimPolicy\":\"$POLICY\"}}"
done < "$WORK/pv-map.txt"
```

Then re-create backup `Plan`s in `$DST` and remove the old ones in `$SRC`. Keep `$WORK` as long as backups of the source VM exist.

## Rollback

While the PVs are `Retain`, no phase loses data. Only deleting a PV, or deleting a PVC while its PV is `Delete`, is irreversible.

- **Before Phase 4**: restore the source `runStrategy` and PV policies, delete the prepared VMDisks in `$DST`.
- **After Phase 4**: run the same procedure in reverse with `SRC` and `DST` swapped. Back in the source namespace the VM gets its original firmware UUID (the formula is deterministic), so cloud-init does not run a second time.

## Fallback: restore a backup into the target namespace

Use it when the PV cannot be re-bound, or when a copy is wanted while the source keeps running. Data goes through backup storage, which is slower; it needs Velero and a BackupClass with a VMInstance strategy.

```yaml
apiVersion: backups.cozystack.io/v1alpha1
kind: RestoreJob
metadata:
  name: move-<VM>
  namespace: <SRC>
spec:
  backupRef:
    name: <VMInstance Backup>
  targetApplicationRef:
    apiGroup: apps.cozystack.io
    kind: VMInstance
    name: <VM>
  options:
    targetNamespace: <DST>
    failIfTargetExists: true
    keepOriginalIpAndMac: false   # defaults to true; keep false while the source VM is alive
```

Reference: `internal/backupcontroller/velerostrategy_controller.go` (`RestoreOptions`, `resolveRestoreTarget`) and `examples/backups/vmi/07-restore-to-copy.sh` in `cozystack/cozystack`.
