---
name: cluster-install
description: Use when installing Cozystack on an existing Kubernetes cluster (kubeadm / k3s / RKE2 / managed). Discovers cluster facts, validates node readiness via kubectl debug, recommends an installer + platform variant, gathers values interactively, creates the ZFS pool on each storage node through kubectl debug (cozystack standardises on ZFS for LINSTOR — LVM / LVM-thin paths are not supported), installs extractedprism (per-node kube-apiserver HA proxy, generic variant default), installs the cozy-installer chart, applies the Platform Package, patches the root Tenant for ingress (breaks the OIDC chicken-and-egg), waits until every HelmRelease is Ready, prints a NOTES-style access summary, and offers an issue-template handoff to cozystack/* on fatal failure. Not for Kubernetes bootstrap and not for upgrades — see `cozystack:cluster-upgrade` for that. Talos node-prep is out of scope — `cozystack:cluster-install` refuses if Talos nodes are missing cozystack-tuned extensions and points at `cozystack:talos-bootstrap`.
argument-hint: "[--config-dir=<path>] [--context=<kube-context>] [--installer-version=<vX.Y.Z>] [--installer-variant=<talos|generic|hosted>] [--platform-variant=<isp-full|isp-full-generic|isp-hosted|default>] [--no-extractedprism] [--api-host=<ip>] [--dry-run]"
---

# cozystack:cluster-install

Work in reasoning mode. Use the phrasing `cozystack:cluster-install` (not "the skill") in user-facing messages. Announce phase transitions: `cozystack:cluster-install Phase N — <name>`.

> **Note on language in this SKILL.md** — every operator-facing prompt below is written in English for clarity. At runtime the skill matches the operator's natural language detected from prior conversation messages (or read from `<config-dir>/.state.yaml` `operator_language` when the wizard chain is in progress). Code identifiers, commands, file paths, and any text destined for GitHub stay canonical.

Entry point note: `cozystack:wizard` is the recommended way to reach this skill. The wizard runs node-bootstrap (`talos-bootstrap` / `ubuntu-bootstrap`) before handing off here when needed. This skill is also callable directly when the operator already has a ready cluster with prepared nodes.

Source of truth, in priority order:

1. Live cluster state — `kubectl --context $CTX ...`.
2. Upstream chart values: `~/git/github.com/cozystack/cozystack/packages/core/{installer,platform}/values.yaml` and the variant overlays.
3. Install guide for the major matching `--installer-version`: `https://cozystack.io/docs/v<X.Y>/install/kubernetes/generic/` (or `talos/`, `air-gapped`, etc.).
4. Ansible reference: `~/git/github.com/cozystack/ansible-cozystack/roles/cozystack/{defaults,tasks}/main.yml`.

Never guess versions, IPs, label values, or CIDRs — read them from the cluster or ask.

## Core principles

- Match the operator's natural language. Read from `<config-dir>/.state.yaml` `operator_language` (set by `cozystack:wizard` Phase 0) or detect from prior messages when invoked directly. Use it in prompts, AskUserQuestion options, summaries, and gates. Code identifiers, commands, file paths, and GitHub-public text stay in their canonical form.
- One valid path → just do it. After the operator approved the consolidated plan in Phase 5 (STOP GATE 2), the skill runs helm install + Platform Package apply + Tenant patch + HR wait + verification back-to-back without re-prompting. Approval gates remain only for (a) multi-option questions in Phase 4 (storage layout, network values, publishing host), (b) destructive operations (Phase 5.5 per-node storage provisioning — each `zpool create` is a real choice with data implications), (c) STOP GATEs 1/2/3 themselves. No "are you ready to continue?" between phases that have one valid outcome.
- Front-load the interview. **Every question the skill might ask in any phase is collected upfront in Phase 4**. That includes per-node storage devices (Phase 5.5), per-node provisioning approvals (Phase 5.5), extractedprism opt-out (Phase 5.6), Tenant ingress patch confirmation (Phase 8, inline), and HR stuck-state recovery preferences (Phase 8). Phase 2 cluster lookup + Phase 0 `intent_hints` from `<config-dir>/.state.yaml` must fill every slot they can before any question fires. Phase 4 presents **one consolidated summary** with every slot filled (defaults marked) and quick-edit affordances. Phases 5.5 onward execute against the collected answers — no re-prompts mid-flow except destructive STOP GATEs that have to ask by their nature (e.g. `zpool destroy` on an existing pool the operator chose to wipe).
- Layer-pure operator output. The skill never says "returning control to wizard", "the wizard will dispatch next", or any other orchestration commentary in the **operator-facing** summary. Whoever invoked the skill (a human running `/cozystack:cluster-install` directly, or the wizard's dispatch loop) figures out what's next on their own. Internal SKILL.md references to `cozystack:wizard` are fine for documentation; `wizard` does not appear in any text shown to the operator.
- The user is click-ops. Show what you're about to do, in plain language, before doing it. Wait for `Continue`.
- Three non-negotiable gates: **cluster fits**, **values gathered**, **all HRs Ready**. None can be skipped.
- Read-only lookups (`get`, `describe`, logs, ephemeral debug pods) need no approval. Mutating actions (`apply`, `patch`, `helm install`, `label`) need explicit user approval each time.
- Errors are not the user's fault. When a check fails, explain what's wrong, why it matters, and offer concrete next steps (with commands). Don't leave the user staring at a Helm stack trace.
- On a fatal failure that looks upstream: stop, assemble a diagnostic bundle (`references/issue-templates.md`), draft an issue body, hand it to the user.

## Phase 1 — Parse arguments and pin the context

Parse flags. Defaults:

- `--context` → use the one you parse from `kubectl config current-context` **but show it to the user and ask `Use this context or pick another?` via AskUserQuestion**. Do not silently inherit current-context.
- `--installer-version` → if absent, ask. Suggest the latest known stable from the cozystack repo's tags (read `git -C ~/git/github.com/cozystack/cozystack tag --list 'v*' --sort=-v:refname | head -5`).
- `--installer-variant` and `--platform-variant` → recommended by Phase 2 unless preset.

After the user picks a context, run and show:

```bash
kubectl --context $CTX cluster-info | head -1
kubectl --context $CTX get nodes --output wide
```

Detect prod-like signals (`prod`, `production`, `prd` in the context name). If present, refuse without `--allow-prod` and explain. The user must re-invoke with the flag.

Check for an existing install:

```bash
kubectl --context $CTX get namespace cozy-system --ignore-not-found --output name
kubectl --context $CTX get package cozystack.cozystack-platform --ignore-not-found --output name
```

If `cozy-system` exists **and** holds resources (any pods, any HRs, any operator deployment), refuse — point the user at `cozystack:cluster-upgrade`. The only "exists but empty" case to handle is a stale namespace with no helm metadata (see Phase 6 namespace-adoption).

## Phase 2 — Cluster lookup and variant recommendation

All read-only. Don't ask the user anything yet — gather facts first, then present.

Collect:

- k8s version (`kubectl version --output json`).
- Per-node `nodeInfo.osImage`, `kernelVersion`, `kubeletVersion`, `architecture`, `kubeProxyVersion`, plus all labels and `status.addresses`.
- Cluster domain — from coredns Corefile (see `references/node-checks.md`). Must be `cozy.local`.
- Pod CIDR — `kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'`.
- Service CIDR — try `kubectl --namespace kube-system get pod --selector component=kube-apiserver -o yaml`; fall back to `kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}'` and infer.
- CNI pods in `kube-system`.
- Conflicting workloads (ingress-nginx, cert-manager, metrics-server, kube-proxy, traefik, servicelb).
- Existing storage classes and the default.
- Existing LoadBalancer-class services.
- Control-plane node labels: `node-role.kubernetes.io/control-plane` key **and value** per node (see `references/node-checks.md`).
- **Storage discovery** (per node, via `kubectl debug node` in read-only mode — `lsblk`, `pvs`, `vgs`, `lvs --all`, `zpool list`, `command -v pvcreate vgcreate lvcreate lvs`; on Talos additionally `lsmod` for `drbd`/`zfs`/`openvswitch` and `/etc/lvm/lvm.conf` global_filter). Records: unmounted devices ≥ 50 GiB, existing VGs / LVs / zpools (will be reused as Phase 4 defaults), LVM-tools availability, Talos extension readiness. Skip on `isp-hosted`.

Apply variant recommendation logic from `references/variants.md`. Print:

```text
cluster lookup
  context:           $CTX
  api server:        $API_URL
  distribution:      $DIST (kubelet $K8S_VERSION)
  nodes:             $N (cp: $CPN, worker: $WN, mixed-arch: $MIXED)
  cluster domain:    $DOMAIN  (required: cozy.local — $MATCH)
  pod CIDR:          $POD_CIDR
  service CIDR:      $SVC_CIDR  (apiserver flag: $SVC_FLAG_MATCH)
  cni:               $CNI_PODS  ($CNI_VERDICT)
  conflicts:         $CONFLICT_LIST or "none"
  cp label values:   $CP_LABEL_VALUES  (per node)
  storage:
    per-node disks:  $UNMOUNTED_DISKS_PER_NODE
    existing pools:  $EXISTING_VGS_OR_ZPOOLS or "none"
    lvm tools:       $LVM_TOOLS_VERDICT
    talos modules:   $TALOS_DRBD_ZFS_OVS_VERDICT  (talos only)

recommended:
  installer variant: $INSTALLER_VARIANT
  platform variant:  $PLATFORM_VARIANT
  why:               $REASON
```

Hard refusals (don't move on, surface clearly):

- Cluster domain is not `cozy.local` → refuse, link to bootstrap docs for the user's distribution.
- CNI conflict (non-hosted) → refuse, list pods to remove.
- Conflicting workloads (ingress-nginx, cert-manager, etc., non-hosted) → refuse, list workloads.
- kubectl can't reach the cluster → refuse, suggest `kubectl auth can-i '*' '*' --all-namespaces`.

## Phase 3 — Node readiness validation

Skip on `isp-hosted` (no node access required).

For every other case, drive `kubectl debug node` per `references/node-checks.md`. For homogeneous clusters, check one sample CP node and one sample worker; warn that the rest are assumed identical. For heterogeneous, check every node.

**Talos-specific early-exit.** If Phase 2 detected Talos on any node, run the four Talos checks from `references/node-checks.md` (lsmod drbd / lsmod zfs / lsmod openvswitch / `/etc/lvm/lvm.conf` cozystack global_filter). If any of them fail on any Talos node, **STOP GATE 1 fails immediately** with this message:

```text
Talos nodes detected without cozystack-tuned extensions.

Missing on $NODE: $MISSING_LIST   (drbd / zfs / openvswitch / lvm.conf filter)

`cozystack:cluster-install` installs Cozystack on top of an already-prepared
cluster — Talos node prep is out of scope.

Fix paths:
  - Run `/cozystack:talos-bootstrap` (separate skill; prepares Talos nodes).
  - Or reinstall the affected nodes from the cozystack-tuned image
    `ghcr.io/cozystack/cozystack/talos:vX.Y.Z` (see
    https://cozystack.io/docs/v1.3/install/talos/).

Refusing to proceed — no mutations performed.
```

No partial install on a half-tuned Talos cluster.

For non-Talos and tuned-Talos, aggregate findings into a node readiness matrix:

```text
node-readiness
  node1 (cp):   kmod ✓  pkgs ✓  svcs ✓  sysctl ✓  multipath-bl ✓  disks ✓  cp-label ✓  storage-tools ✓
  node2 (cp):   kmod ✓  pkgs ✓  svcs ✗ (iscsid inactive)  sysctl ✓  multipath-bl ✗  ...
  node3 (worker): ...
```

For every ✗ surface: the exact check that failed, the value observed vs required, and one concrete fix command. If many nodes share the same gap on Ubuntu / Debian, the recommended fix is to run `cozystack:ubuntu-bootstrap` first (it wraps `cozystack/ansible-cozystack/examples/ubuntu/prepare-ubuntu.yml` which covers every node-prep concern Cozystack has). On Talos, the fix is `cozystack:talos-bootstrap`. For other distributions (RHEL family, SUSE), point operators at `cozystack/ansible-cozystack/examples/{rhel,suse}/prepare-*.yml` directly — out of scope for v1 of `cozystack:wizard`.

**STOP GATE 1 — Cluster readiness**

Present:

```text
gate 1 — cluster readiness

summary: <pass | needs work | refused>

blockers:
  - <list of refusal reasons; empty if "pass">
warnings:
  - <list of soft issues; e.g. mixed arch nodes, single-node cluster, weak resources>

next:
  options: Continue / Fix and re-check / Cancel
```

If blockers present → only `Cancel` is honoured. If only warnings → user picks.

## Phase 4 — Consolidated intake

This is the **one** interview phase. **Policy slots are read from `state.cozystack_intake`** (written by `cozystack:wizard` Phase 4 — the chain orchestrator front-loads every operator-decidable value before any skill runs). Discovery slots — the ones that need post-bootstrap probing (actual device paths, KubeOVN label values, real `Node.status.addresses`) — are resolved here against the live cluster.

Two-tier read pattern:

1. **Read `state.cozystack_intake` first.** Every value the wizard collected is the operator's authoritative answer; this skill never re-prompts what's already there.
2. **Discovery-driven fill.** Run Phase 2's lookups and Phase 3's node checks against the policy values. Pre-fill remaining slots from the discovery output: largest unmounted disk per node (matching `cozystack_intake.storage_pref.layout_per_node[<name>]`), real `InternalIP` / `ExternalIP` (validates `cozystack_intake.external_ips.strategy`), KubeOVN MASTER_NODES label state, talos KubePrism presence.
3. **Render the consolidated summary** with every slot filled and a single `Approve all / Edit <slot> / Cancel` gate. AskUserQuestion fires only when (a) `cozystack_intake` is missing — direct invocation without the wizard, (b) discovery contradicts the policy (e.g. `external_ips.strategy: external` but every node's `ExternalIP == InternalIP`), or (c) destructive STOP GATEs that have to ask by their nature.

When `state.cozystack_intake` is absent (operator ran `/cozystack:cluster-install` directly without the wizard), the skill falls back to asking each slot inline — same shape as before the front-load refactor. This keeps direct invocation viable; running through the wizard is the optimised path.

The shape of the consolidated summary (operator sees this **once**, not 10 times):

```text
cozystack:cluster-install — collected values

bundles:                system, paas, iaas, naas               (default for platform_variant: isp-full-generic on installer_variant: generic)

storage (ZFS):
  cp1 (10.0.0.10):      /dev/nvme1n1                            → zpool data (single)
  cp2 (10.0.0.11):      /dev/nvme1n1                            → zpool data (single)
  cp3 (10.0.0.12):      /dev/nvme1n1                            → zpool data (single)
  linstor pool name:    data

networking:
  podCIDR:              10.244.0.0/16                           (cozystack default; matches apiserver: ✓)
  podGateway:           10.244.0.1
  serviceCIDR:          10.96.0.0/16                            (cozystack default; matches apiserver: ✓)
  joinCIDR:             100.64.0.0/16
  apiServerHost:        127.0.0.1                               (extractedprism, default)
  apiServerPort:        7445
  kubeovn MASTER_NODES: ""                                      (Helm lookup, label matches)

publishing:
  external IPs:         10.0.0.50                               (from MetalLB pool / operator-supplied)
  mode:                 externalIPs
  host:                 10-0-0-50.nip.io                        (nip.io default; ownership gate auto-passes)
  apiServerEndpoint:    https://api.10-0-0-50.nip.io
  exposed:              api, dashboard
  cert solver:          http01

operations:
  storage provisioning: auto (one approve per node in Phase 5.5)
  extractedprism:       enabled (default for generic)
  tenant ingress patch: enabled (default for system bundle)

options:
  - Approve all — proceed to Phase 5 plan gate
  - Edit <slot> — name the slot (storage, networking.podCIDR, publishing.host, …)
  - Cancel
```

Slot legend (every slot the operator may want to edit):

1. **Bundles** (multiSelect, defaults from variant overlay):
   - system (required for `isp-full*`; off for `isp-hosted`)
   - paas (databases / applications)
   - iaas (Cluster API + VMs)
   - naas (Network as a Service)

2. **Storage** (only when `system` bundle is on — `isp-hosted` skips). Cozystack standardises on **ZFS** for LINSTOR pools; see `references/storage-backends.md`. No backend question — only device selection and pool layout per node.

   a. **Per-node disk selection** — for every storage-providing node, show Phase 2's unmounted-device list and ask which device(s) to use. Default is the largest unmounted disk ≥ 50 GiB. If a node has multiple candidates or the operator wants a mirror / RAID-Z, prompt for a vdev layout:

      - `single` — one disk, no redundancy (Recommended for dev / sandbox).
      - `mirror` — two disks, two-way mirror (Recommended for prod on 2-disk nodes).
      - `raidz` — 3+ disks, one parity disk.

      Refuse and ask again if the node has no qualifying device — operator picks: re-check / cancel / proceed without this node (the latter excludes the node from storage).

   b. **Names**:
      - zpool name — default `data`. Same name on every storage node (the LINSTOR storage-pool entry surfaces them under one logical name).
      - LINSTOR storage-pool name — default `data`. What `linstor storage-pool list` shows; referenced by every StorageClass `parameters.linstor.csi.linbit.com/storagePool`.

   c. **Summary echo** after collection:

      ```text
      storage decision (ZFS)
        node1:          /dev/nvme1n1                 → zpool data (single)
        node2:          /dev/nvme1n1, /dev/nvme2n1   → zpool data (mirror)
        node3:          /dev/nvme1n1                 → zpool data (single)
        linstor pool:   data
      ```

   Refuse to proceed if any storage node lacks ZFS tooling (`zpool` / `zfs` binaries) — the Phase 3 storage discovery would have caught it, but re-verify here in case a fix was applied since. RHEL 10 family is not supported on the storage path; see `references/known-failures.md`.

3. **podCIDR / serviceCIDR / joinCIDR** — show detected as defaults. If user picks Other, validate format (CIDR notation, no overlap with host networks the cluster sees, joinCIDR ≠ podCIDR ≠ serviceCIDR).
4. **podGateway** — auto-derive as the first IP of podCIDR, confirm.
5. **apiServerHost** — the address Cilium / KubeOVN / cozystack-operator dial to reach kube-apiserver. The skill picks this automatically by installer variant — **do not ask the operator** unless they passed `--api-host=<ip>`.

   - **`talos` variant** — `localhost:7445` (KubePrism, built into Talos machine-config). Operator can't override; Cozystack's `values-isp-full.yaml` overlay hard-codes this for Cilium.
   - **`generic` variant — default** — `127.0.0.1:7445` via **extractedprism DaemonSet** (a per-node TCP load balancer for kube-apiserver HA; mirrors what KubePrism does on Talos). The skill installs the chart in Phase 5.6 before the cozy-installer chart. No VIP, no keepalived. Single-CP sandboxes work too — extractedprism just proxies to one endpoint.
   - **`generic` variant with `--no-extractedprism`** — operator must supply `--api-host=<ip>` (internal IP of a CP, or a VIP / external LB IP they manage themselves). Single point of failure if a single CP IP is given on a multi-CP cluster; the skill warns but does not refuse.
   - **`hosted` variant** — the managed provider handles kube-apiserver HA; the skill does not install extractedprism and does not set apiServerHost (the cozy-installer chart's `hosted` variant doesn't need it).

   The plan presentation in Phase 5 always shows which choice landed and how to flip it.
6. **LB / external IPs** —
   - Mode: `externalIPs` (recommended for now; deprecated upstream in k8s v1.36) vs `loadBalancer` (Cilium L2/BGP or external cloud LB; needs more wiring).
   - Pool: resolved from `state.cozystack_intake.external_ips` (wizard Phase 4). The wizard already asked the operator's strategy — `internal` / `external` / `explicit` — and the reason. Here the skill **validates the strategy against live `Node.status.addresses`** and refuses to silently override:

     ```bash
     kubectl --context $CTX get nodes --output json \
       | jq -r '.items[] | {name: .metadata.name,
                            internal: (.status.addresses[] | select(.type=="InternalIP") | .address),
                            external: (.status.addresses[]? | select(.type=="ExternalIP") | .address // "")}'
     ```

     Cases:

     - `strategy: internal` and every node's `InternalIP` is present → use those.
     - `strategy: external` and every node's `ExternalIP` is present and differs from `InternalIP` → use the external set, but **first print the NAT-warning probe**: surface the strategy + reason from intake, and warn that on OCI 1:1 NAT / GCP NAT'd external IPs / AWS EIP the public IP is **not** present on the interface that receives the packet — the kernel only sees the InternalIP. Picking external here on such providers causes Cilium externalIPs BPF to never match, producing `Connection refused` on the dashboard host even when every HR is Ready. If `intent_hints.platform` ∈ {oci, aws-with-eip, gcp-with-nat}, **refuse the external choice** and force `internal` with a one-line justification; the operator can override with `--allow-external-on-nat-provider` if they know better.
     - `strategy: explicit` → take `cozystack_intake.external_ips.explicit` verbatim; sanity-check that each IP is reachable from at least one node (`nc -zw1 <ip> 80` from the first CP via `kubectl debug` if `--check-externals` is set; otherwise informational only).
     - `cozystack_intake.external_ips` is missing (direct invocation without the wizard) → ask inline. Default `internal` when InternalIP ≠ ExternalIP on any node. Surface the NAT warning.

   The chosen pool is recorded as `cozystack.publishing.external_ips` and lands in the Platform Package CR `spec.components.platform.values.publishing.externalIPs`.

   Collect these **before** the publishing.host question — the domain gate references the chosen IPs.

7. **publishing.host (FQDN) + domain ownership gate** — this is the public domain under which every service lives: `dashboard.${HOST}`, `keycloak.${HOST}`, `api.${HOST}`, `grafana.${HOST}`. Cozystack creates a wildcard ingress for `*.${HOST}` and asks Let's Encrypt for certificates via the **HTTP-01 solver by default** (`publishing.certificates.solver: http01`).

   This means the domain must be:

   1. **Owned by the operator** — they need to configure DNS for it.
   2. **Publicly resolvable** — wildcard `*.${HOST}` A-records pointing at the external IPs picked in question #6.
   3. **Reachable on port 80 from the public internet** — Let's Encrypt validators hit `http://<challenge-host>/.well-known/acme-challenge/...`.

   Failure modes if any of these is wrong: cert-manager `Order` CRs go pending, certificates never issue, ingress serves a default cert that browsers reject, dashboard / keycloak unreachable.

   Options:

   a) **Custom FQDN** (`cluster.example.com`) — Recommended for real deployments. **Hard gate**: show this confirmation:

   ```text
   You picked publishing.host = cluster.example.com

   Cozystack will request Let's Encrypt certificates for *.cluster.example.com
   via the HTTP-01 solver. For this to work, you must:

     1. Own the domain cluster.example.com (or its parent example.com).
     2. Configure a wildcard A-record: *.cluster.example.com → <EXTERNAL_IPS>
        (the same IPs you picked at the "external IPs" question above).
     3. Make port 80 reachable from the public internet at those IPs.

   If any of this is not true, certificates will never issue, every browser
   visit to https://dashboard.cluster.example.com will warn, and the install
   verification at Phase 9 will fail the dashboard reachability probe.

   Confirm: I own this domain and DNS will be configured before this install completes.

   options: Yes, I own this domain / No, let me pick a different host / Cancel install
   ```

   Without an explicit yes — do not proceed.

   b) **nip.io playground** (`<LB-IP-with-dashes>.nip.io`, e.g. `192-0-2-10.nip.io`) — Recommended for sandbox / dev. Works out of the box: nip.io is a public service that resolves `<IP-with-dashes>.nip.io` to the embedded IP, Let's Encrypt accepts nip.io domains, no DNS configuration needed. Skip the ownership gate for nip.io patterns.

   After collection, run a soft DNS pre-flight (warning only, not a refusal — operator may be configuring DNS in parallel):

   ```bash
   probe="precheck-$(TZ=UTC date +%s).${HOST}"
   dig +short "$probe" | head -3
   ```

   On a nip.io host this returns the embedded IP immediately. On a fresh custom FQDN it may return empty until DNS propagates. Surface either way:

   ```text
   DNS pre-flight for *.${HOST}: $RESULT

   Expected: at least one of <EXTERNAL_IPS> appears in the output.
   Got: $DIG_OUTPUT

   - If matches: DNS already configured. Proceed.
   - If empty / different: configure DNS now (wildcard A-record) before
     Phase 8 reaches dashboard / keycloak HRs (~10 min into wait).
     The install will still progress, but will fail those HRs until DNS
     resolves.

   options: Continue (DNS will be configured shortly) / Re-check DNS / Cancel
   ```

8. **Cert-manager solver** — `http01` (default, Recommended — only works with public DNS + port 80) vs `dns01` (works on internal networks, but needs DNS-provider credentials in cert-manager values, out of scope for v1 of `cozystack:cluster-install`). On nip.io always pick http01. If operator insists on dns01, set `publishing.certificates.solver: dns01` and remind them the issuer config has to be applied manually.

9. **apiServerEndpoint** — default `https://api.<publishing.host>:6443`. Explain it goes into client kubeconfigs.

10. **exposedServices** (multiSelect): `api`, `dashboard`, `vm-exportproxy`, `cdi-uploadproxy`. Default `api,dashboard`.

11. **KubeOVN `MASTER_NODES`** — branch on Phase 2 finding:
    - If CP label value matches variant expectation on at least one node → default empty (let lookup work).
    - Otherwise → pre-fill comma-separated INTERNAL-IPs of CP nodes from Phase 2 and explain why the lookup would fail.

After all questions, render the full Package CR to `<config-dir>/cozystack-platform-package.yaml` and show the file path + content. Offer: `Accept` / `Edit <key>` / `Cancel`. `<config-dir>` comes from `state.config_dir` written by `cozystack:wizard` Phase 1; if invoked directly, ask the operator (default `$PWD`).

If `state.sops.enabled` is true, the skill `sops --encrypt --in-place`s the file after Accept and decrypts to a tempfile for the Phase 7 `kubectl apply --filename`. The encrypted form is what gets committed; the tempfile is removed immediately after apply.

## Phase 5 — Plan presentation (STOP GATE 2)

After Accept of the Phase 4 intake values, build the consolidated plan view. This is the final operator confirmation before the skill runs helm install + Platform Package apply + watch loop:

```text
cozystack:cluster-install plan

context:           $CTX  ($API_URL)
installer release: oci://ghcr.io/cozystack/cozystack/cozy-installer:$INSTALLER_VERSION_OCI    (OCI tag = git tag with the v stripped)
installer variant: $INSTALLER_VARIANT
helm release ns:   kube-system  (chart templates Namespace cozy-system itself)
platform variant:  $PLATFORM_VARIANT
bundles:           $BUNDLES_CSV

networking:
  podCIDR:         $POD_CIDR  (matches apiserver: ✓/✗)
  podGateway:      $POD_GW
  serviceCIDR:     $SVC_CIDR  (matches apiserver: ✓/✗)
  joinCIDR:        $JOIN_CIDR
  kubeovn MASTER_NODES: $MASTER_NODES or "(label lookup)"
  apiServerHost:   $API_HOST  ($API_HOST_SOURCE)
                   # $API_HOST_SOURCE values:
                   #   "Talos KubePrism"        — variant=talos
                   #   "extractedprism (default)" — variant=generic
                   #   "operator override"      — --api-host=<ip> or --no-extractedprism
                   #   "managed (hosted)"       — variant=hosted, not set

publishing:
  host:            $HOST                    (ownership confirmed: ✓ / nip.io)
  dns pre-flight:  $DNS_PROBE_RESULT        (✓ matches external IPs / ⚠ pending / nip.io magic)
  apiServerEndpoint: $API_ENDPOINT
  exposure mode:   $MODE
  external IPs:    $EXT_IPS
  exposed:         $EXPOSED_CSV
  cert solver:     $SOLVER                  (http01 / dns01)

storage (ZFS):
  per-node:
    $NODE1:         $DEVICES1 → zpool $POOL_NAME ($LAYOUT)
    $NODE2:         $DEVICES2 → zpool $POOL_NAME ($LAYOUT)
  linstor pool:    $LINSTOR_POOL_NAME

actions on Continue:
  1. Storage provisioning per node (Phase 5.5; one approval per node)
  2. (generic only, unless --no-extractedprism) install extractedprism DaemonSet for kube-apiserver HA  (~1 min)
  3. (if cozy-system namespace exists but unowned) adopt namespace into kube-system/cozy-installer
  4. helm upgrade --install cozy-installer ... --namespace kube-system  (~2 min)
  5. wait deploy/cozystack-operator Available; wait CRD packages.cozystack.io Established
  6. kubectl apply --filename /tmp/.../platform-package.yaml
  7. wait root Tenant CR, patch spec.ingress=true (~3 min — required for Phase 8 to ever finish; breaks the OIDC chicken-and-egg)
  8. poll HRs every 30s until all Ready=True (~30–60 min)
  9. print access summary

options: Continue / Edit values / Cancel
```

If `Skip — pool already managed externally` was picked in Phase 4, the storage block is replaced with `storage: skipped (externally managed)` and Phase 5.5 is omitted from the action list.

## Phase 5.5 — Storage provisioning (STOP GATE per node, or batch when identical)

Skip entirely if Phase 2 detected an existing zpool with the name Phase 4 collected and the operator chose `reuse` — in that case the skill verifies the existing pool with `zpool status` instead of creating.

**Batch-all-identical pattern**: when every storage-scope node has the same layout (single device path, same `cozystack_intake.storage_pref.layout_per_node[*]` value, same zpool name, same distribution), the per-node STOP GATE collapses to one approval that covers all nodes. Three identical CPs each picking `/dev/sdb` for `single` layout shouldn't require three identical yes/no rounds. Determine identical-batch shape:

```bash
LAYOUTS=$(yq '[.cozystack_intake.storage_pref.layout_per_node[]] | unique' "$STATE_FILE")
DEVICES_PER_NODE=$(yq '[.cozystack.storage.discovered_devices[][] | length] | unique' "$STATE_FILE")
DISTRIBUTIONS=$(yq '[.inventory.nodes[].distribution // .cluster.distribution] | unique' "$STATE_FILE")

if [ "$(jq 'length' <<<"$LAYOUTS")" -eq 1 ] && \
   [ "$(jq 'length' <<<"$DEVICES_PER_NODE")" -eq 1 ] && \
   [ "$(jq 'length' <<<"$DISTRIBUTIONS")" -eq 1 ]; then
  BATCHABLE=1
fi
```

When `BATCHABLE=1`, surface a single STOP GATE that covers all nodes:

```text
storage provisioning — $N identical nodes ($DISTRIBUTION)

  layout:    $LAYOUT (single device per node, same path on each)
  per node:  /dev/sdb → zpool $POOL_NAME

  nodes that will be provisioned:
    node0   /dev/sdb → zpool $POOL_NAME (single)
    node1   /dev/sdb → zpool $POOL_NAME (single)
    node2   /dev/sdb → zpool $POOL_NAME (single)

  options:
    - Provision all $N (Recommended — identical config across nodes)
    - Step through each node — switch to one-STOP-GATE-per-node flow
    - Cancel install
```

On `Provision all`, run the per-node loop without per-node prompts. On any per-node failure, abort the batch and surface which node failed + the failure mode (do not silently continue with the remaining nodes — partial cluster is harder to debug than no cluster).

For non-identical configurations (mixed layouts: one node `single`, another `mirror`; or different device paths discovered per node), drop to the per-node STOP GATE flow below — each node gets its own approval because the operator is making a real choice each time.

For every other node in storage scope, run the per-node loop. The mechanism splits on `cluster.distribution`:

- **Talos**: cannot use `kubectl debug node --image=alpine:3 -- chroot /host zpool create`. Three reasons it fails:
  1. `alpine:3` ships musl libc; the Talos host's `/usr/local/sbin/zpool` is glibc-linked and depends on `/lib64/ld-linux-x86-64.so.2`, which doesn't exist on Talos rootfs (Talos itself is musl-statically-linked; the zfs userspace lives only inside the `ext-zfs-service` namespace).
  2. `chroot /host /bin/sh` — `/bin/sh` does not exist in Talos rootfs.
  3. The Pod Security Admission `baseline` enforced on `default` and `kube-system` rejects the privileged debug Pod the `sysadmin` profile creates.

  Use a privileged DaemonSet bootstrap pattern instead — see `references/storage-backends.md` Talos section for the exact ubuntu+apt+sgdisk+bind-mount commands. Summary: create a `cozy-storage-bootstrap` namespace with PSA label `pod-security.kubernetes.io/enforce=privileged`, run a one-shot privileged pod from `ubuntu:24.04`, `apt-get install -y zfsutils-linux`, bind-mount `/dev/zfs` and the chosen disk's host path, `sgdisk` partition before `zpool create` (Talos has no udev inside the pod, so `zpool create /dev/sdb` cannot wait for partition discovery — partition manually first), then `zpool create -f $POOL_NAME /dev/sdbN`.

- **Ubuntu / k3s / kubeadm**: the original `kubectl debug node --image=alpine:3 -- chroot /host` path works (host has glibc + `/bin/sh` + zfs userspace pre-installed by `ansible-cozystack`).

1. **Present** the exact commands per distribution, with `$DEVICE` (or `$DEVICES` for mirror / raidz) and `$POOL_NAME` substituted. Pull the bodies from `references/storage-backends.md`.

   ```text
   storage provisioning — node $NODE  ($DISTRIBUTION)

   layout:  $LAYOUT         (single / mirror / raidz)
   target:  $DEVICES → zpool $POOL_NAME

   commands (Talos path — privileged DaemonSet from ubuntu:24.04):
     # one-shot pod in cozy-storage-bootstrap; PSA=privileged
     apt-get install -y zfsutils-linux
     sgdisk --zap-all $DEVICE && sgdisk --new=1:0:0 --typecode=1:bf01 $DEVICE
     partprobe $DEVICE && sleep 1
     zpool create -o ashift=12 $POOL_NAME ${DEVICE}1
     zfs set compression=lz4 $POOL_NAME
     zfs set atime=off $POOL_NAME

   commands (Ubuntu / k3s / kubeadm path — kubectl debug chroot /host):
     zpool create -o ashift=12 $POOL_NAME $VDEV_SPEC
     zfs set compression=lz4 $POOL_NAME
     zfs set atime=off $POOL_NAME

   verify (read-only) commands the skill will run afterwards:
     zpool status $POOL_NAME
     zpool list -H -o name,size,free,health $POOL_NAME

   options: Provision this node / Skip this node / Cancel install
   ```

   `$VDEV_SPEC` resolves per layout: `$DEVICE` for `single`, `mirror $DEVICE1 $DEVICE2` for `mirror`, `raidz $DEVICE1 $DEVICE2 $DEVICE3` for `raidz`. The Talos path is single-device only in v1 of this skill — multi-device layouts on Talos need per-device sgdisk and the pod's bind-mount list grows accordingly; surface as "not yet supported, use Ubuntu route for mirror/raidz on Talos workers".

2. **On `Provision this node`**:

   - Talos path:

     ```bash
     # Ensure the bootstrap namespace exists with the right PSA label
     kubectl --context $CTX get ns cozy-storage-bootstrap >/dev/null 2>&1 || \
       kubectl --context $CTX create ns cozy-storage-bootstrap
     kubectl --context $CTX label ns cozy-storage-bootstrap \
       pod-security.kubernetes.io/enforce=privileged --overwrite

     # Run the bootstrap pod; image is held in references/storage-backends.md
     # so a pinned digest is the single source of truth.
     kubectl --context $CTX --namespace cozy-storage-bootstrap run zpool-create-$NODE \
       --image=ubuntu:24.04 --restart=Never --overrides='{...}' \
       --command -- /usr/local/bin/cozy-zpool-bootstrap.sh "$DEVICE" "$POOL_NAME"
     kubectl --context $CTX --namespace cozy-storage-bootstrap wait pod/zpool-create-$NODE \
       --for=condition=Ready --timeout=300s
     ```

     The `--overrides` payload mounts `/dev` into the pod, sets `nodeName: $NODE` so it runs where the disk lives, sets `hostPID: true` so `partprobe` is visible to the host kernel, and sets `hostNetwork: true` because Phase 5.5 runs **before** Phase 6 installs cozy-installer (which installs Cilium). Without `hostNetwork: true`, a pod with the default pod-network needs CNI to assign an IP — Cilium isn't up yet, so the pod stays `ContainerCreating`. Using the host network sidesteps the need for CNI entirely; the bootstrap pod doesn't open any listening ports. See `references/storage-backends.md` for the verbatim JSON.

   - Ubuntu / k3s / kubeadm path:

     ```bash
     kubectl --context $CTX debug node/$NODE \
       --image=alpine:3 --profile=sysadmin --quiet --stdin=false --tty=false \
       -- chroot /host /bin/sh -c '<commands-from-step-1>'
     ```

   Capture stdout/stderr. Print them to the operator verbatim. On Talos, the pod's logs are the source.

3. **Verify**. Run the verify block from step 1. The zpool must show `health: ONLINE`. If the output does not match (`DEGRADED` on a fresh single-disk pool = device failure; missing pool entirely = `zpool create` silently failed), **mark the node as failed** and surface the diff.

4. **On any failure** in step 2 or step 3:

   ```text
   storage provisioning failed on $NODE

   stage:   create | verify
   stderr:  <captured stderr>

   options: Retry / Skip this node / Cancel install (and offer backout commands)
   ```

5. **On `Skip this node`** — record the decision. The skill excludes this node from the LINSTOR storage-pool registration block inside the Phase 8 watch loop. Warn the operator: a single-node-skipped cluster degrades DRBD replica count.

6. **On `Cancel install`** — show backout commands from `references/storage-backends.md` (`zpool destroy` + `wipefs --all`, plus `kubectl delete ns cozy-storage-bootstrap` on Talos) for every node that was already provisioned in this Phase 5.5 run. The skill does not auto-rollback (operator must own the destructive step).

7. **Pre-existing-data check** (every distribution). Before `zpool create`, probe the target device for residual LVM / DRBD / LINSTOR thin-pool state from previous installs:

   ```bash
   # On the same debug pod / privileged pod:
   pvs --noheadings --options vg_name "$DEVICE" 2>/dev/null
   dmsetup ls | grep -E "(linstor|drbd|thin)" || true
   wipefs --output=label,type "$DEVICE"
   ```

   If anything is reported, **refuse to proceed** without an explicit operator confirmation. A `talosctl reset` does not wipe user disks by default; previous-install state on `/dev/sdb` is a common cause of `zpool create` failing with `EBUSY` or silently producing a DEGRADED pool. Offer the wipe command (`vgchange -an; dmsetup remove --force; dd if=/dev/zero of=$DEVICE bs=1M count=10; sgdisk --zap-all $DEVICE; wipefs --all $DEVICE`) for the operator to approve and execute, then re-run.

After every storage-scope node is either provisioned or explicitly skipped, persist the per-node mapping to `<config-dir>/.state.yaml` under `cozystack.storage.nodes[]`. The LINSTOR storage-pool registration is **not** declarative on the ZFS path (the CRD has no `zfsPool` slot); the skill runs the registration inside the Phase 8 watch loop as soon as `linstor-controller` reports Ready — see Phase 8 below for the implementation, not a forward-reference.

## Phase 5.6 — Install extractedprism DaemonSet (generic HA)

Skip entirely when:

- installer variant is `talos` — KubePrism is built-in.
- installer variant is `hosted` — provider handles kube-apiserver HA.
- operator passed `--no-extractedprism` — skill respects the override and uses `--api-host=<ip>` instead.

For `generic` variant without opt-out, install the chart **before** cozy-installer so the operator's `apiServerHost: 127.0.0.1 + apiServerPort: 7445` already resolves when cozystack-operator starts dialing kube-apiserver:

```bash
# Endpoints = list of <CP_IP>:6443 for every CP in inventory.
# Read from Phase 2 node lookup (filter by node-role.kubernetes.io/control-plane).
CP_IPS=$(kubectl --context $CTX get nodes \
  --selector node-role.kubernetes.io/control-plane \
  --output jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')

# Chart contract: endpoints is a comma-separated string scalar
# (values.schema.json type=string). A YAML list is rejected by helm
# schema validation before render.
ENDPOINTS=$(printf '%s\n' "$CP_IPS" | awk 'NF{printf "%s%s:6443", sep, $0; sep=","}')

# Render the values file under <config-dir>. This is the canonical
# artifact the orchestrator advertises and the sops opt-in encrypts.
cat > "$CONFIG_DIR/extractedprism-values.yaml" <<EOF
endpoints: "${ENDPOINTS}"
EOF

helm --kube-context $CTX upgrade --install extractedprism \
  oci://ghcr.io/lexfrei/charts/extractedprism \
  --version 0.2.0 \
  --namespace kube-system \
  --values "$CONFIG_DIR/extractedprism-values.yaml" \
  --wait --timeout 5m
```

Verify the DaemonSet covers every node and pods are Ready (port 7446 health check) before continuing:

```bash
kubectl --context $CTX --namespace kube-system rollout status daemonset/extractedprism --timeout=5m
kubectl --context $CTX --namespace kube-system get pods --selector app.kubernetes.io/name=extractedprism --output wide
```

If any node lacks the extractedprism pod (taint, nodeSelector skip), Cilium on that node will fail to reach the apiserver after install. Surface and ask: continue / re-apply with broader toleration / abort.

extractedprism is a per-node TCP load balancer that listens on `127.0.0.1:7445` and proxies to a healthy CP endpoint with TCP health checks. Source: `https://github.com/lexfrei/extractedprism`. License: BSD-3-Clause. The chart at `oci://ghcr.io/lexfrei/charts/extractedprism` ships a DaemonSet with `hostNetwork: true`, `priorityClassName: system-node-critical`, and a catch-all toleration so it runs on every node regardless of taints — that is intentional, the proxy is critical infrastructure.

## Phase 6 — Install operator

Namespace adoption first if `cozy-system` exists and lacks Helm metadata (see `references/values-template.md`). If it's owned by another release, **refuse** — do not relabel.

**OCI registry version format**: cozystack publishes the cozy-installer chart to `ghcr.io/cozystack/cozystack/cozy-installer` with tags like `1.3.3` (no `v` prefix). If `state.cozystack.installer_version` carries the canonical `vX.Y.Z` form (from cozystack/cozystack git tags), strip the `v` before passing to `--version`. Phase 5 plan presentation already shows the normalised version so the operator sees what gets run.

```bash
# Normalise: v1.3.3 → 1.3.3 (Helm's OCI client matches the registry tag as-is)
INSTALLER_VERSION_OCI="${INSTALLER_VERSION#v}"

# v1.4.0+ (current): release lives in cozy-system; --create-namespace is REQUIRED.
# The chart no longer templates the cozy-system Namespace (changed in cozystack/cozystack#2508);
# a pre-install hook Job (cozy-system-labeler, in kube-system, hostNetwork,
# tolerant of NotReady/CNI-not-ready) stamps the new namespace with
# PSA enforce=privileged + cozystack.io/system=true. Passing the old
# `--namespace kube-system` without --create-namespace makes the labeler hook
# fail with `namespaces "cozy-system" not found` and aborts the install.
helm --kube-context $CTX upgrade --install cozy-installer \
  oci://ghcr.io/cozystack/cozystack/cozy-installer \
  --version "$INSTALLER_VERSION_OCI" \
  --namespace cozy-system --create-namespace \
  --set cozystackOperator.variant=$INSTALLER_VARIANT \
  --set cozystack.apiServerHost=$API_HOST \
  --set cozystack.apiServerPort=$API_PORT \
  --wait --timeout 10m
```

For a v1.3.x install the form is `--namespace kube-system` with NO `--create-namespace` (the v1.3 chart templates the namespace itself). See `references/values-template.md` for both forms side by side — pick the one matching `installer_version`.

For `talos` and `hosted`, drop `cozystack.apiServerHost` / `apiServerPort` if not required by the chart.

Verify:

```bash
kubectl --context $CTX --namespace cozy-system wait deploy/cozystack-operator \
  --for=condition=Available --timeout=300s
kubectl --context $CTX wait crd/packages.cozystack.io \
  --for=condition=Established --timeout=300s
```

If the helm install fails, show events + the operator's logs and stop. Don't retry blindly.

## Phase 7 — Apply Platform Package

```bash
if [ "$(yq '.sops.enabled // false' "$CONFIG_DIR/.state.yaml")" = "true" ]; then
  tmp=$(mktemp); sops --decrypt "$CONFIG_DIR/cozystack-platform-package.yaml" > "$tmp"
  kubectl --context $CTX apply --filename "$tmp"; rm -f "$tmp"
else
  kubectl --context $CTX apply --filename "$CONFIG_DIR/cozystack-platform-package.yaml"
fi
```

Confirm the Package was created:

```bash
kubectl --context $CTX get package cozystack.cozystack-platform --output yaml
```

## Phase 8 — Watch HelmReleases until green (with inline root Tenant patch)

See `references/helmrelease-monitoring.md` for the full polling pattern and stuck-state diagnostics.

This phase merges what used to be Phase 7.5 (root Tenant ingress patch) into the watch loop. The motivation: on a real install the `tenants.apps.cozystack.io` CRD can take longer to install than the wait deadline of a separate phase — sometimes the CRD doesn't exist until after most HRs are Ready, so a fixed 5-minute wait-for-Tenant expires before the CRD lands. Folding the patch into the watch loop makes it event-driven: as soon as the CR appears, the skill patches it and continues monitoring, regardless of where Phase 8 is in its own progression.

**Why the patch is needed**: cozystack's dashboard ships gatekeeper (oauth2-proxy) which, on startup, does OIDC discovery against the **public FQDN** `https://keycloak.${HOST}/realms/cozy/.well-known/openid-configuration` — not an in-cluster service. Without the root ingress controller running, nothing listens on 443, gatekeeper CrashLoopBackOffs, the `cozy-dashboard/dashboard` HR sits in `Unknown: Running 'install' action with timeout of 10m0s` and then `InstallFailed: context deadline exceeded`, Flux remediates and retries forever. `cozy-fluxcd/flux-plunger` has a hard dependency on `cozy-dashboard/dashboard` and stays `False: dependency is not ready`. The phase would never go green.

**The dashboard requires OIDC/Keycloak — it is not optional on the supported path.** The "Why the patch is needed" note above describes gatekeeper doing OIDC discovery against Keycloak. But Keycloak only deploys when `authentication.oidc.enabled: true` in the Platform Package — and that key defaults to `false`, with the `isp-full*` overlays NOT turning it on. If the skill enables `ingress` + sets `host` but never enables OIDC, the result on v1.4.2 is: no `cozy-keycloak` namespace, no Keycloak HR, and the dashboard falls back to its non-OIDC `token-proxy` container, which is **broken on v1.4.2** — the container starts, never binds `:8000` (connection refused, zero logs), and is killed by its own `/ping` liveness probe every ~45 s → CrashLoopBackOff → the `cozy-dashboard/dashboard` HR fails install → `flux-plunger` and the rest of the chain hang. The cluster reports 88/90 HRs Ready and looks "almost done" forever.

So for a usable dashboard the skill must enable OIDC. This is exactly what cozystack's own e2e (`hack/e2e-install-cozystack.bats`) does — patch the root tenant host, then enable OIDC and expose Keycloak:

```bash
# Enable OIDC and expose keycloak (do this once, after the Package exists).
kubectl --context $CTX patch package cozystack.cozystack-platform --type merge \
  --patch '{"spec":{"components":{"platform":{"values":{"authentication":{"oidc":{"enabled":true}}}}}}}'

# keycloak must be in publishing.exposedServices so its public ingress (and
# therefore its LE cert + issuer URL) exists; api+dashboard alone are not enough.
kubectl --context $CTX patch package cozystack.cozystack-platform --type merge \
  --patch '{"spec":{"components":{"platform":{"values":{"publishing":{"exposedServices":["api","dashboard","keycloak"]}}}}}}'
```

Better: bake both into the Platform Package CR written in Phase 4/7 from the start (`authentication.oidc.enabled: true` and `keycloak` in `exposedServices`) so there is no second reconcile. The Phase 4 intake should collect a **dashboard auth** decision — OIDC/Keycloak (recommended; the only path with a working dashboard on 1.4.2) vs none (API-only, no web dashboard) — and only enable OIDC when the operator wants the dashboard. When OIDC is enabled, Keycloak needs a working LE cert for `keycloak.${HOST}`, so the same DNS/port-80 preconditions as the dashboard host apply (Phase 4 publishing gate already covers this — just make sure `keycloak.${HOST}` is inside the wildcard).

Skip the root-Tenant patch entirely on `isp-hosted` or when the `system` bundle was disabled in Phase 4 — there is no root Tenant CR in those modes.

Watch loop (per 30 s poll):

```bash
# 1) Has the root Tenant CR landed? If yes and not yet patched, patch it.
#    Set BOTH spec.host and spec.ingress. The root tenant ships with
#    spec.host: "" and does NOT inherit publishing.host from the Platform
#    Package (verified on v1.4.2). With an empty host the per-tenant ingress
#    objects (dashboard.${HOST}, keycloak.${HOST}, …) render against an empty
#    domain and Keycloak/dashboard never get usable URLs. $HOST is the
#    publishing.host collected in Phase 4.
if kubectl --context $CTX --namespace tenant-root get tenants.apps.cozystack.io root \
     --output jsonpath='{.metadata.name}' 2>/dev/null | grep -q '^root$'; then
  CUR_INGRESS=$(kubectl --context $CTX --namespace tenant-root get tenants.apps.cozystack.io root \
                  --output jsonpath='{.spec.ingress}')
  CUR_HOST=$(kubectl --context $CTX --namespace tenant-root get tenants.apps.cozystack.io root \
                  --output jsonpath='{.spec.host}')
  if [ "$CUR_INGRESS" != "true" ] || [ "$CUR_HOST" != "$HOST" ]; then
    kubectl --context $CTX --namespace tenant-root patch tenants.apps.cozystack.io root \
      --type=merge --patch "{\"spec\":{\"ingress\":true,\"host\":\"${HOST}\"}}"
    echo "patched tenants/root spec.host=${HOST} ingress=true at $(TZ=UTC date -Iseconds)"
  fi
fi

# 2) Standard HR readiness summary
kubectl --context $CTX get hr --all-namespaces \
  --output jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready" && @.status!="True")])]}{.metadata.namespace}/{.metadata.name} {end}'
```

On the full `system`-bundle path you may also want the root tenant's `etcd`/`monitoring`/`seaweedfs` services (this is what cozystack's own `hack/e2e-install-cozystack.bats` patches): extend the patch to `{"spec":{"ingress":true,"host":"<HOST>","monitoring":true,"etcd":true,"seaweedfs":true}}` when those were selected in Phase 4. Leave them at their defaults otherwise.

```text
HelmRelease $NS/$NAME has been Failing for $T minutes.
Last condition: <message>
options: Keep waiting / Capture diagnostics and pause / Abort
```

`Capture diagnostics` runs the bundle script from `references/issue-templates.md`.

**STOP GATE 3 — All HRs Ready AND storage pools registered**

Don't print success until **both** conditions hold:

```bash
# Condition 1: no HelmRelease is non-Ready
HR_NOT_READY=$(kubectl --context $CTX get hr --all-namespaces \
  --output jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready" && @.status!="True")])]}{.metadata.namespace}/{.metadata.name} {end}')

# Condition 2: storage-pool count matches the storage-node count (skip when no ZFS scope)
EXPECTED_POOLS=$(yq '.cozystack.storage.nodes | length' "$STATE_FILE")
if [ "$EXPECTED_POOLS" -gt 0 ]; then
  ACTUAL_POOLS=$(kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- \
    linstor storage-pool list --output-version v1 2>/dev/null \
    | jq --raw-output '[.[] | select(.provider_kind == "ZFS") | .node_name] | unique | length')
else
  ACTUAL_POOLS=0
  EXPECTED_POOLS=0
fi

# Exit watch loop only when BOTH are satisfied
[ -z "$HR_NOT_READY" ] && [ "$ACTUAL_POOLS" -eq "$EXPECTED_POOLS" ]
```

Why both: an HR can report `Ready=True` (from Flux's lifecycle: "install action succeeded") **before** the underlying Deployment has any ready replicas. The LINSTOR-controller HR is the canonical case — Ready=True at the moment the helm release lands, but `kubectl get deploy linstor-controller --output jsonpath='{.status.readyReplicas}'` is still empty for another 30–60 s while the pod starts. Exiting on HR-Ready-only races the inline storage-pool registration block: the watch loop sees "all HRs Ready" and exits before the per-poll registration check has fired against a ready linstor-controller, leaving pools unregistered. Operator then has to register them manually after `cluster-install` already declared success.

The combined gate avoids that race without re-introducing the post-watch deadlock (paas / monitoring HRs that depend on PVCs would never reach Ready if registration ran *after* all HRs were required to be Ready — see `references/known-failures.md`).

### LINSTOR storage-pool registration — inline (gated on linstor-controller Ready)

Why this is folded into the watch loop rather than a post-watch phase: any HR in the `paas` or `monitoring` bundles that requests a PVC stays `Pending` until LINSTOR has a registered storage pool for at least one node. If pool registration runs *after* "all HRs Ready", the watch loop can never exit — Phase 8 deadlocks waiting for HRs whose PVCs deadlock waiting for the pool. This is the same shape as the root-Tenant ingress patch: the right gate is "the producer became Ready", not "everything is Ready".

The same watch loop documented above is extended with a storage-pool registration block, gated on `linstor-controller` Ready, not on all-HR-Ready:

```bash
# Per poll, alongside the root Tenant patch check:

# Gate: linstor-controller Deployment has >= 1 Ready replica
LINSTOR_READY=$(kubectl --context $CTX --namespace cozy-linstor get deploy linstor-controller \
                  --output jsonpath='{.status.readyReplicas}' 2>/dev/null)
if [ "${LINSTOR_READY:-0}" -ge 1 ]; then
  yq --output-format=json '.cozystack.storage.nodes' "$STATE_FILE" \
    | jq --compact-output '.[]' \
    | while IFS= read -r entry; do
        NODE=$(jq --raw-output '.name' <<<"$entry")
        ZPOOL=$(jq --raw-output '.zpool' <<<"$entry")
        LINPOOL=$(jq --raw-output '.linstor_pool' <<<"$entry")

        # Idempotent: skip if the pool is already registered on this node.
        # linstor CLI lives inside the controller pod and uses the in-cluster mTLS
        # client certs at /etc/linstor/client/ — no external CLI install needed.
        if kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- \
             linstor storage-pool list --node "$NODE" --storage-pool "$LINPOOL" \
             --output-version v1 2>/dev/null | grep -q "$LINPOOL"; then
          continue
        fi

        kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- \
          linstor storage-pool create zfs "$NODE" "$LINPOOL" "$ZPOOL" \
          || { echo "storage-pool register failed on $NODE"; exit 1; }
      done
fi
```

On per-node registration failure, the watch loop aborts Phase 8 and writes `failed_at: "linstor-storage-pool"` with `error_detail` containing the failing node and the `linstor storage-pool create` stderr. Partial registrations are kept (idempotent retry-friendly); operator can re-invoke after fixing the root cause.

Verification (after all HRs Ready, separately from registration):

```bash
kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- \
  linstor storage-pool list | grep -E "zfs|node"
# Expect one ZFS row per storage-providing node with non-zero Capacity.
```

## Phase 8.6 — Default StorageClasses

**Gate on the live cluster, not on a version number.** Earlier guidance skipped this phase on `installer_version ≥ 1.4.0` on the assumption that the `tenants.apps.cozystack.io` CRD exposes `spec.storageClasses` and the operator creates the StorageClasses from the tenant declaration. That assumption is **false on at least v1.4.2** — the shipped tenant CRD has no `storageClasses` field (`kubectl get crd tenants.apps.cozystack.io -o yaml | grep -c storageClass` → `0`), nothing auto-creates StorageClasses, and the cluster reaches "all HRs Ready" with `kubectl get storageclass` empty. Every stateful workload (keycloak-db, etcd, seaweedfs, vmstorage/vlstorage) then sits in `Pending: unbound immediate PersistentVolumeClaims`, which cascades: keycloak CrashLoops with no DB → cozystack-api/controller/dashboard never go Ready.

So the correct gate is a live check, not a version branch:

```bash
# Only create defaults if the cluster has none AND nothing else owns the names.
EXISTING_SC=$(kubectl --context $CTX get storageclass --output name 2>/dev/null | wc -l | tr -d ' ')
if [ "$EXISTING_SC" -gt 0 ]; then
  echo "StorageClasses already present — skip (operator or a future chart created them):"
  kubectl --context $CTX get storageclass
else
  echo "No StorageClasses — applying linstor defaults (see manifest below)."
  # apply storageclasses-default.yaml
fi
```

If a future cozystack release does start auto-creating StorageClasses, the live check skips this phase automatically — no version bump to the skill needed. Until then, the skill creates them on every version where the cluster comes up empty.

The skill writes two StorageClasses:

```yaml
# <config-dir>/storageclasses-default.yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: linstor.csi.linbit.com
parameters:
  linstor.csi.linbit.com/storagePool: "${LINSTOR_POOL_NAME}"
  linstor.csi.linbit.com/placementCount: "1"
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: replicated
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: linstor.csi.linbit.com
parameters:
  linstor.csi.linbit.com/storagePool: "${LINSTOR_POOL_NAME}"
  linstor.csi.linbit.com/placementCount: "3"
  linstor.csi.linbit.com/allowRemoteVolumeAccess: "true"
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
```

```bash
kubectl --context $CTX apply --filename "$CONFIG_DIR/storageclasses-default.yaml"
kubectl --context $CTX get storageclass
# Expect:
#   NAME                 PROVISIONER              ... DEFAULT
#   local                linstor.csi.linbit.com   ... false
#   replicated (default) linstor.csi.linbit.com   ... true
```

**Timing — create the StorageClasses inside the Phase 8 watch loop, not after it.** Apply them as soon as `local`/`replicated` are absent and the LINSTOR pools are registered (same gate as the inline pool registration), NOT after "all HRs Ready". stateful HRs in the `paas`/`monitoring` bundles (keycloak, etcd, seaweedfs, vmstorage) request PVCs that stay `Pending` until a default StorageClass exists, so an "all-HRs-Ready → then create SCs" ordering deadlocks the watch loop the same way the LINSTOR pool registration would. Folding SC creation into the loop (gated on `linstor-controller` Ready) lets those PVCs bind and the dependent HRs converge. One subtlety: a PVC created with no `storageClassName` **before** a default SC exists records `storageClassName: ""` and will NOT retroactively pick up a later default — but every cozystack chart pins `storageClassName` explicitly (`replicated`), so in practice the Pending PVCs bind as soon as the named class appears. If you do hit a genuinely class-less Pending PVC, it must be recreated after the default exists.

`replicated` is marked as the default; `local` is a single-replica fallback for system workloads that don't need replication. On clusters with fewer than 3 storage-providing nodes, drop `placementCount` for `replicated` to match — the skill auto-derives this from `cozystack.storage.nodes[]` count.

## Phase 9 — Post-install verification

```bash
kubectl --context $CTX get hr --all-namespaces | grep -v ' True ' || echo "all HRs Ready"
kubectl --context $CTX get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded
```

Confirm the root Tenant patch (applied inline by Phase 8) actually landed:

```bash
kubectl --context $CTX --namespace tenant-root get tenants.apps.cozystack.io root \
  --output jsonpath='{.spec.ingress}'
# Expect: true
```

Spot-check dashboard ingress and certificate:

```bash
kubectl --context $CTX get ingress --all-namespaces | grep dashboard
kubectl --context $CTX get certificate --all-namespaces | grep -E 'dashboard|keycloak'
# Expect: Ready=True.
```

If certificates are still `Ready=False` **after 2 minutes**, do not advise the operator to wait longer — "first issuance takes ~5 min" is a misleading mitigation that hides the actual failure mode. On a healthy install, an ACME HTTP-01 challenge resolves in 10–30 seconds; anything past 2 minutes means the challenge is stuck on a definite cause (rate limit, DNS unreachable, port 80 firewalled, externalIPs mismatch, wildcard config). Inspect the ACME `Challenge` CRs and the cert-manager log directly:

```bash
# Per-domain challenge state — the most direct signal
kubectl --context $CTX get challenges --all-namespaces \
  --output custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STATE:.status.state,REASON:.status.reason,DOMAIN:.spec.dnsName

# Order state — surfaces rate-limit hits and DNS verification failures
kubectl --context $CTX get orders --all-namespaces

# cert-manager log, filtered to ACME activity
kubectl --context $CTX --namespace cozy-cert-manager logs deploy/cert-manager --tail=100 \
  | grep -iE 'acme|challenge|order'
```

Common stuck states and where to look:

| `Challenge.status.state` | Reason in log | Likely cause | Fix |
|---|---|---|---|
| `pending` | `Waiting for HTTP-01 challenge propagation` | DNS not resolving challenge host | Configure wildcard A-record at the registrar |
| `pending` | `dial tcp ...:80: i/o timeout` | port 80 not reachable from LE validators | Open port 80 at firewall / LB |
| `pending` | `connect: connection refused` (RST) | externalIPs on a NAT'd provider (OCI / GCP NAT / AWS EIP) match wrong address | Re-pick external_ips.strategy=internal — see Phase 4 |
| `invalid` | `urn:ietf:params:acme:error:rateLimited` | Let's Encrypt 5-cert-per-week rate limit hit | Wait 7 days, or switch to staging issuer, or `dns01` solver |
| `invalid` | `incorrect response from authoritative server` | wildcard A-record pointing at the wrong IP | Re-verify which IPs cozystack actually advertises with `kubectl get svc -n tenant-root-ingress` |
| `valid` but `Certificate` not Ready | (none — challenge done) | Order Issuing slow (usually <5s) | Wait one more minute; if still stuck, `kubectl describe certificate` for the precise error |

For nip.io hosts: A 2-minute pending challenge is itself anomalous because nip.io DNS is instantaneous. Suspect port 80 firewalling or wrong external IPs first.

That is the operator's fix, not the skill's — DNS / firewall configuration is outside cluster scope. The skill surfaces the diagnosis without speculating on the cause.

## Phase 9.1 — End-to-end reachability probe (mandatory final gate)

"All HelmReleases Ready" is a cluster-side signal — it reports the lifecycle of helm-controller, not whether the dashboard is actually reachable from outside the cluster. Real-world failure modes (OCI 1:1 NAT externalIPs mismatch, DNS not yet propagated, ingress controller running on the wrong nodes) routinely produce Ready=True HRs with an unreachable dashboard. The skill **must** verify reachability before declaring success, otherwise the next operator action is "click the dashboard URL → 530 / RST → debug from scratch", which is the worst possible failure UX.

From the operator's workstation (not from inside the cluster):

```bash
# DNS resolves to expected IPs
EXPECTED_IPS=$(jq -r '.publishing.external_ips[]' <<< "$STATE_JSON" | sort -u)
RESOLVED=$(dig +short "dashboard.${HOST}" | sort -u)

# TCP-level reachability on the canonical port (HTTPS over the ingress).
# %{exitcode} requires curl 7.75+; older curl prints the template literal —
# guard with `curl --version | head -1` if you suspect a pre-2021 workstation.
curl --silent --output /dev/null --write-out '%{http_code} %{exitcode}\n' \
  --connect-timeout 5 --max-time 10 \
  --insecure \
  "https://dashboard.${HOST}/"
```

Pass conditions (any of):

- HTTP 200 / 302 / 401 — dashboard answered (401 is the gatekeeper redirect; that's fine).
- HTTP 200 from `https://api.${HOST}:6443/healthz` with `--insecure` — apiserver ingress is up.

Fail conditions (any of these is `failed_at`, **not** a successful install):

- `curl exit 6` (`Couldn't resolve host`) — DNS not configured. On nip.io this should never happen; on custom-fqdn it means the wildcard A-record isn't published yet. Cross-reference: `RESOLVED` (will be empty).
- `curl exit 7` (`Couldn't connect to host`) — covers both `ECONNREFUSED` (TCP RST — nothing listening at that IP/port) **and** `EHOSTUNREACH` / `ENETUNREACH` (no route to the IP). They look identical at the curl layer; distinguish by checking `ip route get <EXPECTED_IP>` from the workstation:
  - Route returns `unreachable` → no path; workstation can't actually reach the cluster (firewall, VPN not up).
  - Route returns a normal egress → RST; almost always externalIPs misconfig on a NAT'd provider. Cross-reference: `cozystack_intake.external_ips.strategy` and `Node.status.addresses`.
- `curl exit 28` (`Timeout`) — packets reach the destination IP but no SYN/ACK comes back. Usually port 443 firewalled at the cloud-provider security group level; can also be wrong IPs in DNS (`EXPECTED_IPS` ≠ `RESOLVED`).
- HTTP 530 (Cloudflare-style "origin unreachable") — DNS points through a CDN to wrong upstream.
- HTTP 502 / 503 — ingress is up but backend isn't ready; usually transient, retry once after 30 s. Persistent 502/503 (over 2 min) → real failure.

When the probe fails, write `failed_at: "external-reachability"` with `error_detail` containing the curl output, the resolved-vs-expected IP set, and the `Node.status.addresses` mismatch (if any). The cluster stays as-is — no rollback — and `cozystack:debug` gets dispatched by the wizard.

For sandbox / nip.io installs where the operator deliberately picked a non-routable address (`192.168.x.x` on a home LAN where the workstation can reach the cluster), the operator can pass `--skip-external-reachability` to downgrade the probe to a warning. The skill prints the warning and still writes `completed_at`, but the Phase 10 NOTES carry a "external reachability not verified — operator opted out" line so the result is auditable.

## Phase 9.2 — Write status.cluster-install (mandatory)

Before printing Phase 10 NOTES, the skill **must** write exactly one of `completed_at` / `failed_at` to `<config-dir>/.state.yaml`. This is the contract `cozystack:wizard` Phase 5 dispatch loop relies on — without it the chain hangs at the next dispatch decision (no `completed_at` ⇒ no progression; no `failed_at` ⇒ no `cozystack:debug` auto-dispatch).

Success path (every gate from Phase 8 + Phase 9 passed):

```yaml
status:
  cluster-install:
    dispatched_at: <existing-ISO-from-wizard>
    completed_at:  <ISO_TS_UTC_NOW>
    installer_version: <INSTALLER_VERSION>
    platform_variant:  <PLATFORM_VARIANT>
    bundles:           [...]
    helm_releases:     { ready: <N>, total: <N> }
```

Failure path (any STOP GATE refused, any Phase 8 HR stuck past timeout, any Phase 9 verification failed):

```yaml
status:
  cluster-install:
    dispatched_at: <existing-ISO-from-wizard>
    failed_at:     <ISO_TS_UTC_NOW>
    error:         "<one-line summary; what gate / which HR / which check>"
    error_detail:  "<optional multi-line; kubectl describe output, log excerpt>"
```

Write with `sops --encrypt --in-place` afterwards when `state.sops.enabled: true`. Never write both fields. Never leave both unset.

## Phase 10 — NOTES-style access summary

Lean. Entry points, file paths, where credentials live, where to read more. No prose paragraphs.

```text
cozystack ready

cluster:
  context:           $CTX
  api:               $API_URL
  installer:         oci://ghcr.io/cozystack/cozystack/cozy-installer:$VERSION
  installer variant: $INSTALLER_VARIANT
  platform variant:  $PLATFORM_VARIANT  (bundles: $BUNDLES_CSV)
  nodes:             $N ready  |  helmreleases: $M / $M ready

access:
  dashboard:   https://dashboard.$HOST
  api:         $API_ENDPOINT
  grafana:     https://grafana.$HOST          (if monitoring HR ready)
  cert solver: $SOLVER                         (http01 / dns01)
  tls certs:   $CERT_READY_COUNT / $CERT_TOTAL Ready  (cert-manager — first issuance can take ~5 min)

storage (ZFS):
  per-node:    $N × zpool '$POOL_NAME' ($LAYOUTS)
  linstor:     storage pool '$LINSTOR_POOL_NAME'
  verify:      kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- linstor storage-pool list

api server HA:
  apiServerHost: $API_HOST  ($API_HOST_SOURCE)
  # On generic with extractedprism (default), every node dials 127.0.0.1:7445 and the DaemonSet
  # forwards to a healthy CP endpoint. To remove extractedprism later:
  #   helm --kube-context $CTX uninstall extractedprism --namespace kube-system
  # (and re-apply the cozy-installer chart with the operator's chosen apiServerHost).
  verify:      kubectl --context $CTX --namespace kube-system get daemonset extractedprism 2>/dev/null \
                 || echo "extractedprism not installed (Talos KubePrism / operator override / hosted variant)"

credentials:
  keycloak admin (initial):
    kubectl --context $CTX --namespace cozy-keycloak get secret keycloak-credentials \
      --output jsonpath='{.data.admin-password}' | base64 --decode; echo
  dashboard sso:    SSO via Keycloak — first user provisioned by tenant-root

artifacts on disk:
  values file:       <config-dir>/cozystack-platform-package.yaml
  helm release:      kube-system/cozy-installer
  cluster-scoped:    package.cozystack.io/cozystack.cozystack-platform

handy commands:
  watch state:       kubectl --context $CTX get hr --all-namespaces
  operator logs:     kubectl --context $CTX --namespace cozy-system logs deploy/cozystack-operator -f
  list tenants:      kubectl --context $CTX get tenants.apps.cozystack.io --all-namespaces

next:
  docs:              https://cozystack.io/docs/v<X.Y>/
  first tenant:      https://cozystack.io/docs/v<X.Y>/getting-started/install-cozystack#51-setup-root-tenant-services
  upgrade later:     run cozystack:cluster-upgrade
```

Fill all `$placeholders` from collected values and live lookups. Drop lines whose preconditions weren't met (e.g. omit grafana line when the `paas` bundle was not enabled).

## Error handling — upstream issue handoff

If any phase hits a fatal failure that looks like an upstream bug or doc gap, follow `references/issue-templates.md`:

1. Stop the current phase. Don't try further fixes.
2. Run the diagnostic-bundle script. Show the bundle path.
3. Pick the right repo from the routing table.
4. Render the matching issue-body template, fill placeholders from collected state, write to `/tmp/.../issue-body.md`. Show the rendered text to the user.
5. Print the exact `gh issue create` command but **do not execute it**.

## Guardrails

- NEVER apply, patch, label, install, or delete without showing the exact command and getting explicit user approval. Prior approval does not carry forward.
- NEVER overwrite values, namespaces, or labels that belong to another Helm release. Refuse, surface ownership, and let the user decide.
- NEVER skip a STOP GATE because earlier gates passed cleanly.
- NEVER assume current `kubectl` context is the right one — pin `--context` in every command, every time.
- NEVER call success while any HR is not Ready, even on a 59-minute clock.
- NEVER open a GitHub issue automatically. Draft, show, hand the command to the user.
- NEVER include private infrastructure names (cluster name, client, internal namespaces) in drafted public issue bodies. Replace with generic placeholders.
- NEVER create a storage pool without explicit per-node approval in Phase 5.5 — even if the operator approved the consolidated plan in Phase 5. Plan approval does not cascade into mutations.
- NEVER `zpool create` over an existing pool. If `zpool list` shows the target name already exists, refuse and ask the operator to either pick a different name, reuse the existing pool, or destroy it manually with `zpool destroy` + `wipefs` (`references/storage-backends.md` backout section).
- NEVER offer LVM / LVM-thin as a storage backend. Cozystack standardises on ZFS; LVM paths were removed because cozystack does not validate or document them. Operators who need LVM are on their own with the piraeus-operator CRD.
- NEVER bootstrap Talos nodes or invoke `boot-to-talos` / `talm` from inside this skill — that flow lives in `/cozystack:talos-bootstrap`. Refuse and hand off.
- NEVER auto-rollback a partially provisioned storage state — print backout commands and let the operator decide.
- NEVER accept a custom `publishing.host` without an explicit operator confirmation that they own the domain and will configure wildcard DNS — the HTTP-01 cert solver fails silently otherwise. nip.io patterns skip this gate because nip.io is publicly hosted DNS.
- ALWAYS patch `tenants/root.spec.ingress=true` from inside the Phase 8 watch loop as soon as the CR appears, on `system`-bundle installs. The OIDC chicken-and-egg makes Phase 8 unreachable otherwise — dashboard / keycloak / flux-plunger loop forever, every other downstream HR stalls on the missing root ingress. The CR can appear at any point during the watch loop; do not gate the patch behind a fixed pre-Phase-8 wait.
- ALWAYS read variant overlays and `requirements.md` before declaring "this looks fine" — variant-specific checks (CP-label value, ZFS availability, KubeOVN MASTER_NODES) are easy to miss.
- ALWAYS pull live data over cached assumption: `kubectl get` over "I think this is …".
- ALWAYS write Phase 4 collected values to disk in `<config-dir>/cozystack-platform-package.yaml` before applying — the file is part of the diagnostic bundle if Phase 8 fails. ZFS pool registration is stored separately under `<config-dir>/.state.yaml` `cozystack.storage.nodes[]` and replayed by the Phase 8 post-Ready hook (there is no `LinstorSatelliteConfiguration` CR for the ZFS path).
- NEVER silently fall back to plain writes when `state.sops.enabled` is true but `sops` is missing. Refuse Phase 4 and tell the operator to install `sops` + the configured age/PGP key, or re-invoke with `--no-sops`.
- NEVER leave plain `<config-dir>/cozystack-platform-package.yaml` on disk between Phase 4 and Phase 7 when sops is on. Decrypt to a temp file for `kubectl apply`, remove the temp file immediately after.

## References

- `references/requirements.md` — cluster + node + variant matrix.
- `references/node-checks.md` — exact `kubectl debug node` commands and value thresholds.
- `references/variants.md` — picker logic and what each variant deploys.
- `references/values-template.md` — canonical chart values, Platform Package YAML, extractedprism values shape, and the ZFS pool registration hook.
- `references/storage-backends.md` — ZFS pool create / verify / backout commands run in Phase 5.5. Cozystack standardises on ZFS; LVM paths are explicitly out of scope (the doc spells out why). Talos privileged DaemonSet bootstrap pattern lives here.
- `references/provider-pitfalls.md` — provider-specific networking and runtime gotchas: OCI 1:1 NAT, GCP NAT'd external IPs, AWS EIP / NLB proxy-protocol, Talos system-extension namespacing, PSA baseline on k8s 1.25+, talosctl reset preserving user disks, cozystack v1.3.x quirks. Cross-referenced from Phase 4 publishing slot and Phase 5.5 storage.
- `references/helmrelease-monitoring.md` — polling pattern, stuck-state triage.
- `references/known-failures.md` — top failures with recovery commands.
- `references/issue-templates.md` — diagnostic bundle script and issue-body templates per upstream repo.

External:

- `https://cozystack.io/docs/v1.3/install/kubernetes/generic/` — primary install guide.
- `https://cozystack.io/docs/v1.3/install/hardware-requirements/` — hardware sizing.
- `https://github.com/cozystack/cozystack` — chart, operator, packages.
- `https://github.com/cozystack/ansible-cozystack` — node-prep playbooks.
