---
name: wizard
description: Use this as the entry point for installing Cozystack from scratch. Asks one question — Talos / Ubuntu / Existing cluster — then dispatches the right chain of skills. Routes are `talos-bootstrap → cluster-install` (Talos), `ubuntu-bootstrap → cluster-install` (Ubuntu/Debian; ubuntu-bootstrap wraps cozystack/ansible-cozystack), or `cluster-install` direct (existing self-managed or managed k8s). All artifacts (inventory.yml, kubeconfig, .state.yaml, cozystack-platform-package.yaml) live in a cluster config directory the operator picks, so the result is a directory they can manage as code in their own git workflow. Refuses for clusters that already run Cozystack and points the operator at `cozystack:cluster-upgrade`.
argument-hint: "[--config-dir=<path>] [--target=<talos|ubuntu|existing>] [--sops] [--no-sops] [--allow-ephemeral] [--resume]"
---

# cozystack:wizard

Work in reasoning mode. Use the phrasing `cozystack:wizard` (not "the skill"). Announce phase transitions: `cozystack:wizard Phase N — <name>`.

This is the orchestrator. It does not perform mutations on its own — every concrete step is delegated to a downstream skill in the chain. The wizard interviews, builds the route, persists state to `<config-dir>/.state.yaml`, and hands off to the next skill in turn.

> **Note on language in this SKILL.md** — every operator-facing prompt below is written in English for clarity. At runtime the skill matches the operator's natural language detected from prior conversation messages (per Core Principle "Match the operator's natural language" below). Treat the English text as a template for tone, structure, and content; the LLM translates while preserving meaning. Code identifiers, command examples, file paths, and any text destined for GitHub stay canonical (English) regardless of operator language.

## Cluster config directory — the artifact contract

Every cluster `cozystack:wizard` touches has a directory on the operator's workstation:

```
<config-dir>/
  .gitignore                          # skill-managed; excludes secrets + state
  .state.yaml                         # chain progress (gitignored)
  inventory.yml                       # ubuntu route — ansible inventory
  kubeconfig.yaml                     # bootstrap output (gitignored)
  nodes/                              # talos route — per-node machine-config
  talosconfig                         # talos route (gitignored)
  cozystack-platform-package.yaml     # cluster-install output
  extractedprism-values.yaml          # cluster-install Phase 5.6
```

Git is **out of scope** — the skill never runs `git init` / `git add` / `git commit`. The `.gitignore` it writes is a plain text file with sensible exclusions; harmless without git, ready when the operator decides to use it.

## Core principles

- Match the operator's natural language. Detect from the conversation context — the language they wrote in for any prior turn. Use it in every interactive prompt, AskUserQuestion option label, summary, and gate message. Never ask "what language?" separately; just match. Code identifiers, command examples, file paths, and any text that goes to GitHub stay in their canonical form (usually English). When the wizard writes `state.operator_language`, every downstream skill reads it from there.
- One valid path → just do it. Don't gate on an approval question when there's only one sensible next step. Keep the AskUserQuestion shape for (a) multi-option choices the operator actually makes, (b) destructive operations (`talosctl reset`, `zpool destroy`, `kubectl delete` on prod-context, anything in a `prod`-labelled context), (c) plan presentation before a long batch. Otherwise proceed. "I'll wait for you to say done, ok?" is not a gate; it's friction. Just check.
- Front-load the interview. **Every question the skill might ask in any later phase is asked once up front** in a single intake phase, before any execution. Run all read-only lookups first (cluster probes, node enumeration, file checks), merge with `intent_hints` from Phase 0, then present **one consolidated summary** with every slot filled (defaults marked Recommended) and quick-edit affordances (`Approve / Edit <slot> / Cancel`). Fall back to a discrete AskUserQuestion only when both lookup AND hints failed to fill a slot. Later phases consume the collected answers and never re-prompt — per-node storage devices, per-node boot methods, sops opt-in, kubeconfig merge target, all of it lives in the intake.
- Operator-facing only. Talk to the operator, never to the cluster directly.
- One state file per cluster, lives in `<config-dir>/.state.yaml`. Every downstream skill reads and updates it.
- Idempotent transitions. `--resume` re-reads state and continues from the next not-yet-completed step.
- Never silently choose a route. The route is always shown and approved before the first delegation.
- Three routes only (after the v1 refactor). Anything more nuanced lives in the downstream skill, not in the wizard.

## Phase 0 — Free-form context

Before any structured question, ask the operator to describe the situation in their own words:

```text
Before we dive into structured questions — tell me, in your own words,
what you want to install and what's already in place.

Anything you mention here I'll use to pre-fill the rest of the interview so
you don't have to repeat yourself. Examples of useful things to share:

  - Hardware / hosting: bare-metal, cloud VMs, specific provider, count of nodes.
  - OS: Talos / Ubuntu / something else.
  - Existing Kubernetes: yes/no, which distribution.
  - Constraints: GPU workload, no public domain, air-gapped, etc.
  - Previous attempts: anything that failed before that we should know about.

If you're not sure of details, that's fine — say what you know.
```

Surface this question in the operator's natural language (see Core principles below). Don't translate the prompt into English if the operator was writing in Russian; ask in their language and accept the answer in their language.

Parse the free-form answer for hints. Common extracts:

| What operator said | Phase used | Pre-fill |
|---|---|---|
| "3 Hetzner servers running Ubuntu 24.04" | Phase 2 target | `bare-metal-ubuntu`; Phase 4 inventory size 3 |
| "we have k3s already running" | Phase 2 target | `existing` (and distribution=k3s); skip the bootstrap step in chain |
| "Talos on bare-metal, 5 nodes" | Phase 2 target | `bare-metal-talos`; 5 nodes |
| "GPU workload, nvidia 4090" | Phase 2 OS hint | hint: pick Ubuntu over Talos (NVIDIA driver paths simpler) |
| "no domain yet" | Phase 4 publishing.host | suggest nip.io path |
| "tried before, dashboard never came up" | Phase 5 | start with `/cozystack:debug` after Phase 2 picks the cluster |
| "I want to use my existing kubeconfig at ~/.kube/lab" | Phase 1 | use `$PWD` of that file's dir; Phase 2 → existing target |
| "this is for production, we need HA" | Phase 4 | warn on single-CP; insist on 3+ CP |

Record extracted hints to `state.intent_summary` (a short paragraph the operator confirmed) and `state.intent_hints` (the parsed key/value pairs):

```yaml
intent_summary: "Operator wants to install Cozystack on 3 Hetzner Ubuntu 24.04 servers, no GPU, no public domain (will use nip.io). Has tried before, dashboard never came up."
intent_hints:
  target: "bare-metal-ubuntu"
  node_count: 3
  distribution_hint: "k3s"
  domain_hint: "nip.io"
  prior_failure: "cozy-dashboard/dashboard never reached Ready"
```

Don't over-extract. If the operator's free-form is vague, summarise what's there and move on — the structured questions cover the rest. If the operator says "I don't know, just walk me through it" — record `intent_summary` as that phrase and skip the hints; rely entirely on Phase 2 onwards.

After parsing, echo the summary back to the operator **inline** with the next question — do **not** demand a separate confirmation. A single "looks right?" between every wizard phase compounds to 5–6 yes/no checks per session, which is friction the operator already complained about. The single explicit approval point is Phase 4 consolidated intake review, where every extracted hint and every collected slot get verified at once.

```text
got it:

> <intent_summary>

Next: where should I keep cluster config for this install?

  1. $PWD                                         (current directory)
  2. ...
```

Adjust phrasing per language. The operator's answer to Phase 1's question moves the chain forward; if they want to fix the parsed summary, they can say so in free form and the skill re-parses without a "no/yes" gate.

## Phase 1 — Pick the cluster config directory

Ask the operator where the cluster config goes:

```text
Where should cozystack:wizard keep cluster config for this install?

  1. $PWD                                         (current directory)
  2. $PWD/<cluster-name>                          (subdirectory under current directory)
  3. Other — type a path
  4. Scratch dir under $TMPDIR (will be lost on reboot — test runs only)

Operator hint: options 1–3 want somewhere git-able. The skill won't touch git
itself, but all artifacts written there are designed to be committed.
Option 4 is for sandbox / throwaway runs where surviving the next reboot
doesn't matter. The skill warns once and proceeds.
```

If option 2 (subdir) — also ask for cluster name (default `cozystack-lab`). If option 3 — validate the path is writable; offer to mkdir.

Resolve to absolute path. Record as `state.config_dir`.

If `<config-dir>/.state.yaml` already exists:

- If `--resume` was passed — go straight to Phase 5 dispatch from the next pending step.
- Else, if the state file is `< 24h` old, offer `Resume previous session (target=$T, route=$R, $X/$Y steps complete) / Start fresh (wipe .state.yaml only — other files stay) / Cancel`.
- Else (older than 24h, or `Start fresh`) — overwrite `.state.yaml` only, leave other files alone.

Initialise `.gitignore` if missing or lacks the cozystack section (see ubuntu-bootstrap Phase 2 for the exact block). The exact content of the cozystack section depends on whether sops is enabled in Phase 1.5 — leave a placeholder until then.

## Phase 1.5 — Sops opt-in

Skip if `--no-sops` was passed. Run if `--sops` was passed; otherwise ask:

```text
Wrap secrets with sops? (encrypted-in-tree instead of gitignored)

Cozystack:wizard writes several files that contain (or may contain) secrets:
  - kubeconfig.yaml          (TLS certs + tokens)
  - .state.yaml              (collected values; may carry tokens, SSH key path)
  - inventory.yml            (Ubuntu route; k3s join token, maybe ansible_become_password)
  - cozystack-platform-package.yaml  (any operator-supplied creds in values)
  - extractedprism-values.yaml       (rare; included for symmetry)

Talos artefacts (talosconfig, secrets.yaml under nodes/) are already covered
by talm — it respects .sops.yaml when present in the same directory.

Without sops: secret files stay gitignored (operator stores them outside git).
With sops:    secret files are encrypted in place after every write with your
              age public key; the encrypted forms can be committed safely.
              Decryption is automatic when sops finds your age private key
              (~/.config/sops/age/keys.txt or $SOPS_AGE_KEY_FILE).

Options:
  - Yes, enable sops (Recommended for shared cluster configs in git)
  - No, use .gitignore (Recommended for solo workflows)
```

On `No` — write the cozystack `.gitignore` section that excludes `kubeconfig.yaml`, `.state.yaml`, `inventory.yml`, `talosconfig`, `secrets.yaml`. Record `state.sops = {enabled: false}`. Continue to Phase 2.

On `Yes`:

1. **Verify tools** — `sops --version` and `age --version` must succeed. If either is missing, refuse opt-in with the install pointer (`brew install sops age` on macOS; `https://github.com/getsops/sops/releases` and `https://github.com/FiloSottile/age#installation` otherwise). Operator can re-run with `--no-sops` to skip.

2. **Resolve age key** — search in this order, surface each result to the operator and confirm which one to use:

   1. `<config-dir>/.sops.yaml` — if present, read `creation_rules[].age` recipients.
   2. `$SOPS_AGE_KEY_FILE` env var — if set, read the file's `# public key: age1...` comment.
   3. `~/.config/sops/age/keys.txt` — standard sops/age location.
   4. None of the above — print a generation command and ask approve:

      ```bash
      mkdir -p ~/.config/sops/age
      age-keygen --output ~/.config/sops/age/keys.txt
      chmod 0600 ~/.config/sops/age/keys.txt
      ```

      Show the resulting public key + a warning: **the private key in `~/.config/sops/age/keys.txt` is your only way to decrypt these files. Back it up before committing anything encrypted.**

   Ask the operator to confirm the public key shown is correct (paste-back the `age1...` string). Do not proceed on guesswork.

3. **Write `<config-dir>/.sops.yaml`** with creation_rules covering the cozystack secret-files (see `references/sops.md` for the exact block). If the file already existed, merge — don't overwrite — preserving any custom rules the operator added.

4. **Record state**:

   ```yaml
   sops:
     enabled: true
     recipients: ["age1abc...", "age1def..."]   # everyone who can decrypt
     config_path: "<config-dir>/.sops.yaml"
   ```

5. **Write the cozystack `.gitignore` section** without the secret-file lines (they're encrypted-in-tree now). When sops is on, `talosconfig`, `secrets.yaml`, `kubeconfig.yaml`, `.state.yaml`, `inventory.yml`, `cozystack-platform-package.yaml`, `extractedprism-values.yaml`, and `nodes/*.yaml` are all encrypted by talm or by the skill's own `maybe_encrypt` helper — they're commit-friendly and stay out of `.gitignore`. Only `*.tar.gz` (diagnostic bundles) stays ignored. See `references/sops.md` for the per-file decision matrix.

## Phase 2 — Target (the only real question)

If `state.intent_hints.target` was already extracted in Phase 0, **do not ask a separate "right?" confirmation here**. The Phase 0 echo already had the operator confirm `intent_summary`; asking the same question again ("from your description it looks like X — right?") is friction. The Phase 4 consolidated intake review is the single confirmation point — every extracted hint, the inferred target, and every collected slot land there, and the operator approves the whole picture once.

If `state.intent_hints.target` was **not** extracted (operator was vague at Phase 0), single AskUserQuestion:

```text
What's the target environment?

  1. Bare-metal Talos                  — nodes will run Talos Linux, no Cozystack yet
  2. Bare-metal Ubuntu / Debian        — nodes run Ubuntu/Debian, no Kubernetes yet
                                          (ubuntu-bootstrap wraps cozystack/ansible-cozystack)
  3. Existing Kubernetes cluster       — kubectl works, no Cozystack yet
                                          (includes managed: EKS / GKE / AKS / DOKS)
  4. Existing Cozystack cluster        — already installed, want to upgrade

Recommended-by-load hints (operator can override):
  - General-purpose / VMs / databases  → Talos (rec)
  - GPU / custom userspace             → Ubuntu (rec)
```

For target 4 (existing Cozystack), **refuse** and point at `cozystack:cluster-upgrade`. Do not enter the chain.

For target 3 (existing k8s), do a quick read-only probe:

- Show `kubectl --context $CTX get nodes -o wide` and `kubectl get ns cozy-system --ignore-not-found`.
- If `cozy-system` namespace exists and holds pods → refuse, point at `cozystack:cluster-upgrade`.

Record `state.target`.

## Phase 3 — Route build

Map target to a chain:

| Target | Chain |
| ----------- | ----------- |
| Bare-metal Talos | `talos-bootstrap` → `cluster-install` |
| Bare-metal Ubuntu / Debian | `ubuntu-bootstrap` → `cluster-install` |
| Existing Kubernetes (self-managed or managed) | `cluster-install` |
| Existing Cozystack | refuse → `cozystack:cluster-upgrade` |

Record `state.route`. Print the chain with rough time estimates and which skill owns which side-effects:

```text
cozystack:wizard route

  target:    bare-metal-ubuntu
  chain:
    1. cozystack:ubuntu-bootstrap    (~30–60 min)
       └─ wraps cozystack/ansible-cozystack — OS prep, drbd-dkms / ZFS / KubeVirt modules,
          k3s install with cozystack-compatible flags, kubeconfig retrieval
    2. cozystack:cluster-install      (~30–60 min)
       └─ ZFS pool per node, extractedprism, cozy-installer chart, Platform Package,
          tenant root ingress patch, wait HRs

  config dir: /Users/me/cozystack-lab
  state file: /Users/me/cozystack-lab/.state.yaml

  options: Continue / Edit (change target) / Cancel
```

## Phase 4 — Full intake (everything policy-decidable up front)

Front-load is non-negotiable. Every slot that an operator can decide **before the cluster exists** is collected here, in one consolidated screen, and written to `.state.yaml` under `inventory`, `cluster`, and `cozystack_intake`. Downstream skills read these on entry and only ask the operator again for slots that need post-bootstrap discovery (actual device paths from a running Talos node, KubeOVN label mismatch, etc.) or for STOP GATEs that are destructive by nature.

The intake has two layers — **bootstrap-stage** (depends on `route`) and **cozystack-stage** (route-independent policy). Both are filled in this phase.

### Bootstrap-stage slots (per route)

For `talos-bootstrap` first:

- **Node list**: IPs/hostnames, role (cp/worker), optional name.
- **Reach mode**: how the workstation reaches nodes — `public` (workstation has public network access to nodes' public IPs), `internal` (workstation is inside the VCN/segment, reaches private IPs), or `vip` (only the VIP is reachable; nodes are behind NAT). Determines the IP set used for `talosctl --nodes`.
- **CP endpoint**: VIP / single-CP IP / external LB IP. Used for `talm init --cluster-endpoint` and lands in machine-config.
- **VIP details** if applicable: VIP address, link to advertise on (`ens5`, `eth1`, …), subnet, MTU if non-default. **Per-node VIP-link static addresses** — on cloud providers where the VIP-carrying interface in maintenance mode lacks an IPv4 (OCI VLAN secondary interfaces are the canonical case), record one address per node in the same `/N` as the VIP subnet (e.g. `10.17.100.11/24` for node0, `10.17.100.12/24` for node1, …). Without these, `talm template` renders a `LinkConfig` with no `addresses:` block and node1+ never reach the VIP — etcd join hangs in `Preparing`. The wizard explicitly asks "does the VIP link have an IPv4 in maintenance mode?" and offers `Auto-allocate from VIP subnet (skip the first N reserved for the VIP)` as the default. Recorded as `intent_hints.vip.per_node[<node-name>]`.
- **Boot method per node** (only when needs-OS-install): OCI custom image / boot-to-talos / iPXE / "already in maintenance mode" / "already configured — reuse".
- **`talosctl` + `talm` on workstation**: confirm presence.

For `ubuntu-bootstrap` first:

- `inventory.nodes` (host, role cp/worker), `inventory.ssh_user`, `inventory.ssh_key`. Recommended HA — 3 CP nodes (embedded etcd raft).

For `cluster-install` first (existing k8s target):

- `cluster.context` — default `kubectl config current-context` with confirmation.

### Cozystack-stage policy slots (route-independent, **always asked**)

These were historically asked by `cluster-install` Phase 4 *after the cluster existed* — that re-prompted the operator for things they already knew up front. They are policy choices, not discovery-dependent, so they belong here:

- **Bundles** (multiSelect): `system`, `paas`, `iaas`, `naas`. Default per variant overlay (`isp-full` includes all four). The variant is derived from `state.target` + `intent_hints.workload_class`.
- **Storage layout preference** (Talos / Ubuntu routes only): for each node that will provide storage, ask the layout when more than one is plausible — `single` (Recommended for dev), `mirror` (Recommended for prod on 2-disk nodes), `raidz` (3+ disks). Default `single`. Exact device paths are deferred to `cluster-install` Phase 5.5 because they require post-boot probing; the **preference** is recorded here and Phase 5.5 just picks the largest unmounted disk(s) that fit the layout. ZFS pool name and LINSTOR storage-pool name default `data` and are rarely changed.
- **Publishing host kind**: `nip.io` (Recommended for sandbox; no DNS configuration needed) vs `custom-fqdn` (operator owns the domain). When `custom-fqdn` — collect the FQDN and run the **domain-ownership gate** here, not in `cluster-install` (the operator commits to configuring DNS for it before Phase 8 of cluster-install reaches dashboard/keycloak HRs).
- **External IPs strategy**: on Talos / Ubuntu routes, when nodes have distinct `InternalIP` and `ExternalIP` (typical on OCI, GCP with external NAT, AWS with EIPs), ask:
  - `internal` (Recommended for NAT-fronted clouds) — Service `externalIPs` are the nodes' VCN-internal addresses. NAT on the provider fabric (OCI 1:1 NAT, GCP NAT'd public IP, AWS EIP) rewrites packets before they reach the node, so the kernel only ever sees the internal IP; Cilium's externalIPs BPF must match on that. Picking public IPs here is the single most painful misconfiguration on these providers — symptom is `Connection refused` (kernel RST) on `https://dashboard.<host>/` even though every HelmRelease is Ready.
  - `external` (use external/public IPs) — only when the nodes' public IPs are routed onto the interface (bare-metal, Hetzner with direct public IP, dedicated server with no NAT).
  - `explicit` — operator supplies the list (MetalLB pool, external LB VIP).
  - The wizard probes `kubectl get nodes -o jsonpath` on Talos / Ubuntu routes after Phase 5 bootstrap completes to confirm the chosen IPs are present on the cluster's node objects, but the *choice* is asked here.
- **Cert solver**: `http01` (Recommended — works with public DNS + port 80) vs `dns01` (works on internal networks, requires DNS-provider creds wired into cert-manager values). On nip.io always `http01`. On `custom-fqdn` default `http01`, ask if operator wants `dns01`.
- **Exposed services** (multiSelect): `api`, `dashboard`, `vm-exportproxy`, `cdi-uploadproxy`. Default `api,dashboard`.
- **Networking CIDRs** (collapsed by default; ask only if operator explicitly wants non-defaults). **Read defaults from the cozystack source** — do not hardcode. The skill greps for the canonical values in this resolution order:

  1. `~/git/github.com/cozystack/cozystack/packages/core/platform/values.yaml` (operator's local clone)
  2. `~/git/github.com/cozystack/cozystack/packages/core/kubeovn/values.yaml` (older layouts)
  3. URL fallback `https://raw.githubusercontent.com/cozystack/cozystack/<release>/packages/core/platform/values.yaml` (HTTP fetch, cached for 24 h alongside `state.research_cache`)

  ```bash
  POD_CIDR=$(yq '.kubeovn.podCIDR // .cozystack.podCIDR // ""' "$COZYSTACK_VALUES")
  SVC_CIDR=$(yq '.kubeovn.serviceCIDR // .cozystack.serviceCIDR // ""' "$COZYSTACK_VALUES")
  JOIN_CIDR=$(yq '.kubeovn.joinCIDR // ""' "$COZYSTACK_VALUES")
  ```

  cozystack v1.3.3 ships `podCIDR: 10.244.0.0/16`, `serviceCIDR: 10.96.0.0/16`, `joinCIDR: 100.64.0.0/16`. Hardcoded `10.42.x` / `10.43.x` (k3s defaults) would mismatch and break Cilium pod-network reconciliation.

  Surface the resolution to the operator with the source path so they know which file informed the default:

  ```text
  podCIDR:    10.244.0.0/16      (default from cozystack@v1.3.3/packages/core/platform/values.yaml:42)
  serviceCIDR: 10.96.0.0/16      (default from same)
  joinCIDR:   100.64.0.0/16      (default from same)
  ```

  Most operators take the defaults; on Edit, validate the new CIDR doesn't overlap with host networks the cluster sees.
- **API server endpoint**: default `https://api.<publishing.host>:6443`. Explain it lands in client kubeconfigs.
- **extractedprism opt-out**: default `enabled` on generic / on Talos always disabled (KubePrism built in). Operator can flip to `--no-extractedprism` and supply a single CP IP / VIP / external LB IP themselves.

### Consolidated review

Render every slot above on a single screen. Defaults marked `(default)`. The operator answers `Approve all` to proceed, or `Edit <slot>` to fix one and re-render.

```text
cozystack:wizard — collected values for the whole chain

target:                       bare-metal-talos
chain:                        cozystack:talos-bootstrap → cozystack:cluster-install
operator language:            ru
config dir:                   /Users/me/cozystack-lab
sops:                         disabled

bootstrap (talos route):
  nodes:                      3 (all cp+workload)
    node0  10.17.100.11/24 (VIP-link static) — public 158.101.x  internal 10.17.0.128
    node1  10.17.100.12/24                    — public 129.158.x internal 10.17.0.27
    node2  10.17.100.13/24                    — public 157.151.x internal 10.17.0.173
  reach mode:                 public  (workstation talks to nodes' public IPs via talosctl)
  cp endpoint:                https://10.17.100.10:6443  (shared VIP)
  vip link:                   ens5  10.17.100.0/24
  boot method:                already-in-maintenance-mode  (all 3 nodes)

cozystack-stage policy:
  bundles:                    system, paas, iaas, naas  (isp-full)
  storage layout (per node):  node0 single, node1 single, node2 single  (Recommended for 1-disk nodes)
  zpool / linstor name:       data / data
  publishing host:            10-17-0-128.nip.io        (kind: nip.io — DNS auto-resolves)
  external IPs strategy:      internal  (10.17.0.128, 10.17.0.27, 10.17.0.173)
                              ↑ OCI 1:1 NAT — public IPs would not match Cilium externalIPs
  cert solver:                http01
  exposed services:           api, dashboard
  api server endpoint:        https://api.10-17-0-128.nip.io
  extractedprism:             enabled (default for generic)
  networking CIDRs:           podCIDR=10.244.0.0/16 serviceCIDR=10.96.0.0/16 joinCIDR=100.64.0.0/16  (defaults read from cozystack@v1.3.3/packages/core/platform/values.yaml)

options:
  - Approve all — write .state.yaml, proceed to Phase 5 dispatch
  - Edit <slot> — e.g. Edit external IPs strategy, Edit publishing host
  - Cancel
```

Write the approved values to `<config-dir>/.state.yaml` under `inventory`, `cluster`, and the new top-level `cozystack_intake` (see `references/state-schema.md`). Downstream skills read these on entry and skip questions whose answers are already there. The cluster-install Phase 4 then becomes a fast-path: re-render the same summary read-only, ask `Approve / Edit <slot>` once, and proceed.

## Phase 4.5 — Active research on the specific combination (read-only, skeptical)

Before Phase 5 dispatch, run a focused research pass against the concrete combination the operator picked: `target` × `intent_hints.platform` × `cozystack_intake.installer_variant` × `state.cluster.k8s_version` / `talos_version` × the specific bundles. The goal is to surface **known landmines for this combination** so the operator hears about them before execution starts, not after a 30-minute install fails on something well-documented.

This phase is **read-only and time-boxed**. It does not mutate state, does not contact the target cluster, and finishes in under ~2 minutes. If research stalls or returns nothing useful, the phase completes silently — its absence does not block the install.

### Why this is at runtime, not bundled

Skills do not ship a static knowledge base of "known issues per platform". That data ages quickly (Cozystack releases monthly; Talos releases monthly; provider behaviour changes), and operators install across versions and providers the skill author never tested. Instead the wizard does the research **at the time of install**, against the actual versions in play, with current docs and current upstream issue trackers.

The skill's job is to know **how to look** and what to **skeptically verify** — not to memorise answers.

### Sources to consult, in order of trust

1. **Operator's local clones if present** — `~/git/github.com/cozystack/website/content/en/docs/v{MAJOR.MINOR}/`, `~/git/github.com/cozystack/cozystack/` (for source-of-truth on chart values, release notes), `~/git/github.com/cozystack/talm/`. Grep for the platform / scenario terms (`oci`, `hetzner`, the chosen variant). Local clones are highest trust — they're the actual docs for the version the operator picked, not a possibly-stale model recollection.
2. **Upstream issue trackers** — `gh issue list --repo cozystack/cozystack --state open --search "<platform> <version>"`, same for `cozystack/talm`, `piraeusdatastore/piraeus-operator`. Open issues at install time are landmines the operator can avoid by adjusting their plan.
3. **Web search** — only when local clones and issue trackers don't cover the combination. Search forms:
   - `"cozystack v1.3" "<platform>" issue` — find blog reports and discussions
   - `"talm" "<provider>" maintenance mode` — provider-specific Talos quirks
   - `"piraeus" "<distro> <kernel-version>"` — DRBD/kernel-module compatibility
4. **The operator's own prior conversation** — `intent_summary` may have mentioned a previous failed attempt; reference that explicitly in the research scope.

### Skeptical verification rules — non-negotiable

Web search and the model's prior knowledge are both prone to hallucination on niche infrastructure topics. Every claim the research surfaces must be backed by a **traceable source** before it gets shown to the operator:

- **No "I recall that…"** — if the source isn't a URL, a file path, or a GitHub issue number, the claim does not appear in the findings.
- **Cite the source line** — `cluster-install/references/provider-pitfalls.md:42`, `cozystack/cozystack#1234`, `https://docs.cozystack.io/v1.3/...`. The operator should be able to click through.
- **Recency check** — if the source is a blog post older than 12 months and the cited version is older than the operator's, flag it: "This may be stale — the bug it describes was fixed in vX.Y.Z; only relevant if your install is on the older path."
- **Reproduce-or-not flag** — distinguish "documented in upstream docs" (high confidence) from "reported once in a blog post, not yet in docs" (low confidence). Different actionability.
- **No "I'd expect …" or "It might also affect …"** — if a finding is speculation, drop it. Speculative landmines waste operator attention.

### What to look for, per axis

When `intent_hints.platform` is set, scope research to that platform:

- **`oci`** — VLAN/secondary-VNIC interface quirks (VIP placement, IPv4 in maintenance mode); 1:1 NAT effect on `Service.externalIPs`; OCI's required `paravirtualized` launch mode for QCOW2 custom images.
- **`hetzner`** — RobotLB vs MetalLB (L2 ARP doesn't cross hosts); vSwitch + VLAN setup; rescue-mode + GRUB serial-console artefacts; Secure Boot interaction with rescue-image installs.
- **`aws-with-eip`** — Elastic IP not on interface (similar to OCI NAT); NLB proxy-protocol headers in TCP streams.
- **`gcp-with-nat`** — same as OCI for Cloud-NAT'd public IPs.
- **`bare-metal`** — Secure Boot + unsigned `.ko` (piraeus DRBD runtime compile); MOK enrollment; kernel-lockdown rejection of modules.

When `target: bare-metal-talos`, additionally scope:

- talm + `intent_hints.cozystack_version` compatibility (`boot-to-talos` hardcoded default Talos versions can diverge from what cozystack expects).
- Talos PSA `baseline` vs `kubectl debug node` (k8s 1.25+ blocks privileged debug pods on default namespaces).
- system-extension namespacing (zfs / drbd userspace not on host rootfs).

When `cozystack_intake.bundles` includes `system`:

- root Tenant ingress patch needed (race against tenants CRD landing).
- StorageClasses not auto-created on v1.3.x (gone in v1.4+).

When `cozystack_intake.installer_variant: generic` and `extractedprism.enabled: true`:

- chart version vs cozystack-installer version matrix.

This is a starting checklist, not exhaustive — the research pass is allowed to surface anything else the search turns up, as long as the verification rules above hold.

### Output shape

Append the findings to the consolidated summary the operator already approved in Phase 4. Re-show as a separate section before transitioning to Phase 5:

```text
cozystack:wizard — known landmines for your specific combination

  target: bare-metal-talos × oci × cozystack v1.3.3 × talos v1.13.0

  1. [HIGH] OCI 1:1 NAT — Service.externalIPs must be VCN-internal
     source: cozystack docs v1.3/install/providers/oracle-cloud.md
     why: OCI fabric rewrites public IPs to internal before the kernel
          sees them; Cilium externalIPs BPF won't match on public IPs.
     wizard auto-applied:  cozystack_intake.external_ips.strategy = internal

  2. [HIGH] VIP link on OCI VLAN secondary lacks IPv4 in maintenance mode
     source: cozystack/cozystack#<NNNN> + own retro
     why: talm template renders LinkConfig without addresses; etcd join
          hangs. Wizard collected intent_hints.vip.per_node addresses
          to auto-patch nodes/*.yaml before talm apply.
     wizard auto-applied:  3 per-node /24 addresses recorded

  3. [MEDIUM] cozystack v1.3.3 does not create StorageClasses automatically
     source: cozystack/cozystack@v1.3.3 packages/system/linstor/
             templates/storageclass.yaml.disabled
     why: tenants CRD has no spec.storageClasses field (absent through v1.4.2) — nothing auto-creates SCs.
     mitigation: cluster-install Phase 8.6 will apply local + replicated SCs.

  4. [LOW / stale-check] "OCI dashboard install fails after 5 min"
     source: blog post 2024-08-12 — describes v1.2 behaviour
     why: superseded by inline Tenant ingress patch in v1.3.x; flagged
          only because keywords matched.

  options:
    - Acknowledged — proceed to Phase 5 dispatch
    - Pause — let me investigate one of these before continuing
    - Edit Phase 4 values — go back and change the plan based on a finding
```

The operator's `Acknowledged` is the gate into Phase 5. `Pause` stops the wizard with the cluster config dir intact; operator can re-invoke with `--resume`. `Edit Phase 4 values` jumps back to Phase 4 with the offending slot pre-focused.

If the research pass returns **no findings** (clean combination, nothing flagged), print one quiet line: `Phase 4.5 research: no known landmines for this combination.` and proceed automatically — no gate, no friction.

### Caching

If `state.research_cache` exists and is `< 24 h` old AND `cozystack_intake` hasn't changed since the cache was written, skip the research pass and use the cached findings. The combination of (cozystack_version, talos_version, platform, variant, bundles) is the cache key. `--resume` honours the cache; explicit `--rerun-research` forces a fresh pass.

## Phase 5 — Dispatch loop

For each skill in `state.route`:

1. Mark `state.status.<skill>` = `dispatched_at: <ISO ts>` and write `.state.yaml`.
2. Print to the operator:

   ```text
   cozystack:wizard — handing off to /cozystack:<skill>

   config dir: <config-dir>
   state file: <config-dir>/.state.yaml
   ```

3. **Instruct Claude in the next message** to invoke `/cozystack:<skill>` and wait for its summary. Use this exact phrasing: `Next, invoke /cozystack:<skill> — it will resume from <config-dir>/.state.yaml.`

   **Do not set a ScheduleWakeup fallback** before dispatching the downstream skill. Each downstream skill owns its own task-notification lifecycle (Phase 8 watch loop, ansible run, talm apply — they notify Claude when done). A wizard-side wakeup fires regardless of whether the dispatched work finished, costs a turn re-checking state that hasn't changed, and confuses the dispatch decision (was the wake from the wakeup, or from the skill completing?). Trust the downstream notification. If a downstream skill is genuinely stuck without notifying, the operator surfaces it interactively — wakeup-as-deadman-switch is the wrong mechanism here.
4. After Claude returns from the downstream skill, re-read `.state.yaml`. Expect exactly one of `state.status.<skill>.completed_at` or `failed_at` set. If `failed_at` is set, **automatically dispatch `/cozystack:debug`** to investigate and (when possible) resolve before deciding next step. If **neither** is set, treat that as a broken contract (see Guardrails) — synthesise `failed_at: "contract-violation: skill returned without writing status"` and dispatch debug anyway.

   The debug skill writes `status.debug.{classification, action, ...}`. After it returns:

   - `action: resolved` (operator-error or config-drift was fixed) — retry the originally-failing skill: clear its `failed_at`, set `dispatched_at` afresh, hand off again.
   - `action: workaround` — same retry path. Workaround is in place; the originally-failing skill should succeed now.
   - `action: issue-drafted` without a workaround — wizard pauses, surfaces the issue draft path and the `gh` command the operator can run later, then offers `Skip the failing step (cluster will be incomplete) / Cancel install`.
   - `action: no-action` — debug couldn't determine the cause. Offer `Retry the failing skill / Skip / Cancel`.

5. On success (`completed_at` set), continue to the next entry.

The loop is the wizard's main job — sit between every downstream skill, verify the state transition, decide the next step.

## Phase 6 — Final summary

After all skills in the chain report success, print a chain-level NOTES:

```text
cozystack:wizard — install complete

config dir:  /Users/me/cozystack-lab
route taken:
  ✓ cozystack:ubuntu-bootstrap   completed 17:25 UTC (20:25 MSK)
  ✓ cozystack:cluster-install    completed 18:40 UTC (21:40 MSK)

cluster:
  context:        cozystack-lab
  kubeconfig:     /Users/me/cozystack-lab/kubeconfig.yaml
  api:            https://10.0.0.10:6443

cozystack:
  installer variant: talos          # cozy-installer chart variant
  platform variant:  isp-full       # platform-package overlay
  bundles:        system, paas, iaas, naas
  dashboard:      https://dashboard.10-0-0-50.nip.io

artifacts under <config-dir> (safe to commit, see .gitignore for exclusions):
  inventory.yml
  cozystack-platform-package.yaml
  extractedprism-values.yaml

next:
  list tenants:   kubectl --context cozystack-lab get tenants.apps.cozystack.io -A
  upgrade later:  /cozystack:cluster-upgrade
```

The detailed per-skill NOTES (storage breakdown, Keycloak admin path, etc.) were printed by each downstream skill at its own final phase; the wizard summary intentionally stays high-level.

## Guardrails

- NEVER perform cluster mutations directly. Every mutation lives in a downstream skill.
- NEVER skip the route approval gate in Phase 3.
- NEVER hand off to the next skill without verifying the previous one wrote `completed_at` to `.state.yaml`.
- NEVER ignore a returned skill that wrote **neither** `completed_at` **nor** `failed_at`. That's a broken contract — surface it explicitly: `cozystack:wizard — skill /cozystack:<name> returned but did not write status.<name>.completed_at or .failed_at; treating as failed_at='contract-violation' and dispatching /cozystack:debug.` Don't silently retry; the missing write means the skill exited in an unknown state and the next dispatch decision can't be made safely.
- NEVER silently overwrite an existing state file from a different session — always ask resume / fresh / cancel.
- NEVER `git init` / `git add` / `git commit` inside the config dir. Git ops are operator-side.
- AVOID picking a config dir under `/tmp` or another ephemeral location by default — the artifacts are meant to survive. Allow it only when (a) `--allow-ephemeral` was passed, (b) the operator explicitly named a `/tmp/...` path AND signalled test/scratch intent (keywords like "test", "scratch", "throwaway", "ephemeral", "discard after", or the equivalents in their natural language), or (c) Phase 1's 4th option "scratch dir under $TMPDIR (will be lost on reboot)" was chosen. Always surface a one-line warning when ephemeral path is in use.
- ALWAYS read `.state.yaml` after every downstream invocation — don't assume the skill succeeded just because Claude returned.
- ALWAYS leave the operator with a clear next-step command if the chain pauses (failure, manual checklist in talos-bootstrap, etc.).

## References

- `references/routes.md` — target × chain decision table with the reasoning.
- `references/state-schema.md` — `.state.yaml` narrative shape, which fields each skill reads and writes.
- `references/state.schema.json` — machine-readable JSON Schema for `.state.yaml`. Skills validate before writes; `tools/check-refs.sh` can be extended to validate state files in fixtures. Operators / contributors can drive yaml-language-server with `# yaml-language-server: $schema=https://raw.githubusercontent.com/cozystack/ccp/main/plugins/cozystack/skills/wizard/references/state.schema.json` at the top of `.state.yaml`.
- `references/sops.md` — sops opt-in (Phase 1.5): file-by-file decision matrix, age key resolution, `.sops.yaml` block, encrypt-after-write pattern, talm interaction, on↔off toggling.

Downstream skills:

- `/cozystack:talos-bootstrap` — Talos node prep (v1: manual-steps handoff).
- `/cozystack:ubuntu-bootstrap` — Ubuntu / Debian bootstrap via ansible-cozystack wrapper.
- `/cozystack:cluster-install` — Cozystack on a ready Kubernetes cluster.
- `/cozystack:debug` — auto-dispatched by Phase 5 when any chain step writes `failed_at`. Investigates, classifies (operator error / config drift / upstream bug / not-supported), applies workaround when possible, drafts upstream issue on approval.
