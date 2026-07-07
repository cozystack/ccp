---
name: talos-bootstrap
description: Bootstrap Talos Linux nodes into a Cozystack-ready cluster via talm. Default assumption is that the operator's nodes are already in Talos maintenance mode (the standard starting point — Talos boots from a nocloud/raw image and listens on :50000 awaiting machine-config). When that's the case the skill goes straight to `talm init` and `talm apply`, no OCI / PXE / ISO dance needed. When nodes are not yet imaged, the skill offers a boot-method picker (OCI Custom Image, PXE/iPXE, boot-to-talos, ISO) and walks the operator through getting them into maintenance mode first. Verifies the resulting cluster has the cozystack-tuned extensions (drbd, zfs, openvswitch) and the LVM filter before handing off to `cozystack:cluster-install`.
argument-hint: "[--config-dir=<path>] [--skip-boot-method] [--talos-version=<vX.Y.Z>] [--cozystack-repo=<path>] [--installer-profile-url=<url>]"
---

# cozystack:talos-bootstrap

Work in reasoning mode. Use the phrasing `cozystack:talos-bootstrap`. Announce phase transitions: `cozystack:talos-bootstrap Phase N — <name>`.

> **Note on language in this SKILL.md** — every operator-facing prompt below is written in English for clarity. At runtime the skill matches the operator's natural language detected from prior conversation messages (or read from `<config-dir>/.state.yaml` `operator_language` when the wizard chain is in progress). Treat the English text as a template for tone, structure, and content. Code identifiers, commands, file paths, and any text destined for GitHub stay canonical regardless of operator language.

## Core principles

- Match the operator's natural language. Read from `<config-dir>/.state.yaml` `operator_language` (set by `cozystack:wizard` Phase 0) or detect from prior messages when invoked directly. Use it in prompts, AskUserQuestion options, summaries, and gates. Code identifiers, commands, file paths, and GitHub-public text stay in their canonical form.
- One valid path → just do it. The skill executes `talm init` / `talm apply` / `talosctl bootstrap` / `talosctl kubeconfig` / verification automatically once Phase 5 (boot method) or Phase 4 (maintenance-mode probe) confirmed there's one valid forward direction. Gates remain for (a) multi-option choices (Phase 3 needs-help, Phase 5 boot method per provider, Phase 7 per-node review), (b) destructive operations (`talosctl reset` of an already-configured node), (c) the consolidated plan presentation. No "I'll wait for you to say done" gates — the skill verifies on its own schedule.
- Front-load the interview. **Every question the skill might ask in any phase is collected upfront**, before `talm init` runs: needs-OS-install (Phase 3), per-node boot method (Phase 5, for nodes the probe found unready), per-node install disk choice on multi-disk nodes, VIP for HA, custom installer schematic if not the default. Phases 1 (state) + 2 (workstation prep) + 4 (maintenance probe) are read-only lookups that run before any question fires. `intent_hints` from wizard Phase 0 pre-fills wherever it can. Phase 7 per-node review is one consolidated screen for all node configs, not one screen per node. Phases 6–12 then execute end-to-end without re-prompting.
- Layer-pure operator output. The skill never says "returning control to wizard", "the wizard will dispatch next", or any other orchestration commentary in the **operator-facing** summary. Whoever invoked the skill (a human running `/cozystack:talos-bootstrap` directly, or the wizard's dispatch loop) figures out what's next on their own — the wizard reads `.state.yaml` and decides; a human reads the printed `next:` hint at the bottom of the NOTES. Internal SKILL.md references to `cozystack:wizard` are fine for documentation, but `wizard` does not appear in any text shown to the operator.
- **Maintenance mode is the baseline.** Talos in maintenance mode is the standard entry point — listening on `:50000` awaiting machine-config. The skill drives `talm apply` directly against the maintenance API; no SSH, no OCI dance, no boot-to-talos invocation when nodes are already there. Only when nodes aren't imaged yet does the skill detour through a boot-method picker.
- Source of truth for everything Cozystack expects in Talos:
  - Tuned image: `ghcr.io/cozystack/cozystack/talos:vX.Y.Z` — read the pinned tag from the installer profile in this resolution order:
    1. `--installer-profile-url=<url>` override (rare; for testing).
    2. `--cozystack-repo=<path>/packages/core/talos/images/talos/profiles/installer.yaml` override.
    3. `~/git/github.com/cozystack/cozystack/packages/core/talos/images/talos/profiles/installer.yaml` default.
    4. URL fallback `https://raw.githubusercontent.com/cozystack/cozystack/<release>/packages/core/talos/images/talos/profiles/installer.yaml` when no local clone is present (`<release>` is the cozystack tag from `state.cozystack.installer_version` or the latest from `git ls-remote --tags https://github.com/cozystack/cozystack` if not set).
  - System extensions: drbd, zfs, openvswitch, plus firmware (amd-ucode / intel-ucode / intel-ice / etc.).
  - Kernel modules in machine-config: drbd, zfs, spl, openvswitch, vfio_pci, vfio_iommu_type1.
  - LVM filter in `/etc/lvm/lvm.conf`: `global_filter = [ "r|^/dev/drbd.*|", "r|^/dev/dm-.*|", "r|^/dev/zd.*|" ]`.
  - talm preset: `cozystack` chart from `~/git/github.com/cozystack/talm/charts/cozystack`.
- Verify before declaring success. A green Apply is not enough — `kubectl get nodes Ready`, talos extensions present, LVM filter present.

## Phase 1 — Read state

Read `<config-dir>/.state.yaml`. Required: `config_dir`. Optional: `inventory.nodes` (the wizard fills it), `intent_hints` (Phase 0 free-form context may have set boot-method hints).

When invoked outside a wizard chain, interview:

- Node IPs / hostnames + role (cp/worker). Minimum 1 cp; 3 cp for HA via embedded etcd raft.
- Are they already in Talos maintenance mode? — yes/no. If unsure, the skill helps probe (Phase 3).

Persist to `inventory.nodes`.

## Phase 2 — Workstation prep

Read-only checks on the operator's workstation:

```bash
talosctl version --client
talm version 2>/dev/null
```

- `talosctl` is required. If missing → `brew install siderolabs/tap/talosctl` or `https://github.com/siderolabs/talos/releases`; refuse.
- `talm` is required (the skill drives `talm init` + `talm apply`). If missing → `brew install cozystack/tap/talm` or the cozystack/talm releases page; refuse.

`boot-to-talos`, `helm`, `age` etc. only matter for specific boot methods; checked in Phase 4 if that path is taken.

## Phase 3 — Do you need help installing Talos?

Default assumption: Talos is already installed on the nodes — either the operator brought up the boxes themselves (their own image pipeline, an existing Talos cluster they're re-purposing) or they followed the cozystack docs for OCI / bare-metal / wherever and the nodes are now sitting in maintenance mode. The skill's primary job is `talm init` + `talm apply` against ready nodes; the OS-install detour is opt-in only.

Single AskUserQuestion:

```text
Is Talos already installed on the nodes and are they in maintenance mode? Or do you need help installing it?

  1. Already installed / I'll handle it — skip the boot-method picker.
     (Recommended — most scenarios. The skill goes straight to the
     maintenance-mode probe to confirm.)
  2. Need help installing the OS — skill walks through the boot-method
     picker (OCI Custom Image / boot-to-talos / ISO / PXE).
  3. Not sure — let me check first — skill runs the maintenance-mode
     probe (Phase 4) and decides based on the result, offering help
     if any node turns out unreachable.
```

If operator pre-filled `intent_hints.needs_os_install` in wizard Phase 0 (e.g. "I just have raw hardware, need to install Talos") → skip this question, pre-select option 2.

Record `state.talos.needs_os_install` (true / false / unsure).

## Phase 4 — Maintenance-mode probe (always run)

Regardless of Phase 3 answer, probe every node in inventory to ground-truth the state. The probe choice depends on Talos minor version because the insecure surface area changed between releases:

- **Talos 1.12** (the version cozystack v1.3.x pins): `talosctl version --insecure` returns `API is not implemented in maintenance mode` — looks like a fail but the node IS in maintenance. `get machineconfig --insecure` returns `PermissionDenied`. The only insecure-API surface that works reliably is `get disks` (read-only, machine-config-independent).
- **Talos 1.13+**: `get machineconfig --insecure` returns `PermissionDenied` (changed from 1.12's behaviour), but `version --insecure` works. `get disks --insecure` continues to work.

The single probe that works across Talos 1.12 / 1.13 / 1.14:

```bash
talosctl get disks --insecure --nodes "$NODE_IP" 2>&1 | head -5
# Maintenance mode (any Talos version) → returns disk list (NODE / NAMESPACE / TYPE / ID / VERSION / SIZE rows)
# Already configured                    → returns the same disk list (still works, but Phase 3 cross-check via talosctl with the cluster's talosconfig tells us if config is loaded)
# No route to host                      → not yet imaged or wrong IP
# Connection refused                    → port 50000 not open / wrong IP
```

If `get disks` returns rows, the node speaks the Talos API at port 50000 — that's the maintenance-mode signal. To distinguish "maintenance" from "already configured", try `get machineconfig --insecure` afterward — if it returns `NotFound` / `PermissionDenied` the node is in maintenance; if it returns the config, the node is already provisioned (refuse to overwrite without `--reset`).

Cross-check with `talosctl version --insecure --short` only on nodes you've already established are running Talos 1.13+ (e.g. via `get disks --insecure --node $IP --output yaml | yq '.spec.system_info.os_release'`).

Aggregate the matrix:

```text
maintenance-mode probe

  cp1 (10.0.0.10):   ✓ in maintenance mode (Talos vX.Y.Z, no config)
  cp2 (10.0.0.11):   ✓ in maintenance mode
  cp3 (10.0.0.12):   ✗ already configured — refuse to overwrite without --reset
  w1  (10.0.0.20):   ✗ unreachable (timeout) — node not yet imaged or wrong IP
```

Outcomes:

- **All nodes in maintenance mode** → Phase 5 boot-method picker is skipped entirely. Jump to Phase 6 (talm init). Operator's Phase 3 answer didn't matter — reality matched expectations.
- **Some nodes unreachable / not imaged**:
  - Phase 3 said `needs_os_install: false` → reconcile: "you said Talos is already installed, but cp3 isn't responding on :50000. Re-check IP / firewall / provider? Or do you actually want help installing on those nodes?". Operator picks: re-check (re-run Phase 4), help (jump to Phase 5 for those nodes), skip the node, or cancel.
  - Phase 3 said `needs_os_install: true` → Phase 5 boot-method picker for those nodes.
  - Phase 3 said `unsure` → ask explicitly now that we have data: help with these nodes or you'll handle them yourself?
- **Some nodes already configured** (not maintenance, not unreachable — fully running) → refuse for those nodes. Operator decides: `talosctl reset` to wipe (destroys data), skip the node from this install, or cancel. Never silently overwrite.

If `--skip-boot-method` was passed, refuse for any node not in maintenance mode — operator promised they're ready and the skill takes them at their word.

## Phase 5 — Boot method (only when help is needed) + consolidated intake

This is the **one** interview phase. After Phase 4 probe knows which nodes are ready and which aren't, the skill collects everything the rest of the flow needs in one pass and presents a consolidated summary. Later phases (talm init / talm apply / bootstrap / kubeconfig / verify) consume the collected answers without re-prompting.

Slots filled here:

- Per-node **boot method** (only for nodes the probe found unready). See provider tables below.
- Per-node **install disk** if the node has multiple candidates. Default is the largest unmounted disk; surface choice only on ambiguity.
- **VIP** for HA kube-apiserver if more than one CP node — operator-supplied or auto-detect from cloud LB if reachable.
- **Custom installer image** override (rare — default is the pinned cozystack-tuned tag from `~/git/github.com/cozystack/cozystack/packages/core/talos/images/talos/profiles/installer.yaml`).
- **Cluster name** for `talm init --endpoint` and the eventual `kubectl` context. Default from `state.intent_hints.cluster_name` or `cozystack-lab`.
- **Kubeconfig merge target** (when `<config-dir>/kubeconfig.yaml` already exists or operator wants merge into `~/.kube/config`).

After collecting, present the consolidated summary:

```text
cozystack:talos-bootstrap — collected values

inventory:
  cp1 (10.0.0.10):  maintenance ✓                        → talm apply (default disk: /dev/sda)
  cp2 (10.0.0.11):  maintenance ✓                        → talm apply (default disk: /dev/sda)
  cp3 (10.0.0.12):  unreachable                          → boot method: OCI Custom Image
  w1  (10.0.0.20):  maintenance ✓                        → talm apply (default disk: /dev/sda)

cluster:
  endpoint:          https://10.0.0.10:6443
  vip:               (none — single-CP would use cp1.host; with 3 CP set if desired)
  cluster name:      cozystack-lab
  installer image:   ghcr.io/cozystack/cozystack/talos:v1.13.0 (default)
  kubeconfig:        <config-dir>/kubeconfig.yaml  (will overwrite if exists — operator can pick merge instead)

options:
  - Approve all — proceed to Phase 6 (talm init) and then execute end-to-end
  - Edit <slot>
  - Cancel
```

Skip entirely when Phase 4 said all nodes are already in maintenance mode, OR Phase 3 said `needs_os_install: false` and Phase 4 didn't surface contradictions.

For nodes that need OS install, present per-provider options. The picker shape depends on `intent_hints.hardware_provider` from wizard Phase 0:

**OCI / Oracle Cloud Infrastructure**:

1. `OCI Custom Image (nocloud-amd64.raw.xz)` (Recommended) — operator downloads the `nocloud-amd64.raw.xz` from the cozystack-tuned release artefact, uploads to OCI Object Storage, imports as Custom Image, creates instances from it. The skill prints the artefact URL and the exact `oci` CLI commands; operator runs them. Once instances are launched and reach maintenance mode (typically 2–5 min), the skill re-runs Phase 3.
2. `OCI shape already running, just not configured` — operator already launched instances from a Custom Image; they're in maintenance mode now. Re-run Phase 3 — should turn green.
3. `PXE / iPXE / matchbox` — rarely the right choice on OCI; needs a bastion in the same VCN. Surface a warning and the matchbox-on-OCI guide link if the operator insists.

**Bare-metal**:

1. `boot-to-talos` (Recommended for existing-Linux nodes) — operator already has Linux on the box; replaces it in place. The skill prints the exact `boot-to-talos -image ghcr.io/cozystack/cozystack/talos:<tag> -disk /dev/sda -mode install` command.
2. `ISO / USB` — operator downloads `metal-amd64.iso` from the cozystack-tuned release, boots from it.
3. `PXE / iPXE / matchbox` — for racks; the skill points at matchbox docs.

**Other cloud (AWS / GCP / Azure / Hetzner / etc.)**:

1. Provider-specific Custom Image (AMI / disk image / etc.) — different artefact per cloud; skill names the right one and the upload procedure.
2. `Already-launched instance in maintenance mode` — see OCI option 2.

Per-node decisions go into `state.talos.boot_method.<node>`. The skill does **not** run the boot itself in v1 — operator runs the chosen path, then re-invokes the skill with `--skip-boot-method` once nodes are in maintenance mode.

## Phase 6 — talm init (generate cluster-wide secrets + config)

Run inside `<config-dir>` so all artefacts (`nodes/`, `secrets.yaml`, `talosconfig`) land alongside the rest of the cluster config:

```bash
cd "$CONFIG_DIR"

talm init \
  --preset cozystack \
  --endpoint "https://${CP1_IP}:6443" \
  --output-dir ./
```

The `cozystack` preset bakes in everything from the Source-of-truth list above (image, extensions, kernel modules, LVM filter). The operator does not edit those by hand.

`talm init` produces:

- `secrets.yaml` — cluster-wide PKI, encryption keys (sops-encrypted if `state.sops.enabled` is true via the shared `.sops.yaml`).
- `templates/` — per-resource Talos machine-config templates (the cozystack preset).
- `talosconfig` — talos client config to talk to the cluster post-bootstrap.
- `values.yaml` — the input values the templates render against. **This is where certSANs lives.**

Critically, `talm init` does **not** create `nodes/<name>.yaml` — those are operator inputs the skill assembles in Phase 6.5.

If `state.sops.enabled` is true, the `<config-dir>/.sops.yaml` from `cozystack:wizard` Phase 1.5 already covers `secrets.yaml` and `nodes/*.yaml`; talm respects it natively, no skill-side encrypt step needed.

## Phase 6.3 — NAT-provider cert-SAN guardrail (BEFORE first talm apply)

Skip when none of the NAT-provider signatures are present. The trigger is the same one Phase 4.5 research uses:

```
state.intent_hints.reach_mode == "public"
AND state.cozystack_intake.external_ips.strategy == "internal"
AND state.inventory.nodes[].public_ip is set on at least one node
```

This is the OCI / GCP-with-Cloud-NAT / AWS-with-EIP signature: the workstation reaches each node via a **public IP** that is rewritten by the cloud fabric to the node's **internal IP** before the packet hits the interface. The node's kernel — and Talos's machine-cert generator — only ever see the internal IP. After `talm apply`, Talos issues its API-server TLS certificate with `certSANs` populated from observed addresses: internal IPs + `127.0.0.1` + the explicit `--endpoint`. The workstation, dialing the public IP, gets a cert with no matching SAN. **TLS handshake fails. talosctl bootstrap cannot proceed. There is no insecure escape hatch.** Recovery from this point requires re-imaging the node — `talosctl reset` itself needs a valid TLS connection.

This trap caught the same operator twice in a row. It is now closed before the first `talm apply` runs.

Auto-populate `values.yaml` with the full certSANs set the workstation will need to dial:

```bash
# Collect from state.yaml
PUBLIC_IPS=$(yq '.inventory.nodes[] | select(.public_ip != null) | .public_ip' "$STATE_FILE")
INTERNAL_IPS=$(yq '.inventory.nodes[] | select(.internal_ip != null) | .internal_ip' "$STATE_FILE")
VIP=$(yq '.cluster.vip.shared_address // ""' "$STATE_FILE")
PER_NODE_VIPS=$(yq '.cluster.vip.per_node[]' "$STATE_FILE" 2>/dev/null || true)
API_HOST=$(yq '.cozystack_intake.publishing.host // ""' "$STATE_FILE")

# Merge, dedupe, sort
{
  printf '%s\n' "127.0.0.1" "localhost"
  printf '%s\n' $PUBLIC_IPS $INTERNAL_IPS $VIP $PER_NODE_VIPS
  [ -n "$API_HOST" ] && printf 'api.%s\n' "$API_HOST"
} | awk 'NF' | sort -u > /tmp/cert-sans.txt

# Patch values.yaml (yq edits in-place; preserves comments)
yq --inplace '
  .machine.certSANs = (load_str("/tmp/cert-sans.txt") | split("\n") | map(select(length > 0)))
' "$CONFIG_DIR/values.yaml"
```

Surface the result to the operator:

```text
talos-bootstrap — NAT-provider cert-SAN guardrail

  detected signature:  reach_mode=public + external_ips_strategy=internal
                       (OCI 1:1 NAT / GCP NAT / AWS EIP)

  auto-added to machine.certSANs:
    127.0.0.1
    localhost
    10.X.0.128                          # node0 internal
    10.X.0.27                           # node1 internal
    10.X.0.173                          # node2 internal
    10.X.100.10                         # VIP shared
    10.X.100.11 / 10.X.100.12 / 10.X.100.13    # per-node VIPs
    192.0.2.10 / 192.0.2.11 / 192.0.2.12        # workstation-visible public IPs
    api.cluster.example.com             # publishing.host

  why: without public IPs in certSANs, the workstation cannot reach the
  apiserver after talm apply — the cert is valid only for IPs the kernel
  sees, and the kernel never sees public IPs on NAT'd providers. Without
  the apiserver, talosctl bootstrap cannot complete, and there is no
  insecure escape from a wrong cert.
```

No gate — this is purely defensive. The operator can `--no-cert-san-guardrail` to opt out (e.g. they're using their own values.yaml with explicit SANs already).

If the trigger signature is **not** present (operator on bare-metal with the public IP actually on the interface, or reach_mode=internal), skip this entire phase silently.

## Phase 6.5 — Create per-node config stubs (modeline + body overlay)

`talm init` writes `templates/`, `secrets.yaml`, `values.yaml`, and `talosconfig` but **does not** create `nodes/<name>.yaml`. The skill creates them with both the modeline (which links to the rendering template) AND the body overlay (per-node values that get merged on top of the template render at `talm apply` time).

`talm template -f node.yaml [--in-place]` does **not** preserve body overlay — the output is the rendered template plus the modeline, byte-identical to what the template alone would produce on Talos 1.12+ multidoc format. Body overlay (HostnameConfig, per-node LinkConfig with static IPv4 on the VIP link, etc.) gets stripped. So **do not** run `talm template --in-place` to fill the stub. Write the body overlay directly:

```bash
mkdir -p "$CONFIG_DIR/nodes"

for node_idx in "${!INVENTORY_NODE_NAMES[@]}"; do
  node="${INVENTORY_NODE_NAMES[$node_idx]}"
  f="$CONFIG_DIR/nodes/${node}.yaml"
  [ -f "$f" ] && continue

  # Resolve per-node values from state
  per_node_vip=$(yq ".cluster.vip.per_node.${node} // \"\"" "$STATE_FILE")
  vip_link=$(yq '.cluster.vip.link // ""' "$STATE_FILE")
  shared_vip=$(yq '.cluster.vip.shared_address // ""' "$STATE_FILE")
  vip_subnet_mask=$(yq '.cluster.vip.subnet // ""' "$STATE_FILE" | sed 's|.*/||')

  cat > "$f" <<EOF
# talos-version: $TALOS_VERSION
# talm-template: ../templates
machine:
  install:
    # CVE-2026-53359: disable KVM nested virtualization (guest-to-host escape mitigation).
    # Lives under machine.install so talm re-applies it on every talm upgrade.
    extraKernelArgs:
    - kvm_intel.nested=0
    - kvm_amd.nested=0
---
apiVersion: v1alpha1
kind: HostnameConfig
metadata:
  name: $node
spec:
  hostname: $node
EOF

  # If this node carries a per-node VIP static, append the LinkConfig with addresses
  if [ -n "$per_node_vip" ] && [ -n "$vip_link" ]; then
    cat >> "$f" <<EOF
---
apiVersion: v1alpha1
kind: LinkConfig
metadata:
  name: $vip_link
spec:
  name: $vip_link
  addresses:
    - address: ${per_node_vip}/${vip_subnet_mask}
EOF
    # Add Layer2VIPConfig once for the cluster (only on the first CP node — that's CP1)
    if [ "$node_idx" = "0" ] && [ -n "$shared_vip" ]; then
      cat >> "$f" <<EOF
---
apiVersion: v1alpha1
kind: Layer2VIPConfig
metadata:
  name: $shared_vip
spec:
  link: $vip_link
  address: $shared_vip
EOF
    fi
  fi
done
```

This produces a Talos 1.12+ **multidoc** file. `talm apply -f node.yaml` correctly merges the body overlay on top of the template render — no `--in-place` step needed.

For Talos 1.11 and earlier (single-doc format), the skill emits the legacy `machine.network.interfaces[]` shape instead. Determined by `state.cluster.talos_version`.

## Phase 6.7 — VIP-link IPv4 guardrail (HA only, multidoc-aware)

Skip when the cluster is single-CP (no VIP). For multi-CP clusters with `state.cluster.vip.shared_address` set:

The check shape depends on machine-config format:

```bash
# Talos 1.12+ multidoc: VIP lives in Layer2VIPConfig doc, link static addresses
# live in LinkConfig doc. Both must exist for the VIP link on each CP node.
VIP_LINK="$(yq '.cluster.vip.link' "$STATE_FILE")"
export VIP_LINK

HAS_LINK_ADDRS=$(VIP_LINK="$VIP_LINK" yq '
  select(.kind == "LinkConfig" and .metadata.name == strenv(VIP_LINK))
  | .spec.addresses
' "$CONFIG_DIR/nodes/$NODE_NAME.yaml" | grep -c 'address:' || true)

if [ "$HAS_LINK_ADDRS" -eq 0 ]; then
  echo "GUARDRAIL: $NODE_NAME LinkConfig for $VIP_LINK has no addresses"
  exit 1
fi

# Talos 1.11 legacy single-doc check (only if state.cluster.talos_version <= 1.11)
yq '.machine.network.interfaces[] | select(.vip != null) | .addresses // []' \
  "$CONFIG_DIR/nodes/$NODE_NAME.yaml"
```

Why this matters: on cloud-provider VLAN secondaries (canonical case: OCI ens5 attached as VNIC secondary), maintenance mode brings the link `oper-state: up` but with no IPv4 in the VIP subnet. After `talm apply` only one node (the current VIP-holder) is reachable in the subnet — etcd join from the other CPs hangs in `Preparing` for 10+ minutes.

When triggered, refuse Phase 7 and surface:

```text
talos-bootstrap — VIP-link IPv4 guardrail

  node:       $NODE_NAME
  vip link:   $VIP_LINK  (carries shared VIP 10.X.100.10)
  problem:    nodes/$NODE_NAME.yaml has no LinkConfig.spec.addresses
              for $VIP_LINK — link will come up without an IPv4 in the
              VIP subnet, other CPs can't reach the VIP for etcd join.

  How to fix: Phase 6.5 should have populated this from state.cluster.vip.per_node.
  If empty, the wizard's Phase 4 intake didn't collect per-node VIP addresses.
  Re-run /cozystack:wizard --resume and answer the VIP intake question, OR
  edit nodes/$NODE_NAME.yaml manually to add the LinkConfig doc with addresses:

    ---
    apiVersion: v1alpha1
    kind: LinkConfig
    metadata:
      name: $VIP_LINK
    spec:
      name: $VIP_LINK
      addresses:
        - address: 10.X.100.12/24       # per-node IPv4 in the VIP subnet
```

If `state.cluster.vip.per_node[$node]` exists but the LinkConfig doc is missing, the skill auto-patches `nodes/$NODE_NAME.yaml` to add the doc and prints the diff for operator confirmation. If the source value is missing too, refuse and wait. Never `talm apply` with a missing VIP-link address — silent split-brain is worse than a stop-gate.

## Phase 7 — Per-node review (optional but recommended)

Present each `nodes/<name>.yaml` for review. Things to spot before apply:

- `machine.install.image` should be `ghcr.io/cozystack/cozystack/talos:<tag>`. The cozystack preset sets this; surface if missing.
- `machine.install.extraKernelArgs` should include `kvm_intel.nested=0` and `kvm_amd.nested=0` — the CVE-2026-53359 (Januscape) nested-virtualization guest-to-host escape mitigation. The Phase 6.5 overlay and the cozystack preset set these; surface if missing (e.g. an older preset).
- `machine.kernel.modules` should list drbd / zfs / spl / openvswitch / vfio_pci / vfio_iommu_type1.
- For CP nodes: `machine.type: controlplane`, optional `machine.network.interfaces[].vip` for HA.
- `machine.install.disk` defaults to a heuristic — confirm it picks the right system disk on multi-disk nodes (operator can edit nodes/<name>.yaml before apply).

Options:

- `Apply` — proceed to Phase 8. Skill applies to every node back-to-back without per-node prompts.
- `Edit <node>.yaml` — operator names a specific node, opens it in `$EDITOR`, returns; skill re-shows the relevant config slice and asks again.

The default is `Apply`. The per-node-approval path is gone — once the operator approved the config in this phase, every node gets `talm apply` in Phase 8 without a "ok for cp2?" intermission.

## Phase 8 — talm apply (push config to nodes in maintenance mode)

Per-node, drive talm against the maintenance API. **Always double-quote shell variables holding IPs / node lists** — `talosctl` and `talm` both pass `--nodes` as a space-separated list, so an unquoted `--nodes $IPS` with `IPS="1.2.3.4 5.6.7.8"` reads the second IP as a positional subcommand and fails with `unknown command 5.6.7.8`.

```bash
talm apply \
  --talosconfig "$CONFIG_DIR/talosconfig" \
  --insecure \
  --nodes "$NODE_IP" \
  --mode=auto \
  --file "$CONFIG_DIR/nodes/$NODE_NAME.yaml"
```

`--insecure` because the node is in maintenance mode without a cert yet. `--mode=auto` lets talm pick the safest reboot mode (try → staged → reboot). After first apply, every node reboots into the final configuration and is no longer in maintenance mode — but **the first reboot does not reinstall Talos** (see "version drift" in Phase 11). The message `talm` prints — `Applied configuration without a reboot` — is correct: talm applied live, no reboot needed; the on-disk image is replaced lazily on the next `talosctl upgrade`, not on this apply.

Capture talm's stdout/stderr verbatim. On any node failure, abort the batch (don't continue applying to other nodes — partial cluster is harder to debug than no cluster).

## Phase 9 — Bootstrap etcd (CP1 only, first time only)

After CP1 has applied its config and rebooted into the final configuration:

```bash
talosctl --talosconfig "$CONFIG_DIR/talosconfig" \
  --nodes "$CP1_IP" \
  bootstrap
```

This brings etcd online on CP1. Additional CPs (cp2, cp3) join automatically via the join token in the machine-config. Workers come up after the control plane is healthy.

Wait for the cluster to come up:

```bash
talosctl --talosconfig "$CONFIG_DIR/talosconfig" --nodes "$CP1_IP" \
  health --wait-timeout=15m
```

## Phase 10 — Fetch kubeconfig

```bash
talosctl --talosconfig "$CONFIG_DIR/talosconfig" \
  --nodes "$CP1_IP" \
  kubeconfig "$CONFIG_DIR/kubeconfig.yaml"

chmod 0600 "$CONFIG_DIR/kubeconfig.yaml"

# If sops is enabled, encrypt at rest.
if [ "$(yq '.sops.enabled // false' "$CONFIG_DIR/.state.yaml")" = "true" ]; then
  sops --encrypt --in-place "$CONFIG_DIR/kubeconfig.yaml"
fi
```

Verify:

```bash
KUBECONFIG="$CONFIG_DIR/kubeconfig.yaml" kubectl get nodes
# Expect every inventory node Ready, versions matching.
```

## Phase 11 — Verify cozystack-tuned shape

Use `talosctl` (via apid) — **not** `kubectl debug`. At end of `talos-bootstrap` there's no CNI yet (`cluster-install` installs Cilium); `kubectl debug node` will fail to schedule the debug pod. apid is always reachable on the nodes' Talos API port regardless of CNI state.

Three checks per node:

```bash
TALOSCONFIG="$CONFIG_DIR/talosconfig"
NODES=$(yq '.inventory.nodes[].host' "$CONFIG_DIR/.state.yaml" | paste -sd,)

# Modules — read /proc/modules from apid
talosctl --talosconfig "$TALOSCONFIG" --nodes "$NODES" \
  read /proc/modules \
  | awk '{print $1}' \
  | grep -Ex 'drbd|zfs|openvswitch'

# Cozystack-tuned extensions in the installer. talosctl streams one resource
# per line in jsonpath mode, so the kubectl-style {range} wrapper is not needed
# — but newline-separated output also means an empty stream silently passes
# a top-level `grep -E`. The per-extension `grep -qE` loop below catches that:
# every expected extension must produce at least one match, otherwise exit 1.
talosctl --talosconfig "$TALOSCONFIG" --nodes "$NODES" \
  get extensions --output jsonpath='{.spec.metadata.name}' \
  | sort -u \
  | tee /tmp/talos-ext.list

for want in drbd zfs openvswitch; do
  grep -qE "(^|/)${want}\$" /tmp/talos-ext.list \
    || { echo "missing extension: ${want}"; exit 1; }
done

# LVM filter
talosctl --talosconfig "$TALOSCONFIG" --nodes "$NODES" \
  read /etc/lvm/lvm.conf \
  | grep -E '^\s*global_filter\s*=' \
  | grep -E 'drbd|zd|dm-'

# Talos version uniformity — straight from apid
talosctl --talosconfig "$TALOSCONFIG" --nodes "$NODES" \
  version --short \
  | grep -E '^Tag:' | sort -u
```

If any check fails, the skill **does not silently mark `failed_at`** — it tries to reconcile via Phase 11.5 auto-upgrade first (the most common cause of missing extensions is operator-booted-from-base-Talos-image instead of cozystack-tuned). Only after Phase 11.5 fails does the skill write `status.talos-bootstrap.failed_at`. `cluster-install` will refuse a Talos cluster missing extensions.

## Phase 11.5 — Auto-upgrade to cozystack-tuned image (when Phase 11 fails on extensions/drift)

Triggered when Phase 11 detected one of:

- missing extensions (`drbd`, `zfs`, or `openvswitch` not in `talosctl get extensions`)
- running Talos version != pinned image version
- running image != cozystack-tuned (`ghcr.io/cozystack/cozystack/talos:*`)

All three have the same root cause: nodes booted from a non-cozystack-tuned image (operator imported base Talos `nocloud-amd64.raw.xz` from the upstream Talos releases instead of the cozystack-tuned `nocloud-amd64.raw.xz` from cozystack releases; or boot-to-talos used its hardcoded default image; or somebody hand-edited a node config). `talm apply` does not reinstall Talos — the pinned `machine.install.image` only takes effect on the next `talosctl upgrade`. Phase 11.5 runs that upgrade.

Resolve the pinned image:

```bash
PINNED_IMAGE=$(yq '.machine.install.image' "$CONFIG_DIR/nodes/$CP1_NAME.yaml")
# Sanity check: must be a cozystack-tuned image
case "$PINNED_IMAGE" in
  ghcr.io/cozystack/cozystack/talos:*) ;;
  *) echo "REFUSE: pinned image $PINNED_IMAGE is not cozystack-tuned"; exit 1 ;;
esac
```

Surface the plan to the operator (this is a STOP GATE — `talosctl upgrade` is a per-node reboot):

```text
talos-bootstrap — Phase 11.5 auto-upgrade to cozystack-tuned

  reason:
    Phase 11 detected the running nodes are not on the cozystack-tuned
    image. This happens when nodes booted from base Talos (e.g. OCI Custom
    Image of upstream Talos vX.Y.Z) instead of the cozystack-tuned
    artefact. talm apply did NOT reinstall — the pinned image only takes
    effect on the next upgrade.

  current state:
    node0  running base Talos v1.12.6     pinned ghcr.io/cozystack/cozystack/talos:v1.12.6
    node1  running base Talos v1.12.6     pinned ghcr.io/cozystack/cozystack/talos:v1.12.6
    node2  running base Talos v1.12.6     pinned ghcr.io/cozystack/cozystack/talos:v1.12.6
    extensions missing: drbd, zfs, openvswitch

  plan:
    Per-node, sequentially (not parallel — preserves cluster availability):
      talosctl --talosconfig <talosconfig> --nodes <node-ip> upgrade \
        --image $PINNED_IMAGE --preserve

    --preserve keeps user disks (any zfs pool stays). Each node reboots
    once into the cozystack-tuned image. Total ~3 min × 3 nodes = ~9 min.
    etcd quorum maintained (one node down at a time).

  options:
    - Proceed (Recommended — required for cluster-install to accept this Talos cluster)
    - Skip and fail Phase 11.5 — manual recovery needed
    - Cancel
```

On `Proceed`, run per-node:

```bash
for node_ip in $(yq '.inventory.nodes[].host' "$STATE_FILE"); do
  talosctl --talosconfig "$TALOSCONFIG" --nodes "$node_ip" upgrade \
    --image "$PINNED_IMAGE" --preserve --wait

  # Wait for the node to come back Ready (post-reboot, the kubeconfig context is valid).
  kubectl --context "$CTX" wait --for=condition=Ready "node/$(yq ".inventory.nodes[] | select(.host == \"$node_ip\") | .name" "$STATE_FILE")" --timeout=5m
done
```

After all nodes upgraded, re-run Phase 11 verification (recursively, max once). If it still fails, the cause is something other than image mismatch — write `failed_at` and surface the verification output.

If the operator picks `Skip` — write `failed_at: "phase-11.5-skipped"` and exit. `cluster-install` Phase 3 will refuse.

### Talos version drift across nodes (sanity, not the upgrade trigger)

After Phase 11.5 settles, verify uniformity across all CP nodes' configs — if a hand-edit drifted one node, surface it:

```bash
for node_yaml in "$CONFIG_DIR/nodes/"*.yaml; do
  this_image=$(yq '.machine.install.image' "$node_yaml")
  [ "$this_image" != "$PINNED_IMAGE" ] && \
    echo "WARN: $(basename "$node_yaml") pins $this_image (expected $PINNED_IMAGE)"
done
```

This is informational — the per-node hand-edit case is rare and the operator owns it.

## Phase 12 — Write state and hand off

```yaml
cluster:
  context: <CTX>
  kubeconfig: <config-dir>/kubeconfig.yaml
  api_endpoint: https://<CP1_IP>:6443
  distribution: talos
  k8s_version: <FROM_KUBECTL_VERSION>
  talos_version: <FROM_TALOSCTL_VERSION>
status:
  talos-bootstrap:
    completed_at: <ISO_TS_UTC>
    talosconfig: <config-dir>/talosconfig
```

NOTES:

```text
cozystack:talos-bootstrap — ready

cluster:
  context:        <CTX>
  api:            https://<CP1_IP>:6443
  nodes:          <N> Talos $TALOS_VERSION (cozystack-tuned)
  extensions:     drbd ✓  zfs ✓  openvswitch ✓
  lvm filter:     ✓

artifacts under <config-dir>:
  nodes/*.yaml        # per-node machine-config — sops-encrypted in-tree when sops on, plain (safe to commit) when off
  secrets.yaml        # cluster PKI bundle — sops-encrypted in-tree when sops on, gitignored when off
  talosconfig         # talos client config — sops-encrypted in-tree when sops on, gitignored when off
  kubeconfig.yaml     # k8s client config — sops-encrypted in-tree when sops on, gitignored when off
  talm.key            # RECOVERY KEY — talm's own encryption layer over secrets.yaml.
                      # back up SEPARATELY (password manager or air-gapped store).
                      # without it, secrets.encrypted.yaml is unrecoverable —
                      # losing it equals losing the cluster's PKI.

next: invoke /cozystack:cluster-install — it will resume from <config-dir>/.state.yaml
```

After Phase 12 surface a one-line reminder above the NOTES block:

```text
recovery key: <config-dir>/talm.key — back this up SEPARATELY before
anything else. It is not encrypted by sops; losing it means
secrets.encrypted.yaml cannot be decrypted, and the cluster's PKI
cannot be regenerated without re-bootstrapping the whole cluster.
```

## Guardrails

- NEVER `talm apply` on a node that's not in maintenance mode. Phase 4 probe catches this; on `--reset` from the operator the skill `talosctl reset`s explicitly with approval and a clear data-loss warning. Default refusal stands.
- NEVER skip Phase 11 verification — Cozystack expects the cozystack-tuned shape; an un-verified Talos cluster will fail in `cluster-install` Phase 3 anyway.
- NEVER cache the cozystack-tuned image tag — read it from the upstream installer profile each run.
- NEVER write `cluster.kubeconfig` to a path that already exists without offering rename / merge.
- ALWAYS run `talm init` (Phase 6), `talm apply` (Phase 8), `talosctl bootstrap` (Phase 9), `talosctl kubeconfig` (Phase 10), and the verification probes (Phase 11) automatically once the operator approved the plan in Phase 5 (boot method) or confirmed all nodes are in maintenance mode in Phase 4. There is no separate "operator says done" gate between these phases — it's one valid path forward, the skill executes it.
- ALWAYS write artefacts under `<config-dir>/`. nodes/, secrets.yaml, talosconfig, kubeconfig all live there.
- ALWAYS respect `.sops.yaml` when it exists — talm reads it natively for secrets.yaml and nodes/*.yaml; the skill encrypts kubeconfig.yaml manually after fetch.

## References

- `references/manual-steps.md` — boot-method-specific commands per provider (OCI Custom Image, bare-metal ISO / boot-to-talos / PXE) for Phase 4.

External:

- `https://cozystack.io/docs/v1.3/install/talos/` — primary install guide.
- `https://github.com/cozystack/talm` — talm chart + cozystack preset.
- `https://github.com/cozystack/boot-to-talos` — one-step replace-existing-OS helper.
- `https://factory.talos.dev/` — Talos Image Factory (for custom schematics if the cozystack-tuned image doesn't fit).
- `~/git/github.com/cozystack/cozystack/packages/core/talos/` — source of the OCI image build pipeline + extension list.
