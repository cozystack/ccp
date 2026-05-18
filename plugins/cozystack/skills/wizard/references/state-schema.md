# .state.yaml schema

Single source of truth for what each skill in the chain reads and writes. Stored at `<config-dir>/.state.yaml`. Append-only in spirit — skills add their own sections, but don't overwrite sections owned by another skill (`status.<skill>` is the only field the wizard updates between dispatches).

## Top-level keys

```yaml
created_at: "2026-05-15T17:00:00Z"      # ISO-8601 UTC, written once by wizard
session_id: "20260515-170000"            # filename-friendly UTC timestamp
config_dir: "/Users/me/cozystack-lab"    # absolute path, written by wizard Phase 1
intent_summary: "..."                    # free-form recap from wizard Phase 0
intent_hints: {...}                      # parsed key/values from wizard Phase 0
operator_language: "ru"                  # detected language code (ISO 639-1), for skill prompts
target: "bare-metal-ubuntu"              # bare-metal-talos / bare-metal-ubuntu / existing
route: ["ubuntu-bootstrap", "cluster-install"]
sops: {...}                              # secret-encryption settings — Phase 1.5
inventory: {...}                         # bootstrap-only
cluster: {...}                           # filled after bootstrap or upfront
cozystack_intake: {...}                  # operator's policy decisions — wizard Phase 4
cozystack: {...}                         # discovery + execution outcome — cluster-install
status: {...}                            # per-skill outcomes
```

## `intent_summary` and `intent_hints`

Written by wizard Phase 0 from the operator's free-form answer to "tell me what you're doing and what's already in place".

```yaml
intent_summary: "Operator wants to install Cozystack on 3 Hetzner Ubuntu 24.04 servers, no GPU, no public domain (will use nip.io). Has tried before, dashboard never came up."
intent_hints:
  target: "bare-metal-ubuntu"              # used to pre-fill Phase 2 target
  node_count: 3                             # used to size inventory in Phase 4
  distribution_hint: "k3s"                 # ubuntu-bootstrap default
  domain_hint: "nip.io"                    # cluster-install Phase 4 publishing.host
  prior_failure: "cozy-dashboard/dashboard never reached Ready"
                                            # signals to start chain with debug
  hardware_provider: "hetzner"              # informational
  workload_class: "general"                 # general / gpu / vms / databases
  platform: "metal"                        # talos platform — metal / nocloud / aws / oci / azure / gcp
                                            # used by talos-bootstrap to pick the right installer profile
  cloud_hint: "oci"                        # free-form short tag for downstream routing
                                            # (OCI custom-image instructions, AWS AMI flow, etc.)
  reach_mode: "public"                     # how workstation reaches nodes — public / internal / vip
                                            # determines IP set used in talosctl --nodes
  cp_endpoint: "https://10.17.100.10:6443" # VIP / single CP IP / external LB — used for
                                            # talm init --cluster-endpoint and in machine-config
  vip:                                      # only when cp_endpoint is a VIP
    address: "10.17.100.10"
    link: "ens5"
    subnet: "10.17.100.0/24"
    mtu: 9000
```

The list is open-ended — any structured key the operator's free-form answer maps to is fair game. Downstream skills read `intent_hints` to skip questions whose answers are already known.

## `operator_language`

Detected from the operator's free-form Phase 0 answer (or first message before that). ISO 639-1 code:

- `ru` — Russian
- `en` — English
- `de` — German
- etc.

Every skill matches this language in its prompts, AskUserQuestion option labels, summaries, and gate messages. Code identifiers, command examples, file paths, and any text destined for GitHub stay in canonical form (usually English). Skills do not ask the operator which language to use — `operator_language` is filled once in Phase 0 and reused.

## `sops`

Written by wizard Phase 1.5. Every downstream skill reads `sops.enabled` before each secret-file write and runs `sops --encrypt --in-place <file>` after the plain write if true.

```yaml
sops:
  enabled: true
  recipients:                                 # everyone who can decrypt; usually one operator + maybe a shared team key
    - "age1abc..."
  config_path: "<config-dir>/.sops.yaml"      # absolute path to the .sops.yaml
  # When enabled is false, no other field matters and skills skip the encrypt step.
```

If `sops.enabled` is missing or false, the skills behave as before — secret files land in plain text and `.gitignore` keeps them out of commits. See `references/sops.md`.

## `inventory`

Only present when the chain starts with a bootstrap skill. Written by the wizard during Phase 4 interview; refined by the bootstrap skill if it learns more (e.g. real hostnames after `hostnamectl`).

```yaml
inventory:
  ssh_user: "ubuntu"
  ssh_key: "/Users/me/.ssh/cozystack-lab"
  nodes:
    - host: "10.0.0.10"             # external / ansible_host
      internal_ip: "10.0.0.10"      # used as inventory key for ansible-cozystack
      role: "cp"
      name: "cp1"
    - host: "10.0.0.11"
      internal_ip: "10.0.0.11"
      role: "cp"
      name: "cp2"
    - host: "10.0.0.12"
      internal_ip: "10.0.0.12"
      role: "cp"
      name: "cp3"
    - host: "10.0.0.20"
      internal_ip: "10.0.0.20"
      role: "worker"
      name: "w1"
  vip: ""                # optional virtual IP; empty = use cp1.host as tls-san
```

Constraints:

- `nodes[].role` is `cp` or `worker`.
- For HA: at least 3 `cp` nodes (embedded etcd raft).
- For single-node sandbox: one `cp`, zero or more workers.

## `cluster`

Written by whichever bootstrap skill ran (`talos-bootstrap` or `ubuntu-bootstrap`) **or** filled directly by the wizard for the "existing k8s" target.

```yaml
cluster:
  context: "cozystack-lab"
  kubeconfig: "/Users/me/cozystack-lab/kubeconfig.yaml"
  api_endpoint: "https://10.0.0.10:6443"
  distribution: "k3s"                     # k3s / talos / kubeadm / rke2 / managed-eks / ...
  k8s_version: "v1.32.3+k3s1"
```

`cluster.context` is what every downstream `kubectl` invocation uses as `--context`. If the operator already had a kubeconfig with the same context name, the bootstrap skill renames the freshly-fetched one (e.g. `cozystack-lab-2`) and surfaces the rename.

## `cozystack_intake`

Operator's policy decisions collected by **wizard Phase 4**, read by `cluster-install` Phase 4 to skip re-prompting. Every slot below was historically asked by `cluster-install` *after the cluster existed* — moving them into `wizard` is the front-load contract. Discovery-dependent values (actual device paths, KubeOVN label-value mismatches) are still resolved by `cluster-install` against the live cluster.

```yaml
cozystack_intake:
  # Variant + bundle selection — kept SEPARATE because they map to different
  # cozy-installer chart inputs:
  #   --set cozystackOperator.variant=<installer_variant>   (chooses cozy-installer behaviour)
  #   the chart then loads packages/core/platform/values-<platform_variant>.yaml as overlay
  # Both names come from upstream cozystack files; do not invent values.
  # Real upstream platform_variant overlays in cozystack v1.3.x:
  #   default, isp-full, isp-full-generic, isp-hosted
  # Typical pairing:
  #   installer_variant=talos   ↔ platform_variant=isp-full
  #   installer_variant=generic ↔ platform_variant=isp-full-generic
  #   installer_variant=hosted  ↔ platform_variant=isp-hosted
  bundles: ["system", "paas", "iaas", "naas"]
  installer_variant: "talos"                 # generic / talos / hosted (derived from target + workload_class)
  platform_variant: "isp-full"               # default / isp-full / isp-full-generic / isp-hosted

  # Storage layout preference (Talos / Ubuntu routes; "hosted" target skips)
  storage_pref:
    layout_per_node:
      node0: "single"                        # single / mirror / raidz
      node1: "single"
      node2: "single"
    zpool_name: "data"
    linstor_pool_name: "data"

  # Networking — defaults READ from cozystack source values.yaml at wizard Phase 4
  # (not hardcoded). See wizard SKILL.md Phase 4 for the resolution order.
  network:
    pod_cidr: "10.244.0.0/16"
    service_cidr: "10.96.0.0/16"
    join_cidr: "100.64.0.0/16"
    defaults_source: "cozystack@v1.3.3/packages/core/platform/values.yaml"

  # Publishing — host, certs, exposure
  publishing:
    host: "10-17-0-128.nip.io"
    host_kind: "nip.io"                      # nip.io / custom-fqdn
    domain_ownership_confirmed: true         # always true for nip.io; explicit operator confirm for custom-fqdn
    cert_solver: "http01"                    # http01 / dns01
    exposed_services: ["api", "dashboard"]
    api_server_endpoint: "https://api.10-17-0-128.nip.io"

  # External IPs strategy — what Service.externalIPs gets populated with
  external_ips:
    strategy: "internal"                     # internal / external / explicit
    explicit: []                             # populated only when strategy=explicit
    # Reason recorded so operator and reviewer can see why this choice was made:
    reason: "OCI 1:1 NAT — public IPs would not match Cilium externalIPs BPF"

  # kube-apiserver HA
  extractedprism:
    enabled: true                            # default for generic; auto-false for talos / hosted
    api_host_override: ""                    # set only when operator passed --no-extractedprism with --api-host=<ip>
```

Constraints:

- `external_ips.strategy: internal` is the safe default whenever `Node.status.addresses` has both `InternalIP` and `ExternalIP` that differ. Picking `external` on such providers (OCI, GCP+NAT, AWS+EIP) silently breaks Cilium externalIPs matching — symptom is RST on dashboard ingress even with all HRs Ready.
- `publishing.host_kind: custom-fqdn` requires `domain_ownership_confirmed: true` (explicit operator confirm); the wizard refuses to proceed otherwise.
- `storage_pref.layout_per_node` is a *preference* keyed by node name from `inventory.nodes[].name`. The actual device paths are resolved by `cluster-install` Phase 5.5 against the running cluster (post-bootstrap, devices are discoverable).
- `extractedprism.enabled: false` on `installer_variant: generic` requires `extractedprism.api_host_override` to be a non-empty IP / VIP / external LB endpoint.

## `cozystack`

Written by `cluster-install`. Mirrors what gets serialised to `<config-dir>/cozystack-platform-package.yaml`.

```yaml
cozystack:
  installer_variant: "talos"              # generic / talos / hosted — same key as cozystack_intake
  platform_variant: "isp-full"            # default / isp-full / isp-full-generic / isp-hosted — upstream overlay name
  bundles: ["system", "paas", "iaas", "naas"]
  api_server_host: "127.0.0.1"            # or CP1_IP / VIP / "" (hosted)
  api_server_port: "7445"
  api_server_source: "extractedprism (default)"
  storage:
    backend: "zfs"                         # zfs (only supported)
    linstor_pool: "data"
    nodes:
      - name: "cp1"
        devices: ["/dev/nvme1n1"]
        layout: "single"
        zpool: "data"
      - name: "cp2"
        devices: ["/dev/nvme1n1", "/dev/nvme2n1"]
        layout: "mirror"
        zpool: "data"
      - ...
  publishing:
    host: "10-0-0-50.nip.io"
    api_endpoint: "https://api.10-0-0-50.nip.io"
    external_ips: ["10.0.0.50"]
    exposure: "externalIPs"
    cert_solver: "http01"
```

## `status`

Per-skill state machine. The wizard owns this section.

```yaml
status:
  ubuntu-bootstrap:
    dispatched_at: "2026-05-15T17:05:00Z"
    completed_at: "2026-05-15T17:25:12Z"
  cluster-install:
    dispatched_at: "2026-05-15T17:25:30Z"
    failed_at: "2026-05-15T17:32:15Z"
    error: "STOP GATE 1: br_netfilter missing on node cp2"
```

Each skill writes exactly one of `completed_at` or `failed_at` plus an `error` string when failing. The wizard never edits these fields after a skill writes them — only sets `dispatched_at` before handing off and reads `completed_at` / `failed_at` after.

## Skill responsibilities

| Skill | Reads | Writes |
| ----------- | ----------- | ----------- |
| `wizard` | everything (verifies progress) | `created_at`, `session_id`, `config_dir`, `target`, `route`, initial `inventory`, initial `cluster.context` (for existing-k8s target), `cozystack_intake.*`, `status.<skill>.dispatched_at` |
| `talos-bootstrap` | `inventory`, `target`, `config_dir`, `intent_hints.vip.per_node` | `cluster.*`, `status.talos-bootstrap.*` |
| `ubuntu-bootstrap` | `inventory`, `target`, `config_dir` | `cluster.*`, refines `inventory.nodes[].name`, `status.ubuntu-bootstrap.*` |
| `cluster-install` | `cluster.*`, `inventory.nodes[].host`, `cozystack_intake.*`, `config_dir` | `cozystack.*`, `status.cluster-install.*` |
| `debug` | everything (auto-dispatched on any `failed_at`) | `status.debug.*` with `target`, `classification`, `action`, optional `source.{repo,file,line}`, `issue_repo` |

## `status.debug`

Written by `cozystack:debug` after Phase 6:

```yaml
status:
  debug:
    dispatched_at: "2026-05-15T18:00:00Z"
    completed_at:  "2026-05-15T18:15:00Z"
    target: "hr/cozy-dashboard/dashboard"
    classification: "upstream-bug"           # operator-error | config-drift | upstream-bug | not-supported
    action: "workaround"                      # resolved | workaround | issue-drafted | no-action
    source:                                   # populated only when classification=upstream-bug
      repo: "cozystack/cozystack"
      file: "packages/system/dashboard/charts/dashboard/templates/gatekeeper.yaml"
      line: 47
      summary: "gatekeeper container always dials https://keycloak.${HOST} without TLS skip-verify"
    issue_repo: ""                            # set when operator approved an issue filing
    issue_body_path: ""                       # path to the rendered issue body if drafted
```

The wizard's Phase 5 dispatch loop reads `action` to decide what comes next:

- `resolved` or `workaround` → retry the originally-failing skill (clear its `failed_at`, set fresh `dispatched_at`, hand off again).
- `issue-drafted` without a workaround → wizard pauses, offers Skip / Cancel.
- `no-action` → wizard offers Retry / Skip / Cancel.

## On-disk artifacts (siblings of `.state.yaml`)

All paths under `<config-dir>/`:

| File | Written by | Gitignored | Purpose |
|---|---|---|---|
| `.gitignore` | wizard (Phase 1) | no | Excludes secrets + state. Markers `# === BEGIN cozystack ===` / `# === END cozystack ===` let operator add their own rules around the cozystack block. |
| `.state.yaml` | every skill | yes | Chain progress + collected values. Refer-to-by-reference between skills. |
| `inventory.yml` | `ubuntu-bootstrap` Phase 4 | no | Ansible inventory rendered from `state.inventory`. Safe to commit. |
| `kubeconfig.yaml` | `ubuntu-bootstrap` Phase 9 / `talos-bootstrap` Phase 6 | yes | Bootstrap output; chmod 0600. |
| `nodes/cp*.yaml` | `talos-bootstrap` (v1: operator-edited from talm template) | no | Per-node Talos machine-config. Safe to commit. |
| `talosconfig` | `talos-bootstrap` | yes | talos client config; contains certs. |
| `cozystack-platform-package.yaml` | `cluster-install` Phase 4 | no | The Package CR. Safe to commit. |
| `extractedprism-values.yaml` | `cluster-install` Phase 5.6 | no | Endpoints list + chart values. Safe to commit. |

## Resuming

`/cozystack:wizard --resume` (with `--config-dir` either explicit or inferred from `$PWD`) skips Phase 2/3/4 interviews and goes straight to Phase 5 dispatch from the next not-yet-completed step in `route`. The wizard re-prints the route with completed steps marked ✓ so the operator knows where the chain stands.
