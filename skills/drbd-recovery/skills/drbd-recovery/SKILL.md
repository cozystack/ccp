---
name: drbd-recovery
description: Diagnose and recover DRBD/LINSTOR storage issues in Kubernetes clusters — handles StandAlone, DELETING, Inconsistent, Diskless, quorum loss, bitmap errors, and other common failure modes. Use when `linstor r l --faulty` shows broken resources or nodes have `drbd.linbit.com/lost-quorum` taints.
---

# DRBD/LINSTOR Recovery Skill

Specialized skill for diagnosing and recovering DRBD/LINSTOR storage issues in Kubernetes clusters.

## When to use

- `linstor r l --faulty` shows broken resources
- DRBD resources in StandAlone, Connecting, Inconsistent, Outdated, or Unknown state
- Stuck DELETING resources that won't complete
- TCP port collisions between DRBD devices
- Stuck toggle-disk operations
- Nodes with `drbd.linbit.com/lost-quorum` taints
- `drbdadm adjust` failing with bitmap or connection errors

## Core Principles

1. **Work one resource at a time.** On mass incidents, resist the urge to fix everything at once. Serial, monotonic recovery is safer.
2. **Always verify on the node itself.** LINSTOR's view can be stale or wrong. `drbdadm status` on the satellite is the source of truth.
3. **Preserve UpToDate replicas.** Never touch the source-of-truth replica first. Fix broken copies by working outward from the healthy one.
4. **ALWAYS verify at least one UpToDate diskful replica exists before ANY destructive action.** Run `linstor r l -r <resource>` and confirm there is at least one replica with State=UpToDate and a real storage pool (not DfltDisklessStorPool). If there are zero UpToDate diskful replicas — STOP and ask the user before proceeding. This is the single most important safety check.
5. **If SyncTarget is progressing, stop.** A resource that entered sync is already recovering. Don't interfere.
6. **Every action should simplify the graph.** Remove peers from conflict, reduce topology complexity. If an action creates new noise, don't do it.
7. **Check error-reports for the real cause.** What looks like StandAlone may actually be an `adjust` failure underneath.
8. **ASK the user before dangerous operations.** Always ask for explicit confirmation before: `linstor node lost`, force-deleting the last replica, `drbdadm down` on InUse/Primary resource, `--discard-my-data` when only one diskful copy remains.

## Diagnostic Steps

### 1. Get the full picture

```bash
linstor r l --faulty
linstor n l
```

Count faulty, categorize by state:
```bash
linstor r l --faulty | grep -oP '(UpToDate|Outdated|Inconsistent|StandAlone|Connecting|DELETING|Unknown|Diskless|SyncTarget)' | sort | uniq -c | sort -rn
```

Check node taints:
```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key'
```

Find which resources block quorum:
```bash
# On tainted node's satellite:
drbdsetup status --statistics 2>/dev/null | grep -B1 "quorum:no" | grep "^[a-z]"
```

### 2. Examine a specific resource

```bash
linstor r l -r <resource>
linstor r lv -r <resource>
```

### 3. Per-node diagnostics

```bash
# Enter satellite on the problem node:
kubectl exec -ti -n cozy-linstor ds/linstor-satellite.<node> -c linstor-satellite -- bash

# Check DRBD kernel state (most reliable):
drbdadm status <resource>
drbdsetup status <resource> --verbose

# Check .res file:
cat /var/lib/linstor.d/<resource>.res

# Check kernel logs:
dmesg | grep "<resource>"

# Check ZFS backend:
zfs list data/<resource>_00000

# Check error reports for the real error:
linstor error-reports show <report-id>
```

IMPORTANT: If `drbdadm status` answers `No such resource`, the DRBD object is gone locally. The problem is in LINSTOR metadata, not in the local DRBD state. Don't try `drbdadm down` or similar — fix the LINSTOR record instead.

## Recovery Decision Tree

```
Is the resource in Unknown state?
├─ YES: Node is likely OFFLINE. Check `linstor n l`.
│  └─ If node is alive but satellite down: fix satellite first
│  └─ If resource doesn't exist locally (`drbdadm status` = No such resource):
│     `linstor r d <node> <resource>` to clean LINSTOR record
│  └─ If node is permanently gone: ask the user for guidance
│
Is the resource in DELETING state?
├─ YES: See "Stuck DELETING" section below
│
Is the resource in StandAlone?
├─ YES: See "StandAlone" section below
│
Is the resource in Connecting?
├─ YES: Check error-reports. May be TCP port mismatch, bitmap error, or peer not up.
│
Is the resource Inconsistent or Outdated?
├─ YES: If it has a Connected UpToDate peer, resync should happen automatically.
│  └─ If stuck: `drbdadm disconnect <rsc>` then `drbdadm connect <rsc>`
│  └─ If really stuck: `drbdadm down <rsc>` then `drbdadm up <rsc>` (only if Unused!)
│
Is the resource Diskless when it should be diskful?
├─ YES: See "False Diskless" section below
│
Is the resource SyncTarget with progress?
└─ YES: **Do nothing.** Let it finish.
```

## Fix: StandAlone Connections

StandAlone means DRBD detected data inconsistency between peers. The standard fix:

**On the StandAlone (secondary/outdated) side:**
```bash
drbdadm disconnect <resource>
drbdadm connect --discard-my-data <resource>
```

**On the UpToDate (source of truth) side:**
```bash
drbdadm disconnect <resource>
drbdadm connect <resource>
```

The `--discard-my-data` flag tells DRBD to accept the peer's data as authoritative. It only takes effect during split-brain resolution; in other cases it has no effect.

**CRITICAL**: Never use `--discard-my-data` on the only UpToDate copy!

**If StandAlone keeps returning after reconnect:**
Check dmesg for `Unrelated data, aborting!` — this means GI (generation identifiers) diverged completely. The resource must be deleted and recreated:
```bash
linstor r d <broken-node> <resource>
linstor rd ap <resource>
```

## Fix: Unknown on Dead Node Blocking DELETING

When one node has `Unknown` and other replicas are stuck in `DELETING`:

```bash
# If the node is alive but resource doesn't exist locally:
linstor r d <dead-node> <resource>
```

This unblocks cleanup of the remaining `DELETING` replicas.

If the node is permanently gone and individual `r d` doesn't help — **ask the user** for guidance on how to proceed. Do not use `node lost` without explicit user instruction.

## Fix: Stuck DELETING Resources

### Method 1: Deactivate + Delete
```bash
linstor r deact <deleting-node> <resource>
linstor r d <deleting-node> <resource>
```

### Method 2: Convert + Toggle-disk
```bash
linstor r c <deleting-node> <resource>        # convert from DELETING
linstor r td --diskless <deleting-node> <resource>  # clean toggle
```

### Method 3: Force-delete (if patched)
If the force-delete patch is deployed:

**BEFORE force-delete:**
1. Run `linstor r l -r <resource>` — confirm at least one UpToDate diskful replica exists on ANOTHER node
2. If this is the last diskful replica — **STOP and ask the user**
3. Check if PVC is still Bound: `kubectl get pv <resource>` — if Bound and this is among the last replicas, **ask the user**

```bash
linstor r sp <node> <resource> Aux/force-delete true
linstor r d <node> <resource>
```
After force-delete, rename the orphaned ZFS volume:
```bash
# On the node:
zfs rename data/<resource>_00000 data/<resource>_00000_FIX_TODO_REMOVE
```
WARNING: Force-delete can trigger CSI to delete the ResourceDefinition if all resources become flagged. Never force-delete the last replicas without asking the user first.

## Fix: Inconsistent Replica Blocking Others

If a stale `Inconsistent` replica is interfering with healthy copies:

```bash
linstor r deact <stale-node> <resource>
```

This removes it from the active DRBD graph. If `deact` reports errors but some peers adjusted successfully, that's often good enough. Check status after:

```bash
linstor r l -r <resource>
```

If `SyncTarget(n%)` appeared — recovery is already happening. Stop and let it finish.

## Fix: InUse + Diskless + StandAlone (Broken Diskless Attachment)

When a diskless consumer shows StandAlone:

```bash
linstor r td --diskless <consumer-node> <resource>
```

This re-runs the diskless attachment flow, forces LINSTOR to re-adjust peers and regenerate .res files. Very effective after mass incidents.

## Fix: PausedSyncS / resync-suspended:dependency

If you see `replication:PausedSyncS` and `resync-suspended:dependency`:

The problem is not in the paused peer — it's in a different connection in the graph. Reconnect to the Primary (source of truth) node:

```bash
drbdadm disconnect <resource>:<primary-node>
drbdadm connect <resource>:<primary-node>
```

## Fix: "Can not drop the bitmap" / "already has a bitmap"

DRBD kernel has bitmap for a peer that became diskless. The bitmap patch (if deployed) handles this automatically. If not:

```bash
# On the node where adjust fails:
drbdadm disconnect <resource>
drbdadm connect --discard-my-data <resource>

# On the other side:
drbdadm disconnect <resource>
drbdadm connect <resource>
```

For diskful nodes with persistent bitmap in metadata:
```bash
# Only if Unused and not Primary!
drbdadm secondary --force <resource>
drbdadm down <resource>
drbdadm -- --force forget-peer <resource>    # may not work in older drbdmeta
drbdadm up <resource>
```

Last resort (triggers full resync):
```bash
drbdadm secondary --force <resource>
drbdadm down <resource>
echo yes | drbdadm create-md --force <resource>
drbdadm up <resource>
```

## Fix: Stuck SyncTarget (Not Progressing)

```bash
# Try reconnect to the sync source:
drbdadm disconnect <resource>:<source-node>
drbdadm connect <resource>:<source-node>
```

If still stuck at 0%:
```bash
# Full restart (only if Unused!):
drbdadm down <resource>
drbdadm up <resource>
```

## Fix: Suspended I/O (quorum lost)

```bash
# Set quorum off via LINSTOR (persists through satellite restarts):
linstor rd sp <resource> DrbdOptions/Resource/quorum off

# Resume I/O:
drbdadm resume-io <resource>

# Fix connections, then restore quorum:
linstor rd sp <resource> DrbdOptions/Resource/quorum majority
```

If `resume-io` hangs due to stale lock:
```bash
rm -f /var/run/drbd/lock/drbd-*
drbdadm resume-io <resource>
```

If device is `suspended:user` + `open:yes` with no holder process — only a node reboot will fix it. Migrate VMs off the node first.

## Fix: False Diskless (LINSTOR says Diskless, DRBD is diskful)

This happens after force-delete removes CRD but satellite keeps DRBD running.

```bash
# Verify ZFS volume exists:
zfs list data/<resource>_00000

# Re-register as diskful:
linstor r mkavail --diskful <node> <resource>
```

## Fix: Dual-Primary

Dual-primary is NOT necessarily split-brain. If both are UpToDate and Connected, just demote one.

**If one of the Primaries is InUse (VM/pod actively using it):**
- ⚠️ **ASK the user before demoting the InUse Primary** — this will interrupt I/O for the running workload
- Prefer demoting the Unused Primary instead
- If both are InUse — ask the user which workload can tolerate interruption

```bash
# On the node that should become Secondary (prefer the Unused one):
drbdadm secondary --force <resource>
```

If they're StandAlone to each other — that's actual split-brain. Pick the source of truth and use `--discard-my-data` on the other.

## Fix: Node-ID Mismatch (Peer presented wrong node_id)

Check dmesg for `Peer presented a node_id of X instead of Y`:

```bash
# Migrate workload off affected nodes, then recreate broken replicas:
linstor r d <wrong-node-id-node> <resource>
linstor rd ap <resource>
```

## Fix: TCP Port Collisions

Two resources sharing the same TCP port on a node:
```bash
drbdadm adjust all 2>&1 | grep "is also used"
```

Fix via deactivate/activate cycle to get new ports:
```bash
linstor r deact <node> <resource>
# wait
linstor r act <node> <resource>
```

## Mass Incident Recovery Procedure

1. **Remove taints** if blocking pod scheduling: `kubectl taint node <node> drbd.linbit.com/lost-quorum-`
2. **Fix DELETING first** — they block other operations. Use deact+delete or force-delete.
3. **Fix StandAlone** — `disconnect` + `connect --discard-my-data` on secondary side, normal `connect` on primary side.
4. **Fix Connecting** — check error-reports, fix underlying cause (bitmap, port, peer down).
5. **Fix Inconsistent/Outdated** — should auto-sync once connections restored. If stuck, reconnect.
6. **Restore quorum** — `linstor rd sp <rsc> DrbdOptions/Resource/quorum majority`
7. **Verify** — `linstor r l --faulty` should show only SyncTarget resources.

Prioritize by presence of UpToDate replicas: resources with zero UpToDate copies need attention first.

## What NOT to Do

- **Never delete ZFS volumes directly** without verifying UpToDate replicas exist elsewhere
- **Never `drbdadm down` on Primary/InUse** — will hang or cause data loss
- **Never `--discard-my-data` on the only UpToDate copy**
- **Never continue active repair when SyncTarget is progressing**
- **Never treat every `DELETING` as something to immediately destroy** — some are mid-cleanup
- **Never try `drbdadm` commands on a resource that doesn't exist locally** — fix LINSTOR metadata instead
- **Never assume `Diskless` in LINSTOR means no data** — check ZFS and DRBD on the node
- **Never force-delete the last replica without cloning ZFS first**
- **Never use `linstor node lost`** — ask the user instead, this is too destructive for automated use
- **Never perform destructive operations (force-delete, discard-my-data, down on InUse) without asking the user for confirmation first**

## Known Upstream Bugs

1. **DRBD 9.2.16 bitmap race condition** — bitmap state corrupts during diskful→diskless transitions. Fixed in 9.2.17.
2. **ConfFileBuilder uses stale Resource flags** instead of DrbdRscData flags — generates `disk none` for diskful peers. Fix: PR #490.
3. **Toggle-disk doesn't preserve TCP ports** — `removeLayerData` frees ports, `ensureStackDataExists` allocates different ones. Fix: PR #476.
4. **CSI can delete ResourceDefinition while PVC is Bound** — if all resources have FlagDelete, CSI removes RD. Fix: linstor-csi PR #429.
5. **Talos TCP sysctl defaults** — `tcp_orphan_retries=0` causes connection floods under DRBD load. Fix: set `tcp_orphan_retries=3`, `tcp_fin_timeout=30`, `netdev_max_backlog=5000`.
