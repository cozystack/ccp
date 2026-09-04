# Talos / node OS upgrade (DRBD-aware rolling)

Read this when a Cozystack upgrade also moves the underlying **Talos OS** or **Kubernetes** version — the main `cluster-upgrade` flow only covers the `cozy-installer` Helm upgrade. Node upgrades are a **separate, node-by-node procedure**, and on DRBD/LINSTOR-backed clusters the sequencing is what keeps VMs alive.

## Where it fits in the upgrade order

When a release bumps Talos, treat each layer as its own window and run them in this order:

1. **Talos OS** — one node at a time (this file).
2. **Kubernetes** — per the release notes (control-plane first).
3. **Cozystack platform** — the Helm flow in the main skill.

Rationale: some fixes ship only in the newer Talos extension bundle (e.g. a DRBD kernel-module fix), so the OS bump has to land first. Talos pins every extension to its release branch — you **cannot** ship a newer DRBD without moving the Talos minor. Check the DRBD version a Talos release carries before planning: `release-1.12` ships DRBD 9.2.16, `release-1.13` ships 9.3.2.

## The one rule that prevents outages

**One node at a time — and never start the next node until the just-upgraded node's DRBD resources are back `UpToDate`.**

DRBD replicates each volume across a small number of nodes (often 2–3). Rebooting a node takes its replicas offline; the volume keeps quorum from the survivors. Reboot a **second** replica-holding node before the first finished resyncing and the volume loses quorum → I/O suspends → every VM on it stalls. The resync wait is not optional.

## Pre-flight (storage must be clean)

```bash
alias linstor='kubectl --context $CTX exec -n cozy-linstor deploy/linstor-controller -ti -- linstor'
linstor node list                 # every node Online
linstor resource list --faulty    # empty
linstor storage-pool list         # no Err
# no lost-quorum taints stuck on any node:
kubectl --context $CTX get nodes -o json \
  | jq -r '.items[] | select(.spec.taints[]?.key=="drbd.linbit.com/lost-quorum") | .metadata.name'
```

Any faulty resource, pending resync, or lost-quorum taint blocks the upgrade — fix it first (the `linstor:recover` skill covers the recovery paths).

## Per-node loop

Do control-plane nodes first (one at a time, so etcd quorum holds), then storage/worker nodes one at a time.

```bash
NODE=<node-name>

# 1. Cordon
kubectl --context $CTX cordon "$NODE"

# 2. Drain — live-migrate VMs off, respect PDBs.
#    KubeVirt VMs with evictionStrategy=LiveMigrate migrate on drain; ones without
#    it are stopped instead, so check before draining a node that hosts VMs.
kubectl --context $CTX get vmi -A --field-selector status.nodeName="$NODE"
kubectl --context $CTX drain "$NODE" --ignore-daemonsets --delete-emptydir-data

# 3. Upgrade Talos. talm resolves the installer image from values.yaml::image —
#    bump that to the target release first, then:
talm upgrade -f nodes/"$NODE".yaml
#    talm's post-upgrade verify gate confirms the node booted the new version
#    (catches the silent A/B rollback case). Do NOT pass --skip-post-upgrade-verify.

# 4. Wait for the node to come back Ready
kubectl --context $CTX wait --for=condition=Ready node/"$NODE" --timeout=15m

# 5. WAIT FOR DRBD RESYNC on this node before touching the next one.
#    All resources back UpToDate, nothing SyncTarget / Inconsistent / Connecting:
linstor resource list --faulty    # must be empty again
linstor exec -- drbdsetup status | grep -E 'SyncTarget|Inconsistent|Connecting' || echo clean

# 6. Uncordon
kubectl --context $CTX uncordon "$NODE"
```

Only after step 5 reports clean do you move to the next node. Large volumes can take a while to resync — that wait is the whole point.

## After a node reboots: watch for the auto-diskful pause

A VM that restarts onto a node **without a local replica** opens its disk *diskless*, and LINSTOR `auto-diskful` may then convert it to *diskful* under the running VM. On DRBD 9.2.16 (Talos ≤ 1.12) that online toggle can leave the VM in a `PausedIOError` loop — see `known-failures.md` #8. Two ways to shrink the exposure during a node-upgrade window:

- Prefer scheduling VMs onto nodes that already hold a replica (volume affinity), or run enough replicas that most nodes have a local copy — fewer diskless opens, fewer live toggles.
- If a VM does get stuck, `virtctl restart <vm>` reopens the device cleanly.

## Rollback

Talos upgrades are A/B: a failed boot rolls back to the previous partition automatically, and talm's post-upgrade verify catches the silent-rollback case. There is no "roll the whole cluster back" step — you fix the one node and re-run. Never proceed to the next node while any node is on the wrong version or any resource is still resyncing.
