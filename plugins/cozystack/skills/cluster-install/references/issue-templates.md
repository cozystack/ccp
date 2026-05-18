# Upstream issue handoff

When `cozystack:cluster-install` can't continue and the cause looks upstream, assemble a diagnostic bundle and draft an issue body for the user. Never open the issue automatically — the user must read it and choose.

## Routing decision tree

| Failure shape | Repo |
| ----------- | ----------- |
| HelmRelease render or runtime bug; operator panic; resource quotas wrong | `cozystack/cozystack` |
| cozy-installer Helm chart misbehaves (template error, broken hooks, wrong namespace adoption) | `cozystack/cozystack` (label `area/installer`) |
| Docs ambiguous, missing a step, or contradict reality | `cozystack/website` |
| Node prep automation missing a task or broken on a distro | `cozystack/ansible-cozystack` |
| Storage / DRBD / LINSTOR specific failure on a working install | use `linstor:recover` skill before filing — the bug is most likely operational, not upstream |

## Diagnostic bundle

Drop everything below into `<config-dir>/diagnostics-<UTC-timestamp>/` and reference it from the issue body. Strip secrets (`Opaque` / `kubernetes.io/tls` / `kubernetes.io/dockerconfigjson` data fields) before sharing. The diagnostics subdirectory is gitignored automatically (covered by the `*.tar.gz` rule in the cozystack `.gitignore` section).

```bash
TS="$(TZ=UTC date +%Y%m%d-%H%M%S)"
DUMP="$CONFIG_DIR/diagnostics-${TS}"
mkdir -p "$DUMP"

kubectl --context $CTX cluster-info dump --output-directory "$DUMP/cluster-info"
kubectl --context $CTX get nodes --output yaml > "$DUMP/nodes.yaml"
kubectl --context $CTX get hr --all-namespaces --output yaml > "$DUMP/helmreleases.yaml"
kubectl --context $CTX get pods --all-namespaces --output wide > "$DUMP/pods.txt"
kubectl --context $CTX get events --all-namespaces \
  --sort-by=.lastTimestamp > "$DUMP/events.txt"
kubectl --context $CTX --namespace cozy-system logs deploy/cozystack-operator \
  --tail=2000 > "$DUMP/operator.log" 2>&1 || true
kubectl --context $CTX --namespace flux-system logs deploy/helm-controller \
  --tail=2000 > "$DUMP/helm-controller.log" 2>&1 || true
cp /tmp/cozystack-platform-package.yaml "$DUMP/platform-package.yaml" 2>/dev/null || true

# Optional: failing HR detail
for hr in $(kubectl --context $CTX get hr --all-namespaces \
  --output jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready" && @.status!="True")])]}{.metadata.namespace}/{.metadata.name} {end}'); do
  ns=${hr%%/*}; name=${hr##*/}
  kubectl --context $CTX --namespace "$ns" describe hr "$name" > "$DUMP/hr-${ns}-${name}.txt"
done

tar -czf "${DUMP}.tar.gz" --directory /tmp "$(basename "$DUMP")"
echo "Bundle: ${DUMP}.tar.gz"
```

## Issue body templates

All public. English. Singular first person. No private cluster names or client identifiers — replace them in the draft before showing the user. No internal tool names (the user is filing this as a generic bug report).

### cozystack/cozystack (operator / chart / package bug)

```markdown
### What happened

<one paragraph: what `cozystack:cluster-install` was trying to do, what it observed instead. Quote the failing HR's condition message or operator log line verbatim, in a fenced block.>

### Expected behaviour

<one sentence — what the docs / chart values imply should happen.>

### Steps to reproduce

1. Fresh <distribution> v<version> cluster, bootstrapped per `docs/v<X.Y>/install/kubernetes/<distro>/`.
2. `helm upgrade --install cozy-installer oci://ghcr.io/cozystack/cozystack/cozy-installer --version <X.Y.Z> --namespace kube-system --set cozystackOperator.variant=<variant> --set cozystack.apiServerHost=<IP>`
3. Apply Platform Package with `spec.variant: <platform-variant>`. Full Package YAML attached.
4. Observe `kubectl get hr --all-namespaces` — <which HR is stuck and what its condition says>.

### Environment

- Cozystack installer version: <X.Y.Z>
- Kubernetes: <distro> <version>
- Nodes: <N> × <arch> on <OS>
- Variant: <installer> / <platform>

### Logs and manifests

Diagnostic bundle attached: `cozystack-install-<timestamp>.tar.gz` (logs redacted of secrets).
```

### cozystack/website (docs gap)

```markdown
### Documentation page

`https://cozystack.io/docs/v<X.Y>/install/kubernetes/<page>/` (or local path: `content/en/docs/v<X.Y>/install/kubernetes/<page>.md`)

### What I expected to find

<the question I had / the step I needed.>

### What the page says

<quote the relevant section or note it's absent.>

### What I had to do instead

<the workaround, with commands.>

### Suggested change

<one paragraph — what would have unblocked a first-time installer.>
```

### cozystack/ansible-cozystack (playbook gap)

```markdown
### Distribution / OS

<exact OS version, kernel, init system.>

### Task that should exist but doesn't

<which step from `docs/v<X.Y>/install/kubernetes/generic.md` (or equivalent) the role does not automate.>

### Manual workaround

<the commands I ran by hand to get past the gap.>

### Suggested role change

<one paragraph — a new task or a new default that would close the gap.>
```

## `gh` commands (do NOT auto-run)

After showing the draft and getting explicit approval, the user can run:

```bash
gh issue create --repo cozystack/cozystack \
  --title "<short, factual title — no 'cozystack:cluster-install' / tool names>" \
  --body-file <config-dir>/diagnostics-<timestamp>/issue-body.md
```

`cozystack:cluster-install` writes the body to a file under the diagnostic bundle directory so the user can review it before posting.
