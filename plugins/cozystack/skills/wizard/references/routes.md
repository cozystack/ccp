# Routes: target × chain

After the v1 refactor the wizard supports exactly **three** routes plus one refusal. Anything more nuanced lives in the downstream skill, not in the wizard interview.

| Target | Chain | Notes |
| ----------- | ----------- | ----------- |
| Bare-metal Talos | `talos-bootstrap` → `cluster-install` | Talos image factory + talm + manifests dir — handled by `talos-bootstrap` v1 stub (guided checklist; full automation is a follow-up). |
| Bare-metal Ubuntu / Debian | `ubuntu-bootstrap` → `cluster-install` | `ubuntu-bootstrap` is an ansible wrapper around upstream `cozystack/ansible-cozystack/examples/ubuntu/`. Covers OS prep, drbd-dkms / ZFS / KubeVirt, k3s install. |
| Existing Kubernetes (self-managed or managed) | `cluster-install` | Same skill handles vanilla self-managed (kubeadm / k3s / RKE2 already in place) and managed (EKS / GKE / AKS / DOKS). `cluster-install` picks the right installer variant — `generic` or `hosted` — from cluster lookup. |
| Existing Cozystack | **refuse** → `cozystack:cluster-upgrade` | `cozy-system` namespace already holds pods; this is an upgrade scenario, not an install. |

## Recommended-by-load hints

Surface these in the Phase 2 question text so click-ops operators have a hint, but never force the choice:

- **General-purpose / VMs / databases** → Talos (Recommended for prod). Immutable, predictable kernel modules, all cozystack extensions baked into the cozystack-tuned image.
- **GPU workloads / custom userspace drivers** → Ubuntu. NVIDIA / AMD driver paths are more turnkey on Ubuntu than on Talos; custom kernel modules outside Talos's extension catalog need a generic Linux.
- **Cloud / managed Kubernetes** → Existing cluster. Provider runs the control plane; cozystack runs only the workload-layer (`hosted` variant — no LINSTOR, no KubeVirt).

## Refusal flows

- **Existing Cozystack** — wizard prints: "This cluster already runs Cozystack. Run `/cozystack:cluster-upgrade` to upgrade. If you want to wipe and reinstall, delete `cozy-system` namespace and any `package.cozystack.io` CRs manually first, then re-run wizard."
- **Managed k8s where Phase 3 of `cluster-install` would refuse** — managed providers (EKS et al.) don't allow `kubectl debug node` reliably; `cluster-install` notices and runs in hosted-variant mode that doesn't need node-level mutations.
- **Unsupported target** — Windows, k8s versions below the floor in `cluster-install/references/requirements.md`, etc. — wizard refuses early.

## Why the OS-axis question, not a workload-axis question

An earlier draft asked "what workload?" first (general / GPU / VMs / databases) and inferred OS. That added a layer of indirection without removing any question — the operator still ended up picking Talos vs Ubuntu eventually, just one screen later. The current shape (one OS-axis question with workload hints in the prompt text) is shorter for the operator and exactly as informative.

## What the wizard does NOT decide

- `apiServerHost` (Talos KubePrism vs extractedprism vs operator-supplied) — `cluster-install` Phase 4.
- Storage backend (ZFS, no choice) — `cluster-install` Phase 4 + Phase 5.5.
- DNS / cert-manager solver — `cluster-install` Phase 4.
- k3s / kubeadm / RKE2 — wizard picks k3s via `ubuntu-bootstrap` (v1). Other distributions are out of scope until there's a real reason.
