---
name: cozy-bump
description: Bump a single package inside the cozystack monorepo (`packages/{apps,system,extra,core}/<name>/`). Detects the upstream source (vendored Helm chart, in-repo image build, or postgres-style enum), fetches the changelog between current and target versions, surfaces breaking changes / deprecated values / new required keys, applies adaptations, regenerates schema and ApplicationDefinition, runs `helm template` + `helm lint`, commits with a Conventional-Commit message, and optionally deploys the bumped version to a dev cluster via `cozyhr suspend` + `make apply` with a `ttl.sh` ephemeral image registry. Use when raising the upstream version of a cozystack-shipped component (e.g. bumping `apps/postgres` from 16.2 to 16.4, or refreshing a vendored subchart in `system/*`).
argument-hint: "<package-path-or-name> [--target-version=<ver>] [--no-deploy] [--registry=ttl.sh/<uuid>] [--allow-dirty]"
---

# cozy-bump

This skill bumps the upstream version of a single package inside the cozystack monorepo (`~/git/github.com/cozystack/cozystack`, layout `packages/{apps,system,extra,core}/<name>/`). The bump is treated as a real review task — the changelog between the current and target versions is read, breaking changes and deprecations are surfaced, the package's own `values.yaml` and templates are adapted accordingly, and the result is verified locally before any commit.

This skill **does** modify files inside the cozystack checkout, **does** create one signed-off commit, and **may** deploy the bumped version to a dev cluster on user approval. It **does not** push, open PRs, or touch production clusters.

Work in reasoning mode. Follow the phases in order. When a step fails or is ambiguous, stop and ask — do not guess upstream versions, image digests, or breaking-change semantics. Use the phrasing "`cozy-bump`" (not "the skill") in messages to the user, and state progress at each phase boundary.

## Phase 1 — Parse arguments

`$ARGUMENTS` contains the free-form tail after `/cozy-bump`. Extract:

- Positional `<package-path-or-name>` — required. Either an absolute path, a path relative to the monorepo root (`packages/apps/postgres`), or a bare name (`postgres`) which is then resolved against `packages/{apps,system,extra,core}/<name>/`. If multiple matches are found across types, ask the user via `AskUserQuestion` which one.
- `--target-version=<ver>` — explicit target (`16.4`, `v1.25.0`, `2.7.5`). If omitted, Phase 3 resolves the latest from upstream and asks the user to confirm.
- `--no-deploy` — skip Phase 9 entirely (no prompt, no deploy).
- `--registry=ttl.sh/<uuid>` — reuse an existing `ttl.sh` registry from a previous run (so a rebuild lands on the same image path). If omitted, Phase 9 generates a fresh UUID.
- `--allow-dirty` — let Phase 2 proceed when the working tree has uncommitted changes. Default is to refuse.

Record `$PKG_DIR` (absolute), `$PKG_NAME` (basename), `$PKG_TYPE` (`apps`/`system`/`extra`/`core`), `$TARGET_VERSION` (may be empty until Phase 3), `$ALLOW_DIRTY`, `$NO_DEPLOY`, `$REGISTRY` (may be empty).

If `<package-path-or-name>` is missing, ask via `AskUserQuestion` — do not invent a default.

## Phase 2 — Pre-flight checks

Bail early if any check fails.

1. **Monorepo location**: verify the resolved `$PKG_DIR` lives under a clone whose root contains `hack/package.mk` and `hack/common-envs.mk`. If not, tell the user to `cd` into a cozystack monorepo checkout or set `$COZYSTACK_REPO`. Stop.
2. **Package shape**: verify `$PKG_DIR/Chart.yaml` exists and `Chart.yaml.version` is the placeholder `0.0.0` (every package in this monorepo follows that convention; a non-`0.0.0` value indicates a manually edited file or a non-package directory). Verify `$PKG_DIR/Makefile` exists and includes `hack/package.mk` (grep for `include .*package.mk`).
3. **Working tree**: run `git -C <repo-root> status --porcelain --untracked-files=no`. If output is non-empty and `$ALLOW_DIRTY` is unset, print a one-line summary and stop. Recommend `git stash` or `--allow-dirty`.
4. **Tools installed**: check that `yq` (v4), `jq`, `helm`, `docker buildx`, `cozyhr`, `cozyvalues-gen`, `kubectl`, `git`, `gh` are on `PATH` via `command -v`. Missing required tools → print install hints (link to each project's releases page) and stop. `gh` is required only for changelog scraping — if it is missing, warn and fall back to raw `curl` against the GitHub REST API in Phase 4.
5. **GPG signing**: read `git -C <repo-root> config commit.gpgsign`. If `true`, note that the Phase 8 commit will prompt for a YubiKey/PIN — surface this upfront so the user knows to be available.
6. **Cluster context** (only when Phase 9 will run, i.e. `--no-deploy` is unset): read `kubectl config current-context`. Record `$KUBE_CONTEXT`. Do **not** verify cluster reachability yet — Phase 9 confirms the context with the user before any cluster call.

State `$PKG_DIR`, `$PKG_NAME`, `$PKG_TYPE`, working-tree status, and tool availability back to the user, then proceed.

## Phase 3 — Detect upstream and current version

Cozystack packages follow three distinct upstream patterns. Detect which one applies, then resolve the current and target versions.

### Pattern A — Vendored upstream Helm chart

Indicators:
- `$PKG_DIR/Chart.yaml` has a `dependencies:` block listing one or more upstream charts, and/or
- `$PKG_DIR/charts/` contains one or more sub-chart tarballs or directories.

Resolve:
- **Current version**: read each entry's `version:` from `Chart.yaml.dependencies[]`. If the dependency lives in `charts/<name>/Chart.yaml`, read `version:` from there.
- **Target version**: if `$TARGET_VERSION` is set, use it. Otherwise:
  ```bash
  helm repo add --force-update <repo-name> <repo-url>
  helm search repo <repo-name>/<chart-name> --versions --output json | jq -r '.[0].version'
  ```
  For OCI repos: `helm show chart oci://<repo>/<chart> --version <semver-range>`. Present the discovered latest to the user via `AskUserQuestion` and let them confirm or override.
- Source-of-truth for changelog: the upstream project's GitHub repo, derived from `Chart.yaml.dependencies[].repository` (resolve via `helm show chart` and read its `home:` / `sources:` fields).

### Pattern B — In-repo image build

Indicators:
- `$PKG_DIR/Makefile` defines an `image:` or `image-<name>:` target driving `docker buildx build` (grep `Makefile` for `docker buildx`).
- `$PKG_DIR/values.yaml` carries the image reference inline, written by the build via `yq --inplace '.<key>.image = strenv(IMAGE)' values.yaml`.

Resolve:
- **Current version**: parse the existing image ref from `values.yaml` — `yq -r '.<key>.image' values.yaml`. The tag portion (between `:` and `@sha256:`) is the current version.
- **Target version**: ask the user. For first-party images built from the cozystack repo itself, this is typically the next git tag of the cozystack monorepo. For images built from `images/<name>/Dockerfile` that wrap a third-party project, ask the user for the target upstream release (the `Dockerfile` usually pins a base image or `--build-arg VERSION=`).
- Source-of-truth for changelog: depends — for cozystack-internal components, `git log` between tags in this repo. For third-party wrappers, the wrapped project's GitHub releases.

### Pattern C — Postgres-style version enum

Indicators:
- `$PKG_DIR/files/versions.yaml` exists.
- `$PKG_DIR/hack/update-versions.sh` exists.

Resolve:
- **Current versions**: read `files/versions.yaml`.
- **Target versions**: re-run `hack/update-versions.sh` (it queries upstream registries and rewrites the file). Diff the result against `git show HEAD:files/versions.yaml` to identify the new entries. Present the diff to the user — they pick which majors/minors are in scope for this bump.
- Source-of-truth for changelog: the upstream project's release page (e.g., CNPG postgres-containers GitHub README for postgres, mariadb releases for mariadb).

### Ambiguity

If indicators are mixed (e.g., a chart has both a vendored sub-chart AND an in-repo image build — common for `system/*` packages), surface every detected pattern via `AskUserQuestion` and let the user pick which one this bump targets. Multi-pattern bumps in a single invocation are out of scope — ask the user to run `cozy-bump` once per bump.

Record `$BUMP_PATTERN` (`A`/`B`/`C`), `$CURRENT_VERSION`, `$TARGET_VERSION`, `$UPSTREAM_REPO_URL` (the GitHub URL where releases live), `$UPSTREAM_OWNER`, `$UPSTREAM_REPO_NAME`. If any of these cannot be resolved, stop and ask — do not guess.

## Phase 4 — Read changelogs and detect breaking changes

Now that the current/target window is known, scrape the upstream changelog and analyze it. The output of this phase is a structured **adaptation list** that drives Phase 6.

### Step 1 — Fetch release notes

```bash
gh release list --repo $UPSTREAM_OWNER/$UPSTREAM_REPO_NAME --limit 100 \
  --json tagName,name,publishedAt > /tmp/cozy-bump-releases.json
```

Filter to tags whose semver lies strictly between `$CURRENT_VERSION` (exclusive) and `$TARGET_VERSION` (inclusive). Tag prefixes vary — accept both `v1.2.3` and `1.2.3`; normalize via `semver` semantics, not string compare.

For each tag in the window:

```bash
gh release view <tag> --repo $UPSTREAM_OWNER/$UPSTREAM_REPO_NAME \
  --json tagName,name,body > /tmp/cozy-bump-release-<tag>.json
```

Concatenate the `body` fields into `/tmp/cozy-bump-changelog.md` with `## <tag>` headers between sections.

If `gh release list` returns nothing for a project that uses tag-only releases (no GitHub Release objects), fall back to `git ls-remote --tags https://github.com/$UPSTREAM_OWNER/$UPSTREAM_REPO_NAME` plus reading `CHANGELOG.md` from the repo at each tag. If that also fails (sparse releases, no CHANGELOG), stop and ask the user where the changelog lives — never proceed without changelog evidence.

### Step 2 — Helm values diff (Pattern A only)

```bash
helm show values <repo-name>/<chart-name> --version $CURRENT_VERSION > /tmp/cozy-bump-values-current.yaml
helm show values <repo-name>/<chart-name> --version $TARGET_VERSION > /tmp/cozy-bump-values-target.yaml
diff --unified=0 /tmp/cozy-bump-values-current.yaml /tmp/cozy-bump-values-target.yaml \
  > /tmp/cozy-bump-values.diff
```

The diff is the most reliable indicator of renamed/removed/added top-level keys.

### Step 3 — CRD diff (Pattern A, when the chart ships CRDs)

If the chart has `crds/` or `templates/` containing `kind: CustomResourceDefinition`, render both versions with `helm template` and diff the resulting CRD YAML. Flag any change to `spec.versions[].schema.openAPIV3Schema` — schema-level breaking changes are common at major-version bumps and frequently missed by changelog text alone.

### Step 4 — Changelog analysis

Scan `/tmp/cozy-bump-changelog.md` for, case-insensitive: `BREAKING`, `breaking change`, `deprecat`, `removed`, `renamed`, `migration`, `action required`, `incompatible`, `must`. For each hit, capture the surrounding bullet/paragraph plus the tag it came from.

Cross-reference each finding against the actual package state:

- **Removed/renamed key in upstream values**: grep the package's `$PKG_DIR/values.yaml` and `$PKG_DIR/templates/` for references to the old key. Every reference becomes a Phase 6 adaptation.
- **New required key**: check whether the package's `$PKG_DIR/values.yaml` already provides a default. If not, an adaptation entry is needed.
- **Renamed CRD field / removed API version**: grep `$PKG_DIR/templates/` for the old field/version. Every match is an adaptation.
- **Behavior change (new default, changed default)**: note for the plan, but only emit an adaptation if the old behavior was relied on (i.e., explicitly set in the package's values).

### Step 5 — Build the adaptation list

Each adaptation entry is a row of:

| field | example |
| --- | --- |
| `file` | `values.yaml`, `templates/deployment.yaml` |
| `key_or_path` | `.image.repository`, `.spec.containers[0].env[1].name` |
| `action` | `rename`, `remove`, `add`, `update`, `review` |
| `old_value` | `oldKey: foo` |
| `new_value` | `newKey: foo` |
| `evidence` | tag + one-line excerpt from `/tmp/cozy-bump-changelog.md` |

If the changelog is silent on something the diffs reveal (e.g., a values key removed without notice), still create an entry with `evidence: "values diff (no changelog mention)"` — these are the fragile spots.

If **no adaptations** are found and the changelog says "no breaking changes", record that explicitly. The plan still needs to reflect that the bump is mechanically simple.

## Phase 5 — Present plan (single approval gate)

Assemble every decision so far into one consolidated plan. Show via `AskUserQuestion`:

```text
cozy-bump plan for $PKG_TYPE/$PKG_NAME

Pattern:         $BUMP_PATTERN ($CURRENT_VERSION → $TARGET_VERSION)
Upstream:        https://github.com/$UPSTREAM_OWNER/$UPSTREAM_REPO_NAME
Changelog tags:  <list of tags scraped>

Files that will change:
  - Chart.yaml         (appVersion: $CURRENT_VERSION → $TARGET_VERSION)
  - charts/            (helm pull / helm dep update)            [Pattern A only]
  - values.yaml        (<N> adaptation(s) from changelog/diff)
  - templates/         (<M> reference(s) to renamed keys)
  - values.schema.json (regenerated via cozyvalues-gen)
  - <ApplicationDefinition file>  (regenerated via hack/update-crd.sh)

Adaptations (from changelog + values/CRD diffs):
  1. <file>:<key>  <action>  — evidence: <tag> "<one-line excerpt>"
  2. ...

Phase 9 (deploy):  $DEPLOY_PHASE_DECISION  (will be asked again with full context)
Commit:            chore(packages/$PKG_TYPE/$PKG_NAME): bump to $TARGET_VERSION
                   (signed off, GPG-signed if commit.gpgsign=true)
```

Three options: `approve` / `edit <phase>` / `abort`.

- `approve` → set `$PLAN_APPROVED = true`. Phases 6–8 proceed without further per-step prompts. Phase 9 still has its own gate.
- `edit <phase>` → return to the named phase and re-collect input.
- `abort` → stop. No files changed.

Without this gate, the user only sees the bump as files start landing on disk. Always run it.

## Phase 6 — Apply bumps

Skip per-step confirmations when `$PLAN_APPROVED` is true; still confirm on file collisions or unexpected diffs.

### Step 1 — `Chart.yaml.appVersion`

```bash
yq --inplace '.appVersion = strenv(TARGET_VERSION)' "$PKG_DIR/Chart.yaml"
```

Never touch `Chart.yaml.version` — it is the build-time placeholder `0.0.0`.

### Step 2 — Pull vendored chart updates (Pattern A)

If the package has a per-package update target:

```bash
make --directory $PKG_DIR <dep>-update
```

(naming convention: `<dep>-update`, e.g. `make postgres-operator-update`). Otherwise, run `helm pull` directly into `charts/`:

```bash
helm pull <repo-name>/<chart-name> --version $TARGET_VERSION --untar --untardir $PKG_DIR/charts
```

Verify the new sub-chart directory contains the expected `Chart.yaml.version`. Remove the old sub-chart directory if the helm-pull placed the new one alongside.

### Step 3 — Apply the adaptation list

For each adaptation entry from Phase 4 Step 5:

- **`rename` / `update`**: edit the named file via `yq --inplace` (for YAML) or a single targeted Edit (for templates with Helm template syntax). Preserve surrounding indentation, preserve comments.
- **`remove`**: confirm with the user before deleting (one prompt, listing all `remove` actions in a single batch).
- **`add`**: insert the new key/value into `values.yaml`. Use the upstream chart's default as the value, with a comment line above pointing to the changelog evidence.
- **`review`**: do not auto-apply. Surface to the user with the evidence and let them decide.

After every batch, re-run the relevant grep from Phase 4 Step 4 to confirm no straggler references remain.

### Step 4 — Regenerate schema and ApplicationDefinition

```bash
make --directory $PKG_DIR generate
```

The `generate` target (defined per package, typically wrapping `cozyvalues-gen` + `hack/update-crd.sh`) rebuilds:
- `values.schema.json`
- The corresponding `packages/system/<name>-rd/cozyrds/<name>.yaml` ApplicationDefinition (when this package has one).

If the package has no `generate` target, skip — but verify `values.schema.json` exists and is consistent with the new `values.yaml`. If it diverges, stop and ask.

### Step 5 — Image-build packages (Pattern B)

Defer the actual `make image` invocation to Phase 9 if the user is going to deploy. Otherwise, skip — the cozystack release pipeline will rebuild the image at tag time and write the digest into `values.yaml`. Bumping the digest locally without deploying is a no-op for upstream consumers.

If the user explicitly asks for a local image build outside Phase 9 (for offline review of the resulting `values.yaml` digest), run:

```bash
REGISTRY=$REGISTRY TAG=$TAG PLATFORM=linux/amd64 PUSH=1 make --directory $PKG_DIR image
```

But this is unusual. The default is "no local build outside Phase 9".

## Phase 7 — Local verification

Hard gates. If any fails, **stop and report**, do not commit, do not deploy.

```bash
helm template $PKG_DIR --output-dir /tmp/cozy-bump-template-out
helm lint $PKG_DIR
git -C <repo-root> diff --stat $PKG_DIR
```

Show the user:
- A one-line pass/fail per check.
- The `git diff --stat` output (file-level summary).
- On request: full `git diff` for any single file.

If `helm template` or `helm lint` fail, surface the error verbatim. The most common failure at this point is a Phase 6 adaptation that introduced a typo or moved a value into a wrong nesting level — read the failure carefully before editing.

## Phase 8 — Commit

One commit per `cozy-bump` invocation. Format:

```text
chore(packages/$PKG_TYPE/$PKG_NAME): bump $PKG_NAME to $TARGET_VERSION

<2–3 line summary distilled from changelog: highlight features users will notice
and any breaking changes that landed in the bump>

Adaptations:
- <file>: <one-line description of each adaptation>
- ...

Assisted-By: Claude <noreply@anthropic.com>
```

Run:

```bash
cd <repo-root>
git add $PKG_DIR
# Include sibling files generated by Phase 6 Step 4:
git add packages/system/<name>-rd/  # only if it changed
git commit --signoff
```

Do **not** pass `--message` directly when the commit body is multi-line — write it to a temp file and use `git commit --signoff --file <path>` so the body lands verbatim.

GPG signing:
- Respect `commit.gpgsign`. Never use `--no-gpg-sign`. Never use `-c commit.gpgsign=false`.
- If GPG signing fails with "Bad PIN", retry the same command **once** — the user often dismisses the first prompt reflexively. Do not retry beyond two attempts; stop and surface the failure for the user to handle.

Do **not** push, do **not** open a PR. Tell the user the commit landed locally and the next step is theirs.

## Phase 9 — Optional dev-cluster deploy

This phase exists because local `helm template` + `helm lint` only catch syntactic and shallow semantic issues. Real bumps surface their problems on a running cluster — admission webhooks reject CRD changes, init-jobs fail on schema migrations, sidecars get OOMKilled, defaults change in ways that affect a populated workload. Deploy as part of the bump, not as a separate task.

Skip this phase entirely when `--no-deploy` was passed or the user declined Phase 5's preview.

### Step 1 — Confirm deploy intent

Ask via `AskUserQuestion`:

> Deploy this bump to a real cluster for verification? Current kubectl context: `$KUBE_CONTEXT`. (Recommended — exercises the change end-to-end and surfaces issues local checks won't catch.)
>
> Options: `yes` / `no` / `dry-run` (print every command without executing) / `pick-context` (choose a different context first).

If the user picks a different context, switch via `kubectl config use-context <name>` and re-record `$KUBE_CONTEXT`.

### Step 2 — Refuse production contexts

If `$KUBE_CONTEXT` matches `prod`, `production`, or has a recognizable production marker (substring match, case-insensitive), refuse and require an explicit `--allow-prod` style override re-typed by the user (one-shot prompt, do not store). Production rollouts of a freshly-bumped chart bypass this skill entirely — they go through the normal cozystack release process.

### Step 3 — Resolve release name and namespace

Cozystack packages export `NAME` and `NAMESPACE` from their own Makefile (per `hack/package.mk` convention: `NAME=$PKG_NAME`, `NAMESPACE=cozy-$NAME`). Read them from the package Makefile rather than reconstructing:

```bash
RELEASE=$(make --directory $PKG_DIR --no-print-directory --eval='print-name: ; @echo $(NAME)' print-name)
NAMESPACE=$(make --directory $PKG_DIR --no-print-directory --eval='print-ns: ; @echo $(NAMESPACE)' print-ns)
```

Show the resolved `$RELEASE` and `$NAMESPACE` to the user. Refuse to proceed if either resolves empty — that means the package's Makefile diverges from convention and needs human attention.

### Step 4 — Detect HelmRelease shape

```bash
kubectl --context $KUBE_CONTEXT --namespace $NAMESPACE get helmrelease $RELEASE \
  --output jsonpath='{.spec.chartRef.kind}{"\t"}{.spec.suspend}{"\n"}'
```

Three outcomes:

- **HelmChart** (or empty `chartRef.kind` with inline `chart`): the release reads its chart from the cozystack source tree. Local `make apply` will apply the bumped chart. Go to Step 5A.
- **ExternalArtifact**: the release reads from a Flux-built artifact pushed to the cluster — local `values.yaml` changes are ignored by Flux. Go to Step 5B.
- **NotFound**: the release has not been installed yet on this cluster. Ask the user whether to install fresh (`make apply`) or pick a different context. If install fresh, treat as the HelmChart path.

### Step 5A — Inline chart deploy

```bash
make --directory $PKG_DIR apply NAMESPACE=$NAMESPACE NAME=$RELEASE
```

The `apply` target in `hack/package.mk` is `apply: check suspend` followed by `cozyhr apply -n $(NAMESPACE) $(NAME)`. So suspend is automatic — no need to call `cozyhr suspend` separately for this path.

If the package has a `make image` target AND the bump pattern is B (in-repo image build), build and push the image first, then run `make apply`:

```bash
# Generate ephemeral registry once per cozy-bump session
if [ -z "$REGISTRY" ]; then
  UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  REGISTRY="ttl.sh/$UUID"
  echo "Using ephemeral registry: $REGISTRY (24h TTL — image will expire)"
fi
TAG="bump-$TARGET_VERSION-$(date --utc +%Y%m%d-%H%M%S)"

REGISTRY=$REGISTRY TAG=$TAG PLATFORM=linux/amd64 PUSH=1 \
  make --directory $PKG_DIR image
# image target writes the resulting digest into $PKG_DIR/values.yaml via yq --inplace.

make --directory $PKG_DIR apply NAMESPACE=$NAMESPACE NAME=$RELEASE
```

Note that the `make image` target rewrites `values.yaml` with the new `ttl.sh/...` digest. That edit is **transient** — Phase 9 Step 7 will offer to revert it, since shipping a `ttl.sh` reference in a commit would expire after 24h.

### Step 5B — ExternalArtifact deploy

Local `values.yaml` is ignored by Flux for this release. Two cases:

- **Image-only bump (Pattern B)**: suspend Flux, then `kubectl set image`:
  ```bash
  cozyhr --context $KUBE_CONTEXT suspend --namespace $NAMESPACE $RELEASE
  kubectl --context $KUBE_CONTEXT --namespace $NAMESPACE set image \
    deployment/<deploy-name> <container>=<full-image-with-digest>
  ```
  The `<deploy-name>` and `<container>` come from `kubectl --context $KUBE_CONTEXT --namespace $NAMESPACE get deployment --output name` plus a `-o jsonpath` on `.spec.template.spec.containers[].name` — surface the candidates and let the user pick if more than one matches.
- **Chart-structure bump (Pattern A or any template/values change)**: stop. The bumped chart needs to land in the source-of-truth repo (`cozystack-system` GitRepository, typically) before Flux will see it. Tell the user:
  > This release is backed by an ExternalArtifact. Local `values.yaml` changes won't reach the cluster. To verify on a dev cluster, push the bump branch to your fork, point the cluster's GitRepository at the fork temporarily, and let Flux reconcile. Alternatively, replicate the change as a temporary inline `HelmRelease` overlay — out of scope for `cozy-bump`.

### Step 6 — Watch rollout

```bash
kubectl --context $KUBE_CONTEXT --namespace $NAMESPACE rollout status \
  deployment/<deploy> --timeout=5m
```

Repeat for each Deployment / StatefulSet that the package owns (enumerate via `kubectl get deploy,sts --output name`). On failure, stream pod logs:

```bash
kubectl --context $KUBE_CONTEXT --namespace $NAMESPACE logs \
  --selector app.kubernetes.io/instance=$RELEASE --tail=200 --all-containers
```

Surface errors verbatim. Do not auto-recover.

### Step 7 — Hand off and resume policy

Print a hand-off message:

```text
Bump applied to $NAMESPACE on $KUBE_CONTEXT.
Suggested smoke checks for $PKG_NAME:
  - <package-specific check 1>  (e.g., create a CR via the ApplicationDefinition)
  - <package-specific check 2>  (e.g., verify the operator's Secret materialized)
  - <package-specific check 3>  (e.g., kubectl exec into the workload and run a basic op)
```

Tailor the suggestions to the package — for `apps/postgres` suggest a `Postgres` CR creation; for `system/cilium` suggest a node-level connectivity check; etc. Use the package's README and templates as the source for what's realistic to check.

Then ask via `AskUserQuestion`:

> Flux is currently suspended for `$RELEASE`. What now?
>
> - `resume` — `cozyhr resume` to commit to the bump on this cluster
> - `keep-suspended` — leave Flux off so you can iterate (re-run `make apply`, `make image`)
> - `revert` — restore previous values.yaml (`git checkout -- $PKG_DIR/values.yaml`) and `cozyhr resume` to roll back

If `revert` was picked AND Pattern B Step 5A re-wrote `values.yaml` with a `ttl.sh` digest, the `git checkout` undoes that automatically. Confirm with `git status` before running `cozyhr resume`.

### Dry-run mode

If the user picked `dry-run` in Step 1, print every command that Steps 3–6 would run, with all variables expanded, but **do not execute** any of them. Tell the user how to re-invoke without `--dry-run`.

## Phase 10 — Summary

Print:

```text
cozy-bump complete

Package:        $PKG_TYPE/$PKG_NAME
Bump:           $CURRENT_VERSION → $TARGET_VERSION
Pattern:        $BUMP_PATTERN
Files changed:  <list>
Commit:         <hash> chore(packages/$PKG_TYPE/$PKG_NAME): bump to $TARGET_VERSION
Deploy:         skipped | dry-run | running on $KUBE_CONTEXT | failed | reverted

Next steps:
  - Push:     git push origin feat/bump-$PKG_NAME-$TARGET_VERSION
  - Open PR:  gh pr create --draft --base main
  - Resume Flux on dev cluster (if still suspended): cozyhr --context $KUBE_CONTEXT resume --namespace $NAMESPACE $RELEASE
```

If anything earlier failed and was not recovered, the summary should reflect that — do not paper over partial state.

## Guardrails

- **Never** modify `Chart.yaml.version` — it is the `0.0.0` placeholder set at build time. Only `appVersion` changes during a bump.
- **Never** push or open the PR. The Phase 8 commit is the skill's last write to git; everything beyond it is the user's call.
- **Never** disable GPG signing, never use `--no-gpg-sign`, never override `commit.gpgsign`. If signing fails, retry once for PIN-prompt timing; beyond that, stop.
- **Never** run `kubectl apply` or `helm install` directly against a managed package — go through `cozyhr apply` / `make apply` so GitOps semantics are respected.
- **Never** silently auto-recover from a missing changelog source — stop and ask. Bumping without changelog evidence is exactly the failure mode this skill exists to prevent.
- **Never** assume the cluster context is dev — confirm explicitly. Refuse names matching `prod*`/`production*` without a one-shot user override.
- **Never** guess upstream versions, image digests, or release tags — if registry/`gh release`/`helm show` fails, stop and ask.
- **Never** apply Phase 6 adaptations without showing them in the Phase 5 plan first — the plan gate is the user's only chance to catch a misread changelog.
- **Never** ship a `ttl.sh/...` reference in a commit. The Phase 9 image build edits `values.yaml` transiently for testing only; revert before commit.
- **Always** run Phase 7 (`helm template` + `helm lint`) before Phase 8 (commit), regardless of how confident the changelog scan was.
- **Always** treat ExternalArtifact-shaped releases differently from inline chart releases — local `values.yaml` is ignored by Flux for the former. Stop and explain rather than pretending the deploy happened.
- For Pattern C (postgres-style enums), the bump is the `hack/update-versions.sh` output — do not hand-edit `files/versions.yaml` after running the script unless the user explicitly asks.

## References

Read these on demand when reasoning about behavior. Quote line ranges; structure may change between cozystack versions.

- `cozystack/cozystack/hack/package.mk` — `apply: check suspend` then `cozyhr apply -n $(NAMESPACE) $(NAME)`. The `apply` target already suspends.
- `cozystack/cozystack/hack/common-envs.mk` — defaults for `REGISTRY` (`ghcr.io/cozystack/cozystack`), `TAG` (`git describe --tags`), `PUSH` (`1`), `BUILDX_ARGS` assembly.
- `cozystack/cozyhr/` — `cozyhr suspend|resume|apply|diff|show -n NAMESPACE NAME [--context CTX] [--kubeconfig PATH]`. `suspend` toggles `spec.suspend: true` on the HelmRelease via merge-patch with Flux field ownership.
- `cozystack/ccp/skills/cozy-deploy/skills/cozy-deploy/SKILL.md` — the established cozystack pattern for `ttl.sh` ephemeral registries (UUID-based, 24h TTL), HelmRelease shape detection, and `kubectl set image` fallback for ExternalArtifact releases. `cozy-bump` Phase 9 borrows from it directly.
- `cozystack/cozystack/packages/apps/postgres/hack/update-versions.sh` — reference for Pattern C enum updaters.
- `cozystack/cozystack/packages/system/backup-controller/Makefile` — reference for Pattern B image-build targets that write digests back into `values.yaml` via `yq --inplace`.
- Conventional Commits: https://www.conventionalcommits.org/
- Flux HelmRelease spec (suspend, chartRef): https://fluxcd.io/flux/components/helm/helmreleases/
- ttl.sh ephemeral registry: https://ttl.sh/
