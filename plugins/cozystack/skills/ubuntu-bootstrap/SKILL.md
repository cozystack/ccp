---
name: ubuntu-bootstrap
description: Bootstrap a Cozystack-ready Kubernetes cluster on Ubuntu/Debian nodes by wrapping the upstream cozystack/ansible-cozystack playbooks. Drives inventory interview, renders inventory.yml into the operator's cluster config directory, runs prepare-sudo.yml (Ubuntu 26.04+ sudo-rs workaround), prepare-ubuntu.yml (packages, kernel modules, sysctl, services, multipath blacklist, DRBD-DKMS for Secure Boot, ZFS, KubeVirt modules), and the k3s.orchestration collection (HA k3s with cozystack-compatible flags — flannel off, kube-proxy off, traefik off, cluster-domain cozy.local). Stops after k3s is up and kubeconfig is retrieved; the actual Cozystack install is done by `cozystack:cluster-install` in the next step. All artifacts (inventory.yml, kubeconfig, state) live in the cluster config directory so operators can manage them as code in their own git workflow. Use as the first chain step when `cozystack:wizard` picks "Bare-metal generic Linux, no k8s yet".
argument-hint: "[--config-dir=<path>] [--ansible-cozystack-dir=<path>] [--skip-sudo-rs-workaround] [--k3s-version=<vX.Y.Z+k3sN>]"
---

# cozystack:ubuntu-bootstrap

Work in reasoning mode. Use the phrasing `cozystack:ubuntu-bootstrap`. Announce phase transitions: `cozystack:ubuntu-bootstrap Phase N — <name>`.

> **Note on language in this SKILL.md** — every operator-facing prompt below is written in English for clarity. At runtime the skill matches the operator's natural language detected from prior conversation messages (or read from `<config-dir>/.state.yaml` `operator_language` when the wizard chain is in progress). Code identifiers, commands, file paths, and any text destined for GitHub stay canonical. Ansible task names from upstream playbooks come through in English by design — don't translate them.

## Why this is an ansible wrapper, not a hand-rolled SSH flow

`cozystack/ansible-cozystack/examples/ubuntu/` already implements every node-prep step Cozystack needs — and that list is non-obvious and broad: 11 sysctl keys, 8 kernel modules across required / optional / DRBD / ZFS / KubeVirt categories, LINBIT PPA wiring for drbd-dkms on Secure Boot, multipath blacklist for `drbd*` devnodes, iptables flush for cloud images that REJECT non-SSH traffic, Ubuntu 26.04 sudo-rs workaround. A hand-rolled SSH shell skill drifts from this list the moment ansible-cozystack adds anything new. Wrapping the playbooks keeps `ubuntu-bootstrap` aligned by reference.

The wrapper does **not** call the cozystack-install step from upstream `site.yml` — that lives in `cozystack:cluster-install` so the storage / extractedprism / OIDC / domain logic stays in one place. The skill renders an inventory with `cozystack_create_platform_package: false` to enforce this.

## Cluster config directory

Every artifact lives under `<config-dir>/`. Default resolution (read from `state.config_dir` written by `cozystack:wizard`):

```
<config-dir>/
  .gitignore                          # skill-managed: excludes secrets + state
  .state.yaml                         # wizard chain state (read+write by every skill)
  inventory.yml                       # ansible inventory rendered by this skill
  kubeconfig.yaml                     # k3s kubeconfig after Phase 8 (server URL rewritten)
```

The skill never touches `git init` / `git add` / `git commit` — operating on git is the operator's call. The `.gitignore` is just a text file with sensible exclusions; harmless when there is no git repo, ready when the operator decides to make one.

## Core principles

- Match the operator's natural language. Read from `<config-dir>/.state.yaml` `operator_language` (set by `cozystack:wizard` Phase 0) or detect from prior messages when invoked directly. Use it in prompts, AskUserQuestion options, summaries, and gates. Code identifiers, commands, file paths, and GitHub-public text stay in their canonical form. Ansible task names from the upstream playbooks come through in English by design — don't translate them.
- One valid path → just do it. Once the operator approved the rendered `inventory.yml` in Phase 4, the skill runs `ansible-playbook prepare-sudo.yml`, `prepare-ubuntu.yml`, and `k3s.orchestration.site` back-to-back without per-playbook re-confirmation. Approval gates remain only for (a) inventory shape in Phase 4 (operator picks node count, roles, SSH user), (b) destructive recovery paths (resetting a half-installed cluster). The "approve OS prep on all nodes / approve per-node" choice in Phase 7 collapses to a single Apply — the operator already approved the inventory.
- Front-load the interview. **Every question the skill might ask in any phase lives in Phase 4** (inventory render): node IPs, roles, ssh_user, ssh_key path, k3s_version (with default), VIP if HA, `cozystack_flush_iptables` for cloud images, `cozystack_enable_zfs` / `cozystack_enable_drbd_dkms` overrides, alternate `cozystack_ubuntu_extra_packages` for non-stock kernels. `intent_hints` from wizard Phase 0 pre-fills wherever possible. Phases 6–8 (the three playbook runs) consume the inventory and never re-prompt; on any ansible failure the skill surfaces it and stops, but does not interactively ask which playbook step to skip mid-batch.
- Layer-pure operator output. The skill never says "returning control to wizard", "the wizard will dispatch next", or any other orchestration commentary in the **operator-facing** summary. Whoever invoked the skill (a human directly, or the wizard's dispatch loop) figures out what's next on their own. Internal SKILL.md references to `cozystack:wizard` are fine for documentation; `wizard` does not appear in any text shown to the operator.
- Operator-driven SSH via ansible. No direct shell-over-ssh from the skill.
- Per-step gate. Operator approves each `ansible-playbook` invocation before it runs.
- Idempotent re-run. Ansible itself is idempotent; the skill re-runs without harm.
- Stop after k3s is up. The next step is `cozystack:cluster-install`, not bundled here.
- Trust ansible's exit code. Non-zero = abort, surface the ansible output verbatim.
- Cluster config dir as state. Don't sprinkle artifacts across `/tmp`; the operator should be able to `tar`, `rsync`, or `git push` the directory and reproduce the cluster shape.

## Phase 1 — Read state and locate ansible-cozystack

Read `<config-dir>/.state.yaml`. Required keys: `config_dir`, `inventory.nodes`, `inventory.ssh_user`, `inventory.ssh_key`. If invoked without a state file (direct invocation, not via wizard), interview them inline.

Find ansible-cozystack on the workstation:

1. `--ansible-cozystack-dir=<path>` — explicit override; verify it contains `examples/ubuntu/site.yml`.
2. `~/git/github.com/cozystack/ansible-cozystack/` — default checkout location.
3. If neither exists, instruct:

   ```bash
   mkdir -p ~/git/github.com/cozystack
   git clone https://github.com/cozystack/ansible-cozystack.git \
     ~/git/github.com/cozystack/ansible-cozystack
   ```

   Refuse until the directory is present (cloning over network is operator's call).

Verify versions:

```bash
ansible --version            # >= 2.15
ansible-galaxy --version
ssh -V
```

The skill does not install ansible — print the install command and refuse if missing.

## Phase 2 — Initialise .gitignore

If `<config-dir>/.gitignore` is missing or lacks the cozystack section, append the right block based on `state.sops.enabled` (from wizard Phase 1.5):

**sops off** (default — wizard wrote `state.sops.enabled: false`):

```gitignore
# === BEGIN cozystack ===
.state.yaml
kubeconfig.yaml
inventory.yml
talosconfig
secrets.yaml
*.tar.gz
# === END cozystack ===
```

**sops on**:

```gitignore
# === BEGIN cozystack ===
# Secret files are encrypted in place via sops — see .sops.yaml.
# Operator-side: do not commit your private age key.
*.tar.gz
# === END cozystack ===
```

If the section already exists, leave it alone (re-running wizard --sops / --no-sops will rewrite it).

## Phase 2.5 — Sops sanity check

If `state.sops.enabled` is true, verify before any secret write:

```bash
sops --version
test -f "$CONFIG_DIR/.sops.yaml"
```

Refuse to proceed if either fails — surface the missing piece and ask the operator to install `sops` and the configured age/PGP key, then re-run with `--sops` already on, or pass `--no-sops` to disable. Do **not** silently fall back to plain writes.

The encrypt-after-write helper used in Phase 4 / Phase 9 below:

```bash
maybe_encrypt() {
  local file="$1"
  if [ "$(yq '.sops.enabled // false' "$CONFIG_DIR/.state.yaml" 2>/dev/null)" = "true" ]; then
    sops --encrypt --in-place "$file"
  fi
}
```

## Phase 3 — Install ansible collections

```bash
cd "$ANSIBLE_COZYSTACK_DIR/examples/ubuntu"
ansible-galaxy collection install --requirements-file requirements.yml
```

Surface which collections resolve (k3s.orchestration from git, cozystack.installer from git, plus ansible.posix / community.general / kubernetes.core / ansible.utils from Galaxy). Re-running is cheap — Galaxy short-circuits on already-installed versions.

## Phase 4 — Render inventory.yml into config dir

Write `<config-dir>/inventory.yml` from `state.inventory`. Do **not** edit the example's inventory in place — that's a template.

```yaml
---
cluster:
  children:
    server:
      hosts:
        # Internal IP as host key, public IP as ansible_host.
        # ansible-cozystack auto-collects server host keys into kube-ovn MASTER_NODES.
        10.0.0.10:
          ansible_host: 203.0.113.10
        10.0.0.11:
          ansible_host: 203.0.113.11
        10.0.0.12:
          ansible_host: 203.0.113.12
    agent:
      hosts:
        10.0.0.20:
          ansible_host: 203.0.113.20

  vars:
    ansible_port: 22
    ansible_user: ubuntu
    ansible_ssh_private_key_file: ~/.ssh/cozystack-lab

    # k3s.orchestration
    k3s_version: "v1.32.3+k3s1"      # pin explicitly; get.k3s.io floats otherwise
    token: "<32-byte hex>"            # openssl rand -hex 32
    api_endpoint: "10.0.0.10"
    cluster_context: "cozystack-lab"

    # cozystack.installer (we install Cozystack later via cluster-install)
    cozystack_api_server_host: "10.0.0.10"
    cozystack_create_platform_package: false

    # Extra k3s flags (--tls-san for every CP IP and optional VIP)
    cozystack_k3s_extra_args: "--tls-san=203.0.113.10 --tls-san=203.0.113.11 --tls-san=203.0.113.12"

    # OCI / cloud-image multi-master quirk — set true if running on cloud images
    cozystack_flush_iptables: false
```

Critical knob: `cozystack_create_platform_package: false`. This tells the cozystack.installer role to skip Platform Package creation, leaving Cozystack uninstalled. The skill installs operator + Package via `cluster-install` in the next chain step.

This is the **one** interview phase. After Phase 1 inventory interview the skill auto-fills everything the rest of the flow needs and presents a single consolidated summary; later phases (ansible-playbook prepare-sudo / prepare-ubuntu / k3s.orchestration.site / kubeconfig fetch) consume the answers without re-prompting.

Slots filled here from `intent_hints` + defaults (operator edits only what they want different):

- Inventory: nodes (host, role, name), ssh_user, ssh_key path, optional VIP.
- `k3s_version` (default pinned per `references/ansible-playbook.md` version matrix).
- `cozystack_flush_iptables` (default `true` when `intent_hints.hardware_provider` is a cloud / OCI; `false` otherwise).
- `cozystack_enable_zfs` (default `true`; off if `intent_hints.distribution` is RHEL 10 family).
- `cozystack_enable_drbd_dkms` (default `true` on Ubuntu Secure Boot hosts; off if `intent_hints.disable_secure_boot` was hinted).
- Cluster name / kubeconfig merge target (same as `talos-bootstrap`).
- `cozystack_root_host` and `cozystack_external_ips` — passed through to `cluster-install`, not actually used by ansible if `cozystack_create_platform_package: false`, but listed for completeness in case the operator wants to override the ansible defaults.

Consolidated summary:

```text
cozystack:ubuntu-bootstrap — collected values

inventory:
  ssh_user:           ubuntu
  ssh_key:            ~/.ssh/cozystack-lab
  cp1 (10.0.0.10):    Ubuntu 24.04, ansible_host=203.0.113.10
  cp2 (10.0.0.11):    Ubuntu 24.04, ansible_host=203.0.113.11
  cp3 (10.0.0.12):    Ubuntu 24.04, ansible_host=203.0.113.12
  w1  (10.0.0.20):    Ubuntu 24.04, ansible_host=203.0.113.20
  vip:                (none — using cp1 host as tls-san)

k3s:
  version:            v1.32.3+k3s1                        (pinned for cozystack v1.3.x)

knobs:
  cozystack_flush_iptables:      true                      (hardware_provider=oci hinted)
  cozystack_enable_zfs:          true
  cozystack_enable_drbd_dkms:    true
  cluster name:                  cozystack-lab
  kubeconfig:                    <config-dir>/kubeconfig.yaml  (overwrite if exists; or pick merge)

operations on Approve:
  1. ansible-galaxy collection install --requirements-file requirements.yml
  2. ansible -m ping  (preflight)
  3. ansible-playbook prepare-sudo.yml          (Ubuntu 26.04+ only)
  4. ansible-playbook prepare-ubuntu.yml        (~10 min)
  5. ansible-playbook k3s.orchestration.site    (~5 min)
  6. scp + rewrite kubeconfig.yaml

options:
  - Approve all — proceed end-to-end
  - Edit <slot>
  - Cancel
```

After Approve, if sops is enabled, run `maybe_encrypt "$CONFIG_DIR/inventory.yml"` — subsequent `ansible-playbook` invocations need to read the inventory, so the skill calls `sops --decrypt` into a temp file and passes `--inventory=<tempfile>` for each playbook run. The encrypted inventory.yml in the config dir stays the canonical form.

## Phase 5 — SSH preflight via ansible

```bash
cd "$ANSIBLE_COZYSTACK_DIR/examples/ubuntu"
ansible --inventory "$CONFIG_DIR/inventory.yml" all --module-name ping --one-line
```

Every node must respond `pong`. Failure → surface ansible's error verbatim and refuse to proceed (likely SSH key, passwordless sudo, or unreachable host).

## Phase 6 — prepare-sudo.yml (Ubuntu 26.04+ sudo-rs workaround)

Skip on `--skip-sudo-rs-workaround` or when every node reports `ansible_distribution_version < 26.04` (gather_facts result). Otherwise:

```bash
ansible-playbook --inventory "$CONFIG_DIR/inventory.yml" prepare-sudo.yml
```

On any node failure, abort. Subsequent playbooks need sudo working.

## Phase 7 — prepare-ubuntu.yml (OS prep)

```bash
ansible-playbook --inventory "$CONFIG_DIR/inventory.yml" prepare-ubuntu.yml
```

Streams ansible output. This is the long step (5–15 min depending on apt mirror and node count). It installs packages, loads kernel modules, applies sysctl, enables services, writes the multipath blacklist, runs LINBIT PPA + drbd-dkms for Secure Boot hosts, configures ZFS / KubeVirt modules. See `references/ansible-playbook.md` for the full breakdown.

On failure, the skill abandons and shows the failed task + stderr. Recovery is operator-side (fix apt mirror, MOK enrollment, etc.) and re-run.

## Phase 8 — k3s.orchestration.site (k3s install)

```bash
ansible-playbook --inventory "$CONFIG_DIR/inventory.yml" k3s.orchestration.site
```

Upstream `k3s-io/k3s-ansible` playbook. Uses k3s flags from `prepare-ubuntu.yml`'s `cozystack_k3s_server_args` (flannel-backend none, traefik / servicelb / local-storage / metrics-server disabled, kube-proxy off, cluster-domain cozy.local, max-pods 220) plus extra `--tls-san` from inventory.

HA shape: server group ≥ 1 CP (3 for HA via embedded etcd), agents for workers. First server is `cluster-init`; rest joins. Token comes from `inventory.vars.token`.

Exits when `kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes` shows all Ready on the first CP.

## Phase 9 — Retrieve kubeconfig into config dir

See `references/kubeconfig.md`.

```bash
scp -i "$SSH_KEY" \
  "$SSH_USER@$CP1_HOST:/etc/rancher/k3s/k3s.yaml" \
  "$CONFIG_DIR/kubeconfig.yaml"

# Rewrite 127.0.0.1 → CP1 public IP (or VIP if set)
sed -i.bak "s#https://127\.0\.0\.1:6443#https://${VIP:-$CP1_HOST}:6443#g" \
  "$CONFIG_DIR/kubeconfig.yaml"
rm -f "$CONFIG_DIR/kubeconfig.yaml.bak"
chmod 0600 "$CONFIG_DIR/kubeconfig.yaml"

# Encrypt at rest if sops is enabled.
maybe_encrypt "$CONFIG_DIR/kubeconfig.yaml"
```

Offer optional merge into `~/.kube/config` via `kubectl kc add --file "$CONFIG_DIR/kubeconfig.yaml" --context-name "$CLUSTER_CONTEXT" --cover`. Default: keep standalone — `$CONFIG_DIR/kubeconfig.yaml` is gitignored, the operator controls when (and whether) to merge.

Verify:

```bash
KUBECONFIG="$CONFIG_DIR/kubeconfig.yaml" kubectl get nodes
```

Every inventory node must show `Ready`, versions matching.

## Phase 10 — Write state and hand off

Update `<config-dir>/.state.yaml` — if sops is enabled, decrypt-edit-encrypt: shell out to `sops --decrypt > tmp`, mutate `tmp`, `sops --encrypt --output <state> tmp`, `rm tmp`. The skill never leaves a plain-text `.state.yaml` on disk between writes when sops is on.

```yaml
cluster:
  context: cozystack-lab
  kubeconfig: <config-dir>/kubeconfig.yaml
  api_endpoint: https://10.0.0.10:6443
  distribution: k3s
  k8s_version: v1.32.3+k3s1
inventory:
  # refined from prepare-ubuntu.yml gather_facts: real hostnames / arch / kernel
  nodes: [...]
status:
  ubuntu-bootstrap:
    completed_at: <ISO_TS_UTC>
    ansible_cozystack_dir: ~/git/github.com/cozystack/ansible-cozystack
    inventory_path: <config-dir>/inventory.yml
```

Print NOTES:

```text
cozystack:ubuntu-bootstrap — ready

cluster:
  context:        cozystack-lab
  kubeconfig:     <config-dir>/kubeconfig.yaml
  api:            https://10.0.0.10:6443
  distribution:   k3s v1.32.3+k3s1
  nodes:          3 cp + 1 worker — all Ready

artifacts on disk (under <config-dir>):
  inventory.yml          # safe to commit — encrypted if sops on, gitignored otherwise
  kubeconfig.yaml        # encrypted if sops on, gitignored otherwise; chmod 0600 either way
  .state.yaml            # encrypted if sops on, gitignored otherwise; chain progress

next: invoke /cozystack:cluster-install — it will resume from <config-dir>/.state.yaml
      cluster-install installs extractedprism (kube-apiserver HA proxy),
      the cozy-installer chart, and the Platform Package on this fresh cluster.
```

## Guardrails

- NEVER edit `examples/ubuntu/inventory.yml` in place — that's a template. Always render to `<config-dir>/inventory.yml`.
- NEVER set `cozystack_create_platform_package: true` in the rendered inventory. Cozystack install belongs to `cluster-install`.
- NEVER install ansible or pip on the operator's workstation. Refuse if missing, print install command.
- NEVER batch-skip a playbook because "the previous run did it" — ansible is idempotent and re-verifies real state.
- NEVER `git init` / `git add` / `git commit` inside the config dir. Git operations are operator-side decisions.
- ALWAYS surface ansible's stderr / failed task verbatim. Don't paraphrase.
- ALWAYS pin `k3s_version` explicitly — `get.k3s.io` floats to the channel tip otherwise.
- ALWAYS verify `kubectl get nodes` Ready before writing `status.ubuntu-bootstrap.completed_at`.
- ALWAYS write artifacts under `<config-dir>/`, never `/tmp` — operators should be able to `git add inventory.yml` after the run.
- NEVER silently fall back to plain writes when `state.sops.enabled` is true but `sops` or `.sops.yaml` is missing. Refuse Phase 2.5 and tell the operator to install `sops` + the configured age/PGP key, or re-invoke with `--no-sops`.
- NEVER leave a plain-text `.state.yaml` or `kubeconfig.yaml` on disk between phases when sops is on. Decrypt to a temp file, mutate, re-encrypt, remove the temp file.

## References

- `references/inventory.md` — interview template, role rules, HA prerequisites.
- `references/ansible-playbook.md` — what each upstream playbook does, knob mapping (inventory variables → playbook behaviour), troubleshooting per playbook.
- `references/kubeconfig.md` — retrieval, server URL rewrite, merge via kubecm.

Cross-references:

- `/cozystack:cluster-install` — runs after this, installs Cozystack proper.
- `/cozystack:wizard` — the orchestrator that builds the chain.

External:

- `https://github.com/cozystack/ansible-cozystack` — upstream playbooks.
- `https://cozystack.io/docs/v1.3/install/kubernetes/generic/` — install guide this skill automates.
- `https://docs.k3s.io/` — upstream k3s docs.
- `https://github.com/k3s-io/k3s-ansible` — the `k3s.orchestration` ansible collection.
