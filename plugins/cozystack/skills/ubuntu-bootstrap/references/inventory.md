# Inventory interview

Goal: produce a `state.inventory` block that downstream phases (SSH preflight, OS prep, k3s install) can iterate over without further questions. Keep it short — the operator picks defaults for everything when possible.

## Questions

1. **SSH user** — default `root`. Common alternatives `ubuntu` (cloud images) and `debian`. If the user isn't root, `sudo -n` must work (passwordless sudo).

2. **SSH key path** — default `~/.ssh/id_ed25519`. Verify the file exists and is readable. Reject any path containing spaces or globs.

3. **Nodes** — collect one row per node:
   - `host` — IPv4 or DNS name. Validate format with a regex (RFC 1123 hostname or IPv4 dotted-quad).
   - `role` — `cp` or `worker`. Recommended: 3 × cp, then workers as needed.
   - `name` — optional override. If empty, infer from hostname at OS-prep time.

   Cap at 32 nodes in v1 (UX wall — the per-node loops get unmanageable).

4. **Virtual IP (VIP)** — optional. Used as `--tls-san=$VIP` so the kube-apiserver certificate accepts traffic to the VIP, even though the VIP itself is managed externally (keepalived, kube-vip, cloud LB). If specified, every CP also gets `--tls-san=<own-IP>` plus the VIP.

5. **k3s version** — defaults to `v1.32.3+k3s1` (verified against Cozystack v1.3.x). If the operator passes `--k3s-version=...`, validate it matches the format `v\d+\.\d+\.\d+\+k3s\d+`.

## Role rules

- At least 1 `cp` node — sandbox mode.
- HA quorum requires odd `cp` count ≥ 3. Two CPs is a split-brain anti-pattern; refuse it unless the operator explicitly overrides.
- Workers are optional in single-node sandbox (CP can run workloads).

## HA prerequisites

The skill installs k3s with `--cluster-init` on the first CP (embedded etcd raft) and joins additional CPs via `--server https://$CP1_HOST:6443`. For HA to actually be HA, the operator must arrange:

- A way to reach kube-apiserver after CP1 is gone. Three options the skill does NOT configure for the operator:
  - A virtual IP (keepalived / kube-vip) — operator runs it on the CP nodes themselves. Surface the VIP question; if specified, add it to `tls-san`.
  - An external L4 LB (HAProxy, cloud LB) in front of all CP IPs on port 6443. Operator configures it.
  - DNS round-robin — basic, no health checks. Don't recommend in v1.
- Identical hardware / OS version across CPs (recommended). The skill does not enforce, but surfaces a warning if `nodeInfo.osImage` differs.

## Output shape

The skill emits exactly this into `state.inventory`:

```yaml
inventory:
  ssh_user: "ubuntu"
  ssh_key: "/Users/me/.ssh/cozystack-lab"
  vip: ""                          # empty means no VIP
  nodes:
    - host: "10.0.0.10"
      role: "cp"
      name: "cp1"
    - host: "10.0.0.11"
      role: "cp"
      name: "cp2"
    - host: "10.0.0.12"
      role: "cp"
      name: "cp3"
    - host: "10.0.0.20"
      role: "worker"
      name: "w1"
```

## Validation checklist before moving to Phase 2

- All hosts unique (no duplicates).
- All names unique (after inference).
- Role counts sane (1 cp + 0..N workers, **or** 3 cp + 0..N workers — refuse 2-cp).
- SSH key file exists, mode 0600 or 0400 (warn otherwise).
- VIP, if specified, is not in `nodes[].host`.

A failed validation goes back to the interview, not forward into SSH preflight.
