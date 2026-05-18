# k3s install commands

Exact bodies for the three install phases. The skill substitutes `$K3S_VERSION`, `$CP1_HOST`, `$NODE_TOKEN`, `$EXTRA_TLS_SAN_ARGS` from `state.inventory` and Phase-5 capture.

## Version pin

| Cozystack | k3s |
| ----------- | ----------- |
| v1.3.x | `v1.32.3+k3s1` |
| v1.2.x | `v1.31.4+k3s1` |
| v1.1.x | `v1.30.5+k3s1` |
| v1.0.x | `v1.29.6+k3s1` |

Default is the row matching the cozystack release in `state.cozystack.installer_version` (resolved later) or the latest from `https://github.com/k3s-io/k3s/releases` if the operator overrides. Always pass `INSTALL_K3S_VERSION=<vX.Y.Z+k3sN>` explicitly — `get.k3s.io` floats to the channel tip otherwise.

## First CP — `--cluster-init`

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  INSTALL_K3S_EXEC="server \
    --cluster-init \
    --flannel-backend=none \
    --disable=traefik \
    --disable=servicelb \
    --disable=local-storage \
    --disable=metrics-server \
    --disable-network-policy \
    --disable-kube-proxy \
    --cluster-domain=cozy.local \
    --tls-san=$CP1_HOST \
    $EXTRA_TLS_SAN_ARGS \
    --kubelet-arg=max-pods=220" \
  sh -
```

Flag rationale:

- `--cluster-init` — initialise embedded etcd raft on this node; required for HA. Single-node sandbox still works with this flag.
- `--flannel-backend=none` — disables k3s's built-in CNI. Cozystack ships Cilium + Kube-OVN.
- `--disable=traefik` — Cozystack ships its own ingress (ingress-nginx).
- `--disable=servicelb` — Cozystack ships MetalLB inside the platform Package.
- `--disable=local-storage` — Cozystack ships LINSTOR + piraeus-operator.
- `--disable=metrics-server` — VictoriaMetrics stack covers metrics.
- `--disable-network-policy` — Cilium implements policies.
- `--disable-kube-proxy` — Cilium replaces kube-proxy.
- `--cluster-domain=cozy.local` — mandatory for Cozystack. Cluster-install Phase 2 refuses if this isn't set.
- `--tls-san=$CP1_HOST` — adds the CP's IP to the apiserver cert SAN list so clients dialling directly at the IP don't get a cert mismatch.
- `$EXTRA_TLS_SAN_ARGS` — one `--tls-san=<HOST>` per CP in the inventory plus the VIP. Pre-computed before install.
- `--kubelet-arg=max-pods=220` — Cozystack's `talm` preset uses 512; for generic linux 220 is a safe floor without overflowing iptables hashing.

## Additional CP — join existing etcd

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  K3S_TOKEN="$NODE_TOKEN" \
  INSTALL_K3S_EXEC="server \
    --server https://$CP1_HOST:6443 \
    --flannel-backend=none \
    --disable=traefik \
    --disable=servicelb \
    --disable=local-storage \
    --disable=metrics-server \
    --disable-network-policy \
    --disable-kube-proxy \
    --cluster-domain=cozy.local \
    --tls-san=$THIS_CP_HOST \
    $EXTRA_TLS_SAN_ARGS \
    --kubelet-arg=max-pods=220" \
  sh -
```

`--server` points at the first CP. After joining, the new server is also a member of the raft — kill CP1 and the cluster keeps running, provided quorum (≥ 2 of 3 etcd members) survives.

`K3S_TOKEN` is `cat /var/lib/rancher/k3s/server/node-token` from CP1 (captured at the end of Phase 5). The skill keeps it in memory; **do not** write it to `state.yaml` (it's a node-level secret).

## Agent worker

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  K3S_URL=https://$CP1_HOST:6443 \
  K3S_TOKEN="$NODE_TOKEN" \
  sh -
```

Agent install is much simpler — no `INSTALL_K3S_EXEC`, no flag list. The server's disable list is already in effect cluster-wide.

If `inventory.vip` is set, `K3S_URL=https://$VIP:6443` is **also** valid and arguably safer (workers survive CP1 going away). v1 sticks with `CP1_HOST` for simplicity and prints a note.

## Service-readiness probe after each install

```bash
ssh -i "$SSH_KEY" "$SSH_USER@$HOST" '
  systemctl is-active k3s || systemctl is-active k3s-agent
  systemctl is-enabled k3s 2>/dev/null || systemctl is-enabled k3s-agent
'
```

Then, from CP1:

```bash
ssh -i "$SSH_KEY" "$SSH_USER@$CP1_HOST" \
  'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl wait --for=condition=Ready node/$NEW_NODE --timeout=120s'
```

If `kubectl wait` times out → node didn't fully join (network, cert SAN mismatch, taint). Abort.

## Common pitfalls

- **`+k3s1` suffix vs container image tag** — kubelet reports `v1.35.0+k3s1`, but `+` is invalid in Docker image tags. Cozystack's linstor-scheduler hit this in old releases; the v1.0+ chart sanitises. Operator doesn't need to do anything — just be aware that `kubectl version` looks unusual.
- **`tls-san` after install** — adding a SAN later requires recreating the certs (`k3s certificate rotate`). Include every name/IP/VIP upfront.
- **Re-run after partial failure** — `k3s` install script is idempotent if `/etc/systemd/system/k3s.service` already exists and is active. Cozystack:k3s-bootstrap detects this in Phase 5 and skips with a "already installed at $VERSION — skipping" line.
- **Wrong cluster domain** — `--cluster-domain=cozy.local` is the only acceptable value for Cozystack. Without it, cluster-install Phase 2 refuses.

## Why no `--write-kubeconfig-mode=0644`

The skill fetches `/etc/rancher/k3s/k3s.yaml` over `scp` with `sudo` — file mode on the node stays `0600` (k3s default). Don't loosen it for convenience.
