# Kubeconfig retrieval and merge

Phase 8 fetches `/etc/rancher/k3s/k3s.yaml` from the first CP node, rewrites the server URL from `https://127.0.0.1:6443` to the CP's IP (or the VIP), then either saves it standalone or merges it into the operator's existing `~/.kube/config`.

## Standalone path

```bash
TS="$STATE_TS"
TMP="/tmp/cozystack-install-$TS/k3s.yaml"
TARGET="$HOME/.kube/cozystack-lab.yaml"  # ask operator for the target path

scp -q -i "$SSH_KEY" "$SSH_USER@$CP1_HOST:/etc/rancher/k3s/k3s.yaml" "$TMP"

# Rewrite the loopback URL. Pick the right server:
#   - inventory.vip if set
#   - else CP1_HOST
SERVER_URL="https://${VIP:-$CP1_HOST}:6443"
sed -i.bak "s#https://127\.0\.0\.1:6443#$SERVER_URL#g" "$TMP"
rm -f "${TMP}.bak"

chmod 0600 "$TMP"
mv "$TMP" "$TARGET"
chmod 0600 "$TARGET"
```

Verify:

```bash
KUBECONFIG="$TARGET" kubectl config get-contexts
KUBECONFIG="$TARGET" kubectl get nodes
```

Result: every inventory node in `Ready`.

## Merge path (preferred when `kubecm` is installed)

```bash
kubectl krew install kc        # if not installed yet — once per workstation
kubectl kc add --file "$TMP" --context-name cozystack-lab --cover
```

`--cover` writes the merged result back to `~/.kube/config` instead of a sibling file. The new context is named `cozystack-lab` (or whatever the operator picked).

Test the merged context:

```bash
kubectl --context cozystack-lab get nodes
```

## Context naming conflict

If `cozystack-lab` already exists in `~/.kube/config` (operator ran the skill before, then re-bootstrapped a different cluster with the same name), `kubectl kc add` will refuse / overwrite without warning. Options the skill offers:

- Pick a different name (suggest `cozystack-lab-2`, `cozystack-lab-$TS`).
- Delete the old context first: `kubectl kc delete cozystack-lab`. Surface the dropped cluster's `server` URL so the operator can confirm they really want to forget it.

## What to store in `state.yaml`

After the merge / standalone path:

```yaml
cluster:
  context: cozystack-lab
  kubeconfig: ~/.kube/config       # if merged; else the standalone path
  api_endpoint: https://10.0.0.10:6443
```

Downstream skills (`cluster-install`) read `cluster.context` and trust it. They do not re-read the kubeconfig file from `state.yaml`; the OS lookup chain (`$KUBECONFIG` env, then `~/.kube/config`) covers it.

## When to leave it standalone

For lab / multi-cluster workflows where the operator manages multiple clusters with sibling files (`~/.kube/cozystack-lab.yaml`, `~/.kube/cozystack-prod.yaml`), don't merge. Standalone keeps each cluster's lifecycle independent.

The operator picks merge vs standalone at the Phase 8 gate.

## Don't lose the node-token

The kubeconfig is recoverable from CP1 as long as CP1 is alive (or any CP in HA). The node-token cannot be regenerated post-install — if the operator wipes `/var/lib/rancher/k3s/server/` they're rebuilding from scratch. The skill does not back it up automatically (it's a secret); if the operator wants belt-and-braces, suggest:

```bash
ssh -i "$SSH_KEY" "$SSH_USER@$CP1_HOST" 'sudo cat /var/lib/rancher/k3s/server/node-token' \
  > ~/cozystack-lab-node-token.txt
chmod 0600 ~/cozystack-lab-node-token.txt
```

Surface this as an optional step at the end of Phase 7, **not** Phase 8 (no kubeconfig coupling).
