# Symptom record + diagnostic bundle

Two pieces of state Phase 1 produces:

- **Symptom record** — a structured in-memory description of what's broken. Used by Phase 2 (doc check), Phase 3 (classify), and Phase 5 (issue body rendering).
- **Diagnostic bundle** — on-disk artefacts (logs, CR dumps, events) that go alongside any upstream issue.

## Symptom record format

The skill builds this in memory; not written to disk on its own (it's embedded in `.state.yaml` under `status.debug` when Phase 6 lands).

```yaml
symptom:
  surface: "hr"                              # hr / pod / namespace / cluster
  namespace: "cozy-dashboard"
  name: "dashboard"
  observed_at: "2026-05-15T18:00:00Z"
  condition:
    type: "Ready"
    status: "False"
    reason: "InstallFailed"
    message: "context deadline exceeded ..."
  recent_events:
    - "2026-05-15T17:50:00Z Warning ReconcileFailure: install retries exhausted (10/10)"
  related_pods:
    - name: "gatekeeper-xxx"
      phase: "Running"
      restarts: 47
      last_log: "Unable to fetch OIDC well-known: dial tcp keycloak.cluster.example.org:443: connection refused"
  dependencies:
    upstream_of:
      - "cozy-fluxcd/flux-plunger"           # depends on this HR
    downstream_of: []
  cluster_context:
    context: "cozystack-lab"
    distribution: "k3s"
    k8s_version: "v1.32.3+k3s1"
    cozystack_installer_version: "v1.3.2"
    platform_variant: "isp-full-generic"
```

This shape is what `references/issue-templates.md` body templates interpolate from. Keep field names stable.

## Diagnostic bundle layout

```
<config-dir>/diagnostics-<UTC-timestamp>/
  README.md                          # one-page summary: symptom + classification
  symptom.yaml                       # the in-memory record dumped to disk
  cluster-info/                      # output of kubectl cluster-info dump
    namespaces/
    nodes.json
    ...
  helmreleases.yaml                  # kubectl get hr -A -o yaml
  pods.txt                           # kubectl get pods -A -o wide
  events.txt                         # kubectl get events -A --sort-by=.lastTimestamp
  failing-hr.txt                     # kubectl describe hr for each not-Ready HR
  operator.log                       # cozystack-operator last 2000 lines
  helm-controller.log                # helm-controller last 2000 lines
  values.yaml                        # cozystack-platform-package.yaml at issue time (REDACTED)
  state.yaml                         # .state.yaml at issue time (REDACTED)
  bundle.tar.gz                      # everything above as a single tarball
```

## Bundle script

Same body as `cluster-install/references/issue-templates.md` — copy verbatim to avoid drift; if the cluster-install version changes, propagate the change here.

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

# Operator-supplied artefacts at the time of failure
cp "$CONFIG_DIR/cozystack-platform-package.yaml" "$DUMP/values.yaml" 2>/dev/null || true
cp "$CONFIG_DIR/.state.yaml" "$DUMP/state.yaml" 2>/dev/null || true

# Per-failing-HR describe
for hr in $(kubectl --context $CTX get hr --all-namespaces \
  --output jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready" && @.status!="True")])]}{.metadata.namespace}/{.metadata.name} {end}'); do
  ns=${hr%%/*}; name=${hr##*/}
  kubectl --context $CTX --namespace "$ns" describe hr "$name" > "$DUMP/hr-${ns}-${name}.txt"
done

# Redact sops-encrypted forms — re-encrypt if state.sops.enabled is true
if [ "$(yq '.sops.enabled // false' "$CONFIG_DIR/.state.yaml" 2>/dev/null)" = "true" ]; then
  # The copies above came from already-encrypted on-disk files; nothing to do.
  :
else
  # Strip secrets from the plain copies before they go anywhere public.
  yq --inplace 'del(.spec.components.platform.values.authentication.oidc)' \
    "$DUMP/values.yaml" 2>/dev/null || true
fi

tar --create --gzip --directory "$CONFIG_DIR" --file "$DUMP.tar.gz" \
  "diagnostics-${TS}"
echo "Bundle: $DUMP.tar.gz"
```

## Redaction rules

The bundle goes to GitHub. Strip these before sharing:

- Any `Opaque` / `kubernetes.io/tls` / `kubernetes.io/dockerconfigjson` Secret `data` fields. `cluster-info dump` includes Secrets; rewrite them to `<REDACTED>`.
- Operator-supplied passwords in values (Keycloak admin, registry creds).
- IP addresses that identify a customer or internal subnet — replace with `<CUSTOMER_IP>` or generic RFC 5737 (`192.0.2.x`).
- Hostnames that identify a customer — replace with `cluster.example.com`.
- SSH key paths from `.state.yaml`.

The `*.tar.gz` glob is in the `.gitignore` cozystack section so bundles never get accidentally committed.

## Bundle path under the cluster config directory

`<config-dir>/diagnostics-<ts>/` keeps every artefact with the cluster it describes. `*.tar.gz` is gitignored. Operators can `rsync` the directory to a colleague or attach the tarball to a support thread.

If `<config-dir>` isn't writable (read-only mount, exotic setup), fall back to `/tmp/cozystack-diagnostics-<ts>/` and surface the path explicitly.
