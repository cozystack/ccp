# Watching HelmReleases until green

After applying the Platform Package, the operator reconciles the bundle and emits dozens of HelmReleases. Don't declare success until every expected HR reports `Ready=True`.

## Shell compatibility (helper scripts the skill emits)

Watch loops and other helper scripts the skill writes to `/tmp/` or `<config-dir>/` MUST be portable across macOS bash 3.2 (`/bin/bash` on macOS) and Linux bash 4+/5+:

- Shebang: `#!/usr/bin/env bash` — picks up Homebrew bash 5 on macOS when on PATH, falls back to system bash on Linux.
- **Avoid bash 4+ features** in emitted scripts: no `declare -A` (associative arrays), no `mapfile -t` (use `while IFS= read -r ...`), no `${var,,}` / `${var^^}` case conversion (use `tr '[:upper:]' '[:lower:]'`), no `**` globstar (enable explicitly only when guarded with `(( BASH_VERSINFO[0] >= 4 ))`).
- When an associative-array-like structure is genuinely needed, fall back to two parallel arrays + a linear lookup loop, or write the data to a tempfile and use `awk` / `jq` / `yq` to query.
- For the rare case where bash 4+ is unavoidable, document it loudly in the script header and add a runtime guard:

  ```bash
  #!/usr/bin/env bash
  if (( BASH_VERSINFO[0] < 4 )); then
    echo "This script needs bash 4+; on macOS install via 'brew install bash' and re-run." >&2
    exit 1
  fi
  ```

A real session hit a bash-3.2 incompatibility on macOS where `declare -A` failed silently and the watch loop never ran. Default to POSIX-compatible constructs unless guarded.

## Polling loop

```bash
kubectl --context $CTX get hr --all-namespaces --output json
```

Parse the array; for each HR extract `metadata.namespace`, `metadata.name`, the `Ready` condition status, and `lastAppliedRevision`. Summarise as `Ready: N/M, Progressing: P, Failing: F` every 30 seconds. List the failing ones explicitly.

Cap the loop at 60 minutes. Initial reconcile on a slow registry can take 30+ minutes.

## What "expected" means by variant

The Platform values render a different set of HRs per bundle. Read the actual list from the cluster — don't hard-code, the chart evolves.

```bash
# Once the operator has settled — usually 1–2 minutes after Package apply.
kubectl --context $CTX get hr --all-namespaces --output jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' | sort -u
```

That list is your denominator. Refresh it on every poll — new HRs appear as dependencies unlock.

Typical counts for orientation (not gospel):

| Variant | Approx HR count |
| ----------- | ----------- |
| `isp-full` | 40–50 |
| `isp-full-generic` | 40–50 |
| `isp-hosted` | 15–20 |
| `default` | 1–3 |

## Reading a stuck HR

For each HR not Ready after 5 minutes:

```bash
kubectl --context $CTX --namespace $NS describe helmrelease $NAME | sed -n '/Status:/,$p'
kubectl --context $CTX --namespace $NS get events --sort-by=.lastTimestamp \
  --field-selector involvedObject.kind=HelmRelease,involvedObject.name=$NAME
```

Helm-controller log slice:

```bash
kubectl --context $CTX --namespace flux-system logs deploy/helm-controller --tail=100 \
  | grep -i "$NAME" || true
```

Operator log slice:

```bash
kubectl --context $CTX --namespace cozy-system logs deploy/cozystack-operator --tail=100
```

## Expected transient errors (not blockers)

For the first ~5 minutes after Package apply:

- `ExternalArtifact not found` — chart artifact not pulled yet.
- `dependency is not ready: cozy-cilium` — Cilium hasn't finished installing.
- HRs in `Progressing` with empty `lastAppliedRevision` — initial install.

These are normal. Don't escalate before five minutes have passed since the HR's `lastTransitionTime`.

## Reading the operator's view

The operator exposes its own status on the `Package` CR:

```bash
kubectl --context $CTX get package cozystack.cozystack-platform --output yaml | sed -n '/status:/,$p'
```

When the operator considers the bundle reconciled, `status.conditions[Type=Ready].status=True`.

## When to escalate

A stuck HR is worth escalating (offer the user to abort or capture a diagnostic bundle) when:

- It's been `Failing` for > 10 minutes with the same error.
- Helm-controller log shows a stack trace or `context deadline exceeded` repeating.
- Operator log shows a panic.
- Pods in the HR's namespace are in `ImagePullBackOff`, `CrashLoopBackOff`, or `Pending` with no scheduling event.

Don't escalate just because progress is slow — pulls on a fresh cluster can take 20 minutes on a thin uplink.
