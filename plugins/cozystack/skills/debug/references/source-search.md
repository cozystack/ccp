# Searching cozystack monorepo from a symptom

When Phase 3 classified as `upstream-bug`, Phase 4 must name a specific file:line in the cozystack source. "Something is wrong somewhere" doesn't help maintainers and doesn't justify an upstream issue. This document is the recipe for getting from a symptom to a source location.

## Search roots

Local checkouts (preferred — fast, no network, includes diffs against your local branch):

- `~/git/github.com/cozystack/cozystack/` — main monorepo. Charts, operator Go code, platform Package templates.
- `~/git/github.com/cozystack/ansible-cozystack/` — ansible playbooks, role tasks, defaults.
- `~/git/github.com/cozystack/website/` — docs (Hugo content under `content/en/docs/`).
- `~/git/github.com/cozystack/talm/` — talm chart preset + binary source.
- `~/git/github.com/cozystack/boot-to-talos/` — bootstrap helper source.

If a checkout is missing, `cd ~/git/github.com/cozystack && git clone https://github.com/cozystack/<repo>.git` first.

## Patterns by symptom shape

### Chart render failure

The HR status shows something like:

```text
Reason: InstallFailed
Message: ... template: <chart>/templates/_helpers.tpl: error calling fail:
  No nodes found with label 'node-role.kubernetes.io/control-plane=true'.
```

Grep for the `fail` string verbatim:

```bash
grep -rn "No nodes found with label" ~/git/github.com/cozystack/cozystack/packages/system/<chart>/
```

If the chart is vendored under `charts/<name>/`, search there too:

```bash
grep -rn "No nodes found with label" ~/git/github.com/cozystack/cozystack/packages/system/<chart>/charts/
```

The error text usually lives in a `templates/_helpers.tpl` `fail` call. From there, walk back to the `if` block that decides when to fire.

### Operator runtime error

`cozystack-operator` logs an error from its Go source. Grep the Go code:

```bash
# The exact format string from the log line, with %s placeholders replaced by literals.
# Example log: "failed to reconcile HelmRelease cozy-dashboard/dashboard: install timeout"
grep -rn "failed to reconcile HelmRelease" ~/git/github.com/cozystack/cozystack/pkg/ ~/git/github.com/cozystack/cozystack/cmd/
```

If the operator panics, the stack trace gives you the file:line directly. Otherwise look for `fmt.Errorf` / `klog.Error` calls in the matching function.

### Package CR rejected by API server

`kubectl apply` of `cozystack-platform-package.yaml` fails with:

```text
The Package "cozystack.cozystack-platform" is invalid: spec.variant: Unsupported value: "isp-x"
```

The validation lives in the CRD or in admission webhooks:

```bash
# CRD validation schema
grep -rn "spec.variant" ~/git/github.com/cozystack/cozystack/packages/core/installer/templates/

# Admission webhook code
grep -rn "variant" ~/git/github.com/cozystack/cozystack/internal/admission/
```

### piraeus-operator / LINSTOR

These are upstream-upstream — not in the cozystack monorepo. Forward to:

- `https://github.com/piraeusdatastore/piraeus-operator` — the CRDs and reconciler.
- `https://github.com/LINBIT/linstor-server` — the LINSTOR API itself.
- `https://github.com/LINBIT/drbd` — kernel module.

Cozystack pins versions in `packages/system/piraeus-operator/charts/piraeus/Chart.yaml` and `packages/system/linstor/charts/<x>/Chart.yaml`; report the exact upstream version in the issue body.

For LINSTOR-specific failures, prefer `/linstor:recover` — it's more specialised than `cozystack:debug` for that area.

### Kube-OVN / Cilium

Upstream-upstream too:

- `https://github.com/kubeovn/kube-ovn`
- `https://github.com/cilium/cilium`

Cozystack vendors the charts under `packages/system/{kubeovn,cilium}/charts/`. Check `values.yaml` in those subtrees for cozystack-specific overrides before assuming the bug is in upstream.

### Documentation contradicts reality

Three possible outcomes:

1. Docs wrong — file in `cozystack/website`. The relevant page is under `content/en/docs/v<X.Y>/...`.
2. Docs right, chart drifted — file in `cozystack/cozystack`.
3. Both wrong — file in both with cross-links.

Use a side-by-side: `cat ~/git/github.com/cozystack/website/content/en/docs/v1.3/<page>.md` vs the chart values / Go code.

## Helpful grep idioms

```bash
# Find every fail() call in chart templates, mapped to the strings that surface to operators
grep -rn --include='*.tpl' --include='*.yaml' 'fail (printf' ~/git/github.com/cozystack/cozystack/packages/

# Find the cozystack value key that controls a given chart sub-value
grep -rn 'apiServerHost' ~/git/github.com/cozystack/cozystack/packages/core/

# Find the HelmRelease that fires a given chart
grep -rn 'chart: <chart-name>' ~/git/github.com/cozystack/cozystack/packages/core/platform/templates/

# Find changelog entries for a release (sometimes documents the bug already)
grep -rn '<keyword>' ~/git/github.com/cozystack/cozystack/docs/changelogs/v*.md
```

## When source search dead-ends

If 15 minutes of grepping doesn't surface a source location:

1. Re-classify. Maybe it's config drift after all.
2. Ask the operator if the cluster has any non-cozystack operators that might be relevant.
3. Open an exploratory issue in `cozystack/cozystack` with the diagnostic bundle and a request for a maintainer to point at the right code path. Better than silently struggling.

## Recording the find

The Phase 6 state write captures it:

```yaml
status:
  debug:
    target: hr/cozy-dashboard/dashboard
    classification: upstream-bug
    source:
      repo: cozystack/cozystack
      file: packages/system/dashboard/charts/dashboard/templates/gatekeeper.yaml
      line: 47
      summary: "gatekeeper container always dials https://keycloak.${HOST} without a TLS skip-verify switch; values key not exposed"
    action: workaround
    issue_repo: cozystack/cozystack
```

That file:line ends up in the issue body so maintainers know where to look. Without it, the issue is much harder to triage.
