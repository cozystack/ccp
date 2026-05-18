---
name: talos-reset
description: Cloud-provider recovery helper for Talos nodes in an unrecoverable state. Use when the API-TLS handshake is broken (cert-SAN trap caught before the guardrail, broken machine-config, lost talosconfig, accidental wipe). Wraps the provider CLI (oci / aws / gcloud / hcloud) to terminate the instance, preserve attached block volumes, VLAN/secondary VNIC attachments, NSG rules, then relaunch from the same cozystack-tuned image, re-attach the disks + VNICs, and hand the freshly-bootstrapped nodes back to `cozystack:talos-bootstrap` for re-bootstrap from maintenance mode. Does NOT touch already-installed Cozystack — that's `cozystack:debug` territory. Read-only against any cluster; mutations only via the provider CLI with explicit per-node operator approval.
argument-hint: "[--config-dir=<path>] [--provider=oci|aws|gcp|hetzner] [--nodes=<name1,name2,...>] [--preserve-disks] [--preserve-vnics]"
---

# cozystack:talos-reset

Work in reasoning mode. Use the phrasing `cozystack:talos-reset`. Announce phase transitions: `cozystack:talos-reset Phase N — <name>`.

> **Note on language in this SKILL.md** — every operator-facing prompt below is written in English for clarity. At runtime the skill matches the operator's natural language detected from prior conversation messages (or read from `<config-dir>/.state.yaml` `operator_language` when the wizard chain is in progress). Code identifiers, commands, file paths, and any text destined for GitHub stay canonical regardless of operator language.

## When to use this skill

Use `cozystack:talos-reset` when **none** of the in-cluster paths work:

- `talosctl reset` requires a valid TLS handshake — useless when cert-SAN is wrong, talosconfig is lost, or `apid` doesn't trust the workstation.
- `talosctl upgrade --image <X>` needs the same TLS path.
- `kubectl drain` + `kubectl delete node` only works if `kube-apiserver` is reachable.
- A cluster that never reached bootstrap (`talosctl bootstrap` failed) has no etcd, no apiserver, no kubectl path at all.

When none of those apply, the node has to be re-imaged at the cloud-provider layer: terminate the instance, preserve the disks (so a re-bootstrap with `--preserve` keeps the zpool), and relaunch from the cozystack-tuned image. This skill orchestrates that without losing the operator's existing block volumes, VNIC attachments, or NSG rules.

**Not for**:

- Cozystack-side problems (HRs failing, dashboard unreachable, certs not issuing) → use `cozystack:debug`.
- Talos upgrades on a healthy cluster → use `talosctl upgrade --preserve` directly; no need for cloud-provider intervention.
- Fresh installs with no pre-existing state → use `cozystack:wizard` → `cozystack:talos-bootstrap`.

## Core principles

- Match the operator's natural language. Read `<config-dir>/.state.yaml` `operator_language` if available, detect otherwise.
- Provider CLI is the operator's tool. The skill prints exact `oci`, `aws`, `gcloud`, or `hcloud` commands; the operator runs them. The skill never directly invokes the provider CLI without operator approval — every mutation is shown first.
- Preserve by default. `--preserve-disks` and `--preserve-vnics` default true. The skill explicitly lists what it will preserve and what gets recreated.
- Layer-pure operator output. The skill never says "returning control to wizard" — whoever invoked the skill figures out next steps from the printed NOTES.
- One node at a time. Sequential terminate+relaunch preserves etcd quorum on 3+ CP clusters. For total cluster recovery (all CPs broken), the skill walks the operator through losing+regaining quorum explicitly.
- Verify before declaring success. Post-relaunch the node must reach Talos maintenance mode (port 50000 responds to `talosctl get disks --insecure`) AND retain the preserved disks (existing zpool surfaced by `talosctl get disks`).

## Phase 1 — Read state and scope

Read `<config-dir>/.state.yaml`. Required: `config_dir`, `inventory.nodes` (with per-node `public_ip` / `internal_ip` / `name`), `intent_hints.platform`. If invoked without a state file (operator hand-bootstrapped, never used the wizard), interview:

- Provider (`oci` / `aws` / `gcp` / `hetzner`).
- Node list with provider-specific IDs (OCI: instance OCIDs; AWS: instance IDs; GCP: instance names + zone; Hetzner: server numbers).
- For each node: which block volumes / VNICs / NSG attachments to preserve.

If `--nodes` was passed, scope to that subset; otherwise scope to **all** nodes that match the failure signature (operator describes the symptom, skill infers which nodes are affected).

Persist scope to `state.talos_reset.scope`.

## Phase 2 — Workstation prep

Verify the relevant provider CLI is installed and authenticated:

```bash
# OCI
oci --version && oci iam region list --output table

# AWS
aws --version && aws sts get-caller-identity

# GCP
gcloud --version && gcloud auth list --filter=status:ACTIVE

# Hetzner
hcloud version && hcloud context list
```

Refuse for any provider where the CLI is missing or not authenticated — point the operator at the install instructions. Do not attempt to wrap with `gh auth login` / `oci setup` / `aws configure` — credential setup is operator territory.

## Phase 3 — Snapshot current cloud state

Before terminating anything, capture the **exact** current state of every in-scope node so re-attach in Phase 6 can restore it:

```bash
# Example: OCI
oci compute instance get --instance-id "$OCID" > "$CONFIG_DIR/talos-reset/$NODE_NAME/instance.json"
oci compute volume-attachment list --instance-id "$OCID" \
  > "$CONFIG_DIR/talos-reset/$NODE_NAME/volume-attachments.json"
oci compute vnic-attachment list --instance-id "$OCID" \
  > "$CONFIG_DIR/talos-reset/$NODE_NAME/vnic-attachments.json"
# Network security group memberships — fetched per-VNIC
for vnic_ocid in $(jq --raw-output '.data[].id' < "$CONFIG_DIR/talos-reset/$NODE_NAME/vnic-attachments.json"); do
  oci network vnic get --vnic-id "$vnic_ocid" \
    > "$CONFIG_DIR/talos-reset/$NODE_NAME/vnic-${vnic_ocid##*.}.json"
done
```

Equivalent shapes for AWS / GCP / Hetzner — see `references/provider-cli.md` for the verbatim command sets.

The snapshot directory `<config-dir>/talos-reset/<node-name>/` becomes the source of truth for Phase 6. Operator can audit `cat instance.json | jq '.data.shape'` before approving any destructive step.

## Phase 4 — Present the reset plan (STOP GATE 1)

Surface the consolidated plan in a single screen:

```text
cozystack:talos-reset — plan

  provider:   oci
  scope:      3 nodes (all CPs)
  signature:  cert-SAN trap detected — workstation cannot reach apiserver

  per-node plan (sequential, etcd quorum maintained: 2/3 stay up while 1 resets):

    node0 (instance ocid1.instance.oc1.iad.abc123)
      preserve:   block volume ocid1.volume.oc1.iad.xyz789  (254 GiB, zpool 'data')
                  secondary VNIC ocid1.vnic.oc1.iad.def456  (VLAN 4000, VIP-link static 10.X.100.11)
                  NSG memberships  cozystack-cp (2 rules: 6443/tcp, 50000/tcp)
      terminate:  oci compute instance terminate --instance-id <OCID> --preserve-boot-volume false
                  ↑ deletes ephemeral boot disk; data disk above is preserved separately
      relaunch:   oci compute instance launch \
                    --shape VM.Standard3.Flex --shape-config '{...}' \
                    --image-id <COZYSTACK_TUNED_IMAGE_OCID> \
                    --launch-mode PARAVIRTUALIZED \
                    --availability-domain <AD> --subnet-id <PRIMARY_SUBNET> \
                    --hostname-label node0 \
                    ...
      reattach:   oci compute volume-attachment attach \
                    --instance-id <NEW_OCID> --volume-id <PRESERVED_VOLUME_OCID> --type iscsi
                  oci compute vnic-attachment create \
                    --instance-id <NEW_OCID> --create-vnic-details file://vnic-secondary.json
      verify:     wait until 'talosctl get disks --insecure --nodes <NEW_PUBLIC_IP>' returns
                  AND existing zpool 'data' visible in disk list

    node1: <same shape>
    node2: <same shape>

  what gets lost:
    - ephemeral boot volume (Talos rootfs — replaced from cozystack-tuned image)
    - any public IP NOT covered by a Reserved IP (OCI ephemeral IPs change on relaunch;
      Phase 4.5 NAT-signature research in the next bootstrap will re-derive certSANs
      from the NEW public IPs — old certs are discarded with the boot volume anyway)

  what gets preserved:
    - data block volumes (and the zpool on them — re-bootstrap with --preserve)
    - secondary VNIC attachments (VLAN VIP-link static IPs survive)
    - NSG memberships
    - block-volume IQN/auth — re-attach uses the same volume OCID

  options:
    - Proceed (sequential, ~5 min per node, ~15 min total for 3 nodes)
    - Edit plan — pick a different subset of nodes / preserve options
    - Cancel
```

`Proceed` is the gate; the skill does NOT auto-execute any provider CLI until this answer.

## Phase 5 — Terminate (per node, sequential)

For each in-scope node, in inventory order:

```bash
# 1. (CP only on multi-CP clusters) drain the node from the cluster's perspective if apiserver still works
if kubectl --context "$CTX" get node "$NODE_NAME" 2>/dev/null | grep -q Ready; then
  kubectl --context "$CTX" drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --timeout=120s || true
  kubectl --context "$CTX" delete node "$NODE_NAME" || true
fi

# 2. Terminate the instance, NOT preserving the boot volume
oci compute instance terminate \
  --instance-id "$OCID" \
  --preserve-boot-volume false \
  --force
```

Wait for instance state to reach `TERMINATED` before proceeding:

```bash
until [ "$(oci compute instance get --instance-id "$OCID" \
            --query 'data."lifecycle-state"' --raw-output 2>/dev/null)" = "TERMINATED" ]; do
  sleep 10
done
```

Surface termination confirmation explicitly — operator sees the lifecycle transition before relaunch starts.

## Phase 6 — Relaunch + reattach (per node)

```bash
# 1. Launch a new instance from the cozystack-tuned Custom Image
NEW_OCID=$(oci compute instance launch \
  --shape "$SHAPE" --shape-config "$SHAPE_CONFIG" \
  --image-id "$COZYSTACK_TUNED_IMAGE_OCID" \
  --launch-mode PARAVIRTUALIZED \
  --availability-domain "$AD" \
  --subnet-id "$PRIMARY_SUBNET" \
  --hostname-label "$NODE_NAME" \
  --metadata "$METADATA" \
  --query 'data.id' --raw-output)

# 2. Wait for RUNNING + maintenance mode reachable
until [ "$(oci compute instance get --instance-id "$NEW_OCID" --query 'data."lifecycle-state"' --raw-output)" = "RUNNING" ]; do
  sleep 10
done

# 3. Discover the NEW public IP and update state
NEW_PUBLIC_IP=$(oci compute instance list-vnics --instance-id "$NEW_OCID" \
  --query 'data[0]."public-ip"' --raw-output)
yq --inplace ".inventory.nodes[] |= select(.name == \"$NODE_NAME\") .public_ip = \"$NEW_PUBLIC_IP\"" "$STATE_FILE"

# 4. Re-attach preserved data volume
oci compute volume-attachment attach \
  --instance-id "$NEW_OCID" \
  --volume-id "$PRESERVED_VOLUME_OCID" \
  --type iscsi --wait-for-state ATTACHED

# 5. Re-attach secondary VNIC (carries VIP-link static IPv4)
oci compute vnic-attachment create \
  --instance-id "$NEW_OCID" \
  --create-vnic-details file://"$CONFIG_DIR/talos-reset/$NODE_NAME/vnic-secondary.json"
```

Provider-specific equivalents documented in `references/provider-cli.md`.

## Phase 7 — Verify maintenance mode + preserved disks

```bash
# Talos API responds (port 50000) — get disks works on Talos 1.12+ in maintenance
until talosctl get disks --insecure --nodes "$NEW_PUBLIC_IP" 2>&1 | head -3; do
  echo "waiting for $NEW_PUBLIC_IP to reach maintenance mode..."
  sleep 20
done

# Verify the preserved data disk + existing zpool are visible
talosctl get disks --insecure --nodes "$NEW_PUBLIC_IP" --output yaml \
  | yq 'select(.spec.size > 100000000000)'   # filter for the data disk by size
# Expect: /dev/sdb with the zpool-signature recognisable. Talos doesn't auto-mount user disks,
# so the zpool isn't imported — that's fine, talos-bootstrap Phase 8 + cluster-install Phase 5.5
# pre-existing-data check handles import.
```

If the preserved zpool data is gone (volume re-attached but blank), abort and surface — operator's preserved volume OCID was wrong, do NOT continue with the remaining nodes.

## Phase 8 — Update state and hand off

Write to `<config-dir>/.state.yaml`:

```yaml
talos_reset:
  scope: ["node0", "node1", "node2"]
  completed_at: <ISO_TS_UTC>
  preserved:
    - node: node0
      volume: ocid1.volume.oc1.iad.xyz789
      vnics: ["ocid1.vnic.oc1.iad.def456"]
    - ...
  ip_changes:
    - node: node0
      old_public_ip: 198.51.100.10
      new_public_ip: 198.51.100.42
status:
  talos-reset:
    completed_at: <ISO_TS_UTC>
```

Reset `status.talos-bootstrap` and `status.cluster-install` — those skills will need to re-run, but they should NOT re-do the heavy work on what's already on disk (zpool exists, talm.key + secrets.yaml exist):

```yaml
status:
  talos-bootstrap:
    dispatched_at: null
    completed_at: null
    failed_at: null
  cluster-install:
    # left untouched if cluster-install had already run — its post-install state lives in the cluster,
    # not on disk; after re-bootstrap the kubeconfig will reach the recovered cluster
    ...
```

## Phase 9 — NOTES + handoff

```text
cozystack:talos-reset — complete

  reset:        3 nodes (node0, node1, node2)
  duration:     14 min
  preserved:    block volumes + secondary VNICs intact
  ip changes:   node0 198.51.100.10 → 198.51.100.42
                node1 198.51.100.11 → 198.51.100.43
                node2 198.51.100.12 → 198.51.100.44

  state updates:
    inventory.nodes[*].public_ip   — updated to new public IPs
    status.talos-bootstrap         — reset (will re-run)

next: invoke /cozystack:talos-bootstrap — it will detect maintenance mode
      on the new instances, skip the boot-method picker, run talm init +
      apply against the recovered nodes. zpool 'data' will be picked up
      by cluster-install Phase 5.5 pre-existing-data check (no wipe needed).
```

## Guardrails

- NEVER call any provider CLI mutation without operator approval. The skill prints the exact command and waits for `Proceed`.
- NEVER terminate more than one node at a time on multi-CP clusters — etcd quorum requires ⌈N/2⌉+1 nodes up. Sequential reset preserves quorum.
- NEVER assume the new public IP equals the old. OCI / AWS / GCP ephemeral IPs change on relaunch unless a Reserved IP / EIP is in use. The skill updates `state.inventory.nodes[*].public_ip` from the new instance's actual VNIC data.
- NEVER reset a node whose data volume isn't part of a preserved volumes list — accidentally wiping a zpool is unrecoverable from this skill.
- NEVER touch in-cluster state (HelmReleases, namespaces, ConfigMaps). Cozystack-side problems are `cozystack:debug` territory.
- ALWAYS verify the preserved disk is intact AND the new instance reaches maintenance mode before continuing to the next node in the batch.
- ALWAYS surface what changes between old and new instance (public IP, instance OCID, anything else operator-visible).

## References

- `references/provider-cli.md` — verbatim CLI command sets per provider (oci / aws / gcloud / hcloud) for terminate, launch, volume-attach, vnic-attach.

Cross-references:

- `/cozystack:wizard` — the orchestrator. If `talos-reset` completed, wizard's `--resume` will re-dispatch `talos-bootstrap` and pick up from there.
- `/cozystack:talos-bootstrap` — re-bootstrap entry point post-reset.
- `/cozystack:debug` — for in-cluster failures that don't require cloud-layer reset.
