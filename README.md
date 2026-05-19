# Cozystack Claude Plugins (CCP)

External marketplace repository for Claude Code plugins
for the [Cozystack](https://cozystack.io) ecosystem.

## Installation

Add the marketplace:

```text
/plugin marketplace add cozystack/ccp
```

Install a plugin:

```text
/plugin install cozystack@cozystack-claude-plugins
/plugin install linstor@cozystack-claude-plugins
```

## Plugins

### cozystack

Platform skills bundle. One install gives you eleven skills, invoked as `/cozystack:<name>`. Start with `/cozystack:wizard` — it asks Talos / Ubuntu / Existing and picks the chain.

| Skill | Description |
| --- | --- |
| **/cozystack:wizard** | Entry point. Opens with a free-form "tell me about your setup and goal" question so context comes through in the operator's own words and pre-fills the structured questions. Then asks Talos / Ubuntu / Existing, builds a chain, dispatches downstream skills via a cluster config directory the operator picks. Artifacts (inventory, kubeconfig, state, platform-package YAML) all live there — operator manages git on their own. Every skill in the chain matches the operator's natural language. |
| **/cozystack:talos-bootstrap** | Bootstrap Talos nodes via talm. Default: probe nodes for maintenance mode (Talos-1.12-aware `get disks --insecure`); if ready, write per-node multidoc machine-config stubs with VIP-link static IPv4, run NAT-provider cert-SAN guardrail (auto-populates `values.yaml.certSANs` with public IPs before first `talm apply`), then `talm apply` + `talosctl bootstrap` + kubeconfig fetch + cozystack-tuned shape verification with auto-upgrade to tuned image when nodes booted from base Talos. Opt-in boot-method picker (OCI Custom Image / boot-to-talos / ISO / PXE) only when nodes aren't yet imaged. |
| **/cozystack:talos-reset** | Cloud-provider recovery helper when Talos nodes are unrecoverable from inside the cluster (cert-SAN trap, broken machine-config, lost talosconfig). Wraps `oci` / `aws` / `gcloud` / `hcloud` to terminate + relaunch from the cozystack-tuned image while preserving block volumes, secondary VNICs, NSG memberships. Sequential per-node to maintain etcd quorum. Hands off to `cozystack:talos-bootstrap` for re-bootstrap. |
| **/cozystack:ubuntu-bootstrap** | Bootstrap Ubuntu / Debian nodes by wrapping `cozystack/ansible-cozystack/examples/ubuntu/` — OS prep, drbd-dkms for Secure Boot, ZFS + KubeVirt modules, k3s install with cozystack-compatible flags, kubeconfig retrieval. Stops before Cozystack itself. |
| **/cozystack:cluster-install** | Cozystack on a ready cluster — node-readiness validation, variant picker, interactive values, per-node ZFS pool provisioning, extractedprism for kube-apiserver HA, cozy-installer chart, Platform Package apply, root Tenant ingress patch, wait until every HelmRelease is Ready, NOTES summary. |
| **/cozystack:debug** | Investigate a stuck or broken Cozystack install. Gathers symptoms, classifies (operator error / config drift / upstream bug / not-yet-supported), applies fixes or workarounds, drafts upstream issues with diagnostic bundle on approval. Never opens PRs or files silently. Auto-dispatched by the wizard when any chain step fails. |
| **/cozystack:cluster-upgrade** | Guided upgrade of a running Cozystack v1.x cluster — release-notes analysis, prechecks, stop gates, helm upgrade, targeted post-upgrade verification, known-failure recovery. |
| **/cozystack:package-deploy** | Deploy a single Cozystack package to a dev cluster via make + cozyhr — handles fresh install and dev-loop iteration with ExternalArtifact support. |
| **/cozystack:package-bump** | Bump a single package inside the cozystack monorepo — reads upstream changelog, adapts to breaking changes, regenerates schema, optionally deploys to a dev cluster. |
| **/cozystack:external-app-create** | Scaffold a new Cozystack external app package with dependency integration (managed CNPG Postgres, external secret references). |
| **/cozystack:dev-ui-bootstrap** | Bootstrap a UI dev sandbox — Playwright + Vite dev server for `cozystack-ui` pointed at a chosen kubeconfig. Creates a feature worktree, installs `@playwright/test` and Chromium, writes `playwright.config.ts`, adds `dev:e2e` / `test:e2e` scripts, and brings up `kubectl proxy` + Vite on a free port. Use when fixing, debugging, or writing tests against the Cozystack console. |

Chains the wizard builds:

| Target | Chain |
| ----------- | ----------- |
| Bare-metal Talos | `talos-bootstrap` → `cluster-install` |
| Bare-metal Ubuntu / Debian | `ubuntu-bootstrap` → `cluster-install` |
| Existing Kubernetes (self-managed or managed) | `cluster-install` |
| Existing Cozystack | refuse → `cozystack:cluster-upgrade` |

### linstor

LINSTOR / DRBD operations bundle. Useful on any Kubernetes cluster that runs piraeus-operator / LINSTOR, not just on Cozystack.

| Skill | Description |
| --- | --- |
| **/linstor:recover** | Diagnose and recover broken DRBD resources — handles StandAlone, DELETING, Inconsistent, Diskless, quorum loss, bitmap errors, and other common failure modes. |

## Third-party dependencies

`cozystack:cluster-install` default-installs [extractedprism](https://github.com/lexfrei/extractedprism) on `generic` variant clusters (k3s / kubeadm / RKE2). extractedprism is a per-node TCP load balancer that gives generic Linux Kubernetes the same `localhost:7445` kube-apiserver shape Talos has built-in (KubePrism), so Cilium and KubeOVN can dial a stable local address regardless of which control-plane node is up.

Project metadata:

- Source: `https://github.com/lexfrei/extractedprism` (BSD-3-Clause).
- Helm chart: `oci://ghcr.io/lexfrei/charts/extractedprism`.
- Maintained independently by a Cozystack contributor; reviewed and approved by the Cozystack platform team for use as the generic-variant HA proxy.

Operators can opt out with `--no-extractedprism` and supply their own `--api-host=<ip>` (external LB, VIP, or single CP IP with the SPOF caveat) — see `cozystack:cluster-install` Phase 4. Talos and hosted variants do not need extractedprism.

## Repository layout

```text
plugins/
  cozystack/                          # platform bundle (11 skills)
    .claude-plugin/plugin.json
    skills/
      wizard/                         # entry point: interview + chain dispatcher
      talos-bootstrap/                # Talos node prep
      talos-reset/                    # cloud-provider terminate+relaunch helper
      ubuntu-bootstrap/               # Ubuntu/Debian via ansible-cozystack wrapper
      cluster-install/                # Cozystack on a ready cluster
      debug/                          # investigate + classify + workaround + issue draft
      cluster-upgrade/                # v1.x patch/minor upgrade
      package-deploy/                 # dev-loop deploy of a single package
      package-bump/                   # bump a monorepo package
      external-app-create/            # scaffold a new external-apps package
      dev-ui-bootstrap/               # bootstrap Playwright + Vite sandbox for cozystack-ui
  linstor/                            # storage bundle (1 skill)
    .claude-plugin/plugin.json
    skills/
      recover/
```

## License

[Apache-2.0](LICENSE)
