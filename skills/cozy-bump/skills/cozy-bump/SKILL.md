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

- Positional `<package-path-or-name>` — required. Either an absolute path, a path relative to the monorepo root (`packages/apps/postgres`), or a bare name (`postgres`) resolved against `packages/{apps,system,extra,core}/<name>/`. If multiple matches are found across types, ask the user via `AskUserQuestion` which one. `packages/library/` and `packages/tests/` are explicitly **out of scope** — those are internal helpers without an upstream version to track. If a bare-name match falls only into one of those, stop and explain.
- `--target-version=<ver>` — explicit target (`16.4`, `v1.25.0`, `2.7.5`). If omitted, Phase 3 resolves the latest from upstream and asks the user to confirm.
- `--no-deploy` — skip Phase 9 entirely (no prompt, no deploy).
- `--registry=ttl.sh/<uuid>` — reuse an existing `ttl.sh` registry from a previous run (so a rebuild lands on the same image path). If omitted, Phase 9 generates a fresh UUID.
- `--allow-dirty` — let Phase 2 proceed when the working tree has uncommitted changes. Default is to refuse.

Record `$PKG_DIR` (absolute), `$PKG_NAME` (basename), `$PKG_TYPE` (`apps`/`system`/`extra`/`core`), `$TARGET_VERSION` (may be empty until Phase 3), `$ALLOW_DIRTY`, `$NO_DEPLOY`, `$REGISTRY` (may be empty).

If `<package-path-or-name>` is missing, ask via `AskUserQuestion` — do not invent a default.

## Phase 2 — Pre-flight checks

Bail early if any check fails.

1. **Monorepo location**: verify the resolved `$PKG_DIR` lives under a clone whose root contains `hack/package.mk` and `hack/common-envs.mk`. If not, tell the user to `cd` into a cozystack monorepo checkout or set `$COZYSTACK_REPO`. Stop. Record `$REPO_ROOT=$(git -C "$PKG_DIR" rev-parse --show-toplevel)` for use by Phase 7 and Phase 8.
2. **Package shape**: verify `$PKG_DIR/Chart.yaml` exists. Most in-scope packages carry `Chart.yaml.version: 0.0.0` as a build-time placeholder, but **not all** — known exceptions at time of writing include `apps/foundationdb` (`0.1.0`), `system/cozystack-scheduler` (`0.3.0`), `system/kubeovn` (`0.38.0`). Treat a non-`0.0.0` version as a warning (note that the bump must not touch `version`, only `appVersion`), not a stop. Verify `$PKG_DIR/Makefile` exists and includes `hack/package.mk` (grep for `include .*package.mk`).
3. **Working tree**: run `git -C "$REPO_ROOT" status --porcelain --untracked-files=no`. If output is non-empty and `$ALLOW_DIRTY` is unset, print a one-line summary and stop. Recommend `git stash` or `--allow-dirty`.
4. **Tools installed**: check that `yq` (v4 mikefarah), `jq`, `helm`, `docker buildx`, `cozyhr`, `cozyvalues-gen`, `kubectl`, `git`, `gh` are on `PATH` via `command -v`. Missing required tools → print install hints (link to each project's releases page) and stop. `gh` is required only for changelog scraping — if missing, warn and fall back to raw `curl` against the GitHub REST API in Phase 4. Note: every shell snippet in this skill is portable across macOS (BSD coreutils, GNU Make 3.81 default) and Linux (GNU coreutils). If you find yourself reaching for `make --eval`, `date --utc`, `date -u`, or any GNU-only flag, stop and rewrite using a portable form (e.g. `TZ=UTC date +...`, `make --makefile=- <<MK ... MK`).
5. **GPG signing**: read `git -C "$REPO_ROOT" config commit.gpgsign`. If `true`, note that the Phase 8 commit will prompt for a YubiKey/PIN — surface this upfront so the user knows to be available.
6. **Cluster context** is **not** read here. The current-context can change between Phase 2 and Phase 9 (another shell, another `cozy-deploy` invocation, anything). Phase 9 Step 1 reads it freshly right before the deploy gate, so the read and the use are adjacent. Phase 2's only job is to confirm `kubectl` is on `PATH` (already covered by step 4).

State `$PKG_DIR`, `$PKG_NAME`, `$PKG_TYPE`, working-tree status, and tool availability back to the user, then proceed.

## Phase 3 — Detect upstream and current version

Cozystack packages follow three distinct upstream patterns. Detect which one applies, then resolve the current and target versions.

### Pattern A — Vendored upstream Helm chart

Indicator: `$PKG_DIR/charts/<name>/Chart.yaml` exists. This is **the** signal — cozystack vendors via `helm pull --untar` into `charts/`, not via `Chart.yaml.dependencies`. The one package with a `dependencies:` block today (`apps/qdrant`) points at the in-tree `cozy-lib` library via `repository: file://charts/cozy-lib`, which is **not** an upstream-vendor case — ignore that pattern.

Resolve:
- **Current version**: `yq '.version' "$PKG_DIR/charts/<name>/Chart.yaml"`. If multiple sub-charts exist (e.g. an operator chart plus a CRD chart), ask the user which one this bump targets.
- **Helm repo registration** (run unconditionally — Phase 4 Step 2 depends on this):
  ```bash
  helm repo add --force-update <repo-name> <repo-url>
  ```
  For OCI repos there is no `helm repo add` equivalent; the OCI `oci://...` URL is passed directly to `helm show`/`helm pull`.
- **Target version**: if `$TARGET_VERSION` is set on the CLI, use it. Otherwise:
  ```bash
  helm search repo <repo-name>/<chart-name> --versions --output json | jq --raw-output '.[0].version'
  ```
  For OCI repos: `helm show chart oci://<repo>/<chart> --version <semver-range>`. Present the discovered latest to the user via `AskUserQuestion` and let them confirm or override.
- Source-of-truth for changelog: the upstream project's GitHub repo. Derive the `<owner>/<name>` in this order, taking the first that yields a `https://github.com/<owner>/<name>` URL:
  1. `Chart.yaml.dependencies[].repository` if it points at `https://github.com/<owner>/<name>` (some Helm repos are GitHub Pages off the project repo).
  2. `helm show chart` `sources[]` entries — pick the first matching `https://github.com/<owner>/<name>(/.*)?`.
  3. `helm show chart` `home:` field, but **only** when it matches `https://github.com/...`. Many charts list `home:` as a project landing site (e.g. `home: https://cloudnative-pg.io` for cloudnative-pg) — those are not usable as a `gh` target.
  4. None of the above → stop and ask the user for the upstream GitHub repo. Do not guess.

### Pattern B — In-repo image build

Indicators:
- `$PKG_DIR/Makefile` defines an `image:` target (grep for `^image:` at column 0). Cozystack convention is the top-level `image:` target delegates to one or more `image-<name>:` sub-targets that drive `docker buildx build`.
- `$PKG_DIR/values.yaml` carries the image reference inline, written by the build via `yq --inplace '.<key>.image = strenv(IMAGE)' values.yaml`.

Resolve:
- **Current version**: parse the existing image ref from `values.yaml` — `yq '.<key>.image' values.yaml` (mikefarah `yq` v4 returns scalars unwrapped by default, no flag needed). The tag portion (between `:` and `@sha256:`) is the current version.
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
GH_LIMIT=200
gh release list --repo $UPSTREAM_OWNER/$UPSTREAM_REPO_NAME --limit "$GH_LIMIT" \
  --json tagName,name,publishedAt > /tmp/cozy-bump-releases.json
COUNT=$(jq --raw-output 'length' /tmp/cozy-bump-releases.json)
if [ "$COUNT" -ge "$GH_LIMIT" ]; then
  # COUNT == GH_LIMIT means we hit the cap (could be exactly that many releases,
  # could be more). Confirm by fetching the page beyond the cap — page number is
  # 1-based, per_page=1 means page=N returns the N-th release.
  EXTRA=$(gh api "repos/$UPSTREAM_OWNER/$UPSTREAM_REPO_NAME/releases?per_page=1&page=$((GH_LIMIT + 1))" --jq 'length')
  if [ "$EXTRA" -gt 0 ]; then
    echo "WARNING: gh release list returned $COUNT == --limit and more pages exist."
    echo "Increase GH_LIMIT or paginate via 'gh api repos/.../releases?page=N' if the bump"
    echo "spans more tags than fit in one page."
  fi
fi
```

Filter to tags whose semver lies strictly between `$CURRENT_VERSION` (exclusive) and `$TARGET_VERSION` (inclusive). Tag prefixes vary — accept both `v1.2.3` and `1.2.3`; normalize via real semver semantics, not lexicographic string compare. Concrete tools, in order of preference:

1. `helm` itself: `helm install --version <range>` and `helm search repo --versions` already accept semver constraints — reuse them when the goal is "is this version between X and Y" rather than ordering a list.
2. The standalone `semver` CLI (npm package, `brew install semver`): `semver --range ">$CURRENT_VERSION <=$TARGET_VERSION" "$tag"`.
3. As a last resort, a small bash helper that strips a leading `v` and compares with `sort --version-sort` (`printf '%s\n%s\n' "$a" "$b" | sort --version-sort | head -1`). Note `sort --version-sort` is GNU-only — on macOS use `gsort` from coreutils.

For Pattern C bumps that span many minor releases (postgres-style), 200 may not be enough — paginate via `gh api` and concatenate the pages before filtering.

For each tag in the window:

```bash
gh release view <tag> --repo $UPSTREAM_OWNER/$UPSTREAM_REPO_NAME \
  --json tagName,name,body > /tmp/cozy-bump-release-<tag>.json
```

Concatenate the `body` fields into `/tmp/cozy-bump-changelog.md` with `## <tag>` headers between sections.

If `gh release list` returns nothing for a project that uses tag-only releases (no GitHub Release objects), fall back to `git ls-remote --tags https://github.com/$UPSTREAM_OWNER/$UPSTREAM_REPO_NAME` plus reading `CHANGELOG.md` from the repo at each tag. If that also fails (sparse releases, no CHANGELOG), stop and ask the user where the changelog lives — never proceed without changelog evidence.

### Step 2 — Helm values diff (Pattern A only)

Phase 3 already registered the upstream Helm repo unconditionally — this step can call `helm show values` directly.

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

Scan `/tmp/cozy-bump-changelog.md` for these patterns (case-sensitive where indicated):

- Case-insensitive substring: `breaking change`, `breaking:`, `deprecat`, `removed`, `renamed`, `migration`, `action required`, `incompatible`, `no longer supported`.
- Case-sensitive: `BREAKING`, `MUST` / `MUST NOT` / `MUST be` (RFC 2119 conformance language). Lowercase `must` matches almost every changelog and drowns the signal — don't grep on it.

For each hit, capture the surrounding bullet/paragraph plus the tag it came from.

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

Phase 9 (deploy):  preview only — Phase 9 has its own confirmation gate
Commit:            chore(packages/$PKG_TYPE/$PKG_NAME): bump to $TARGET_VERSION
                   (signed off, GPG-signed if commit.gpgsign=true)
```

Three options: `approve` / `edit <phase>` / `abort`.

- `approve` → set `$PLAN_APPROVED = true`. Phases 6–8 proceed without further per-step prompts. Phase 9 still has its own gate.
- `edit <phase>` → return to the named phase and re-collect input.
- `abort` → stop. No files changed.

**Pattern B + `--no-deploy` interlock**: when `$BUMP_PATTERN = B` and `$NO_DEPLOY` is set, the plan gate must prompt explicitly for which Pattern B path (see Phase 6 Step 5) the user is taking — `local-build` (path 2, requires push credentials), `maintainer-handoff` (path 3, abort the commit), or `re-enable-deploy` (drop `--no-deploy`). Without an answer, refuse to proceed past Phase 5 — silently committing only `Chart.yaml.appVersion` while `values.yaml` retains the old digest is the failure mode this interlock prevents.

**ExternalArtifact reality check (warn before approve)**: the cozystack platform operator creates **every** managed `HelmRelease` with `spec.chartRef.kind: ExternalArtifact` (verified against `cozystack/internal/operator/package_reconciler.go`). On any real cozystack cluster (anything past bootstrap), Flux pulls the chart from the platform-built artifact, not from your local checkout. This means:

- **Pattern A chart-structure bumps**: Phase 9's local `make apply` cannot verify them on a real cluster. The chart must land in the platform's source-of-truth GitRepository and be rebuilt by the operator before Flux sees it. Phase 9 will detect this and explain the push-to-fork workflow rather than pretend to deploy.
- **Pattern B image-only bumps**: Phase 9 can verify by suspending Flux and running `kubectl set image` (the local `values.yaml` digest is irrelevant to Flux; what runs in the pod is what matters).

Surface this in the plan summary so the user knows whether Phase 9 will actually exercise their bump or whether it can only verify the image swap (Pattern B) / nothing (Pattern A on ExternalArtifact). The skill does not refuse — many bumps are correct after Phase 7 alone — but the user should approve Phase 5 with an honest expectation.

Without this gate, the user only sees the bump as files start landing on disk. Always run it.

## Phase 6 — Apply bumps

Skip per-step confirmations when `$PLAN_APPROVED` is true; still confirm on file collisions or unexpected diffs.

### Step 1 — `Chart.yaml.appVersion`

```bash
yq --inplace '.appVersion = strenv(TARGET_VERSION)' "$PKG_DIR/Chart.yaml"
```

Never touch `Chart.yaml.version` — it is the build-time placeholder `0.0.0`.

### Step 2 — Pull vendored chart updates (Pattern A)

The package's `make update` target (when present) hardcodes the upstream version inside the recipe — it is **not** parameterized by the environment. Examples in the current monorepo: `system/cilium/Makefile` pins `--version 1.19`, `system/kafka-operator/Makefile` pins `--version 0.45.1-rc1`, `system/opensearch-operator` and `system/postgres-operator` likewise. Calling `make update` blindly would re-fetch the **previous** version, leave `Chart.yaml.appVersion` correctly bumped from Step 1, but ship a `charts/<name>/` still at the old version. Phase 7 would pass against unchanged templates and Phase 8 would commit a lying bump.

Path:

1. Read `$PKG_DIR/Makefile` — find the line matching `helm pull .* --version <X>`.
2. If a `--version <X>` is hardcoded, edit that line to `--version $TARGET_VERSION` via `sed --in-place` (or a targeted Edit). Surface the diff to the user before continuing.
3. Run `make --directory $PKG_DIR update`. The target's pre-clean (`rm -rf charts/`) is preserved by editing the version literal only.
4. If the Makefile has no `update` target, replicate the convention manually — the pre-clean step is non-negotiable:

   ```bash
   rm -rf "$PKG_DIR/charts"/*
   helm pull <repo-name>/<chart-name> --version $TARGET_VERSION \
     --untar --untardir "$PKG_DIR/charts"
   ```

5. **Self-check** (mandatory invariant): after the pull, verify

   ```bash
   [ "$(yq '.version' "$PKG_DIR/charts/<name>/Chart.yaml")" = "$TARGET_VERSION" ] \
     || { echo "Pulled chart version does not match target — stopping"; exit 1; }
   ```

   If the result diverges from `$TARGET_VERSION`, stop and surface the actual pulled version. Do not proceed to Phase 7. If multiple sub-chart directories remain in `charts/`, stop — pre-clean failed.

### Step 3 — Apply the adaptation list

For each adaptation entry from Phase 4 Step 5:

- **`rename` / `update`**: edit the named file via `yq --inplace` (for YAML) or a single targeted Edit (for templates with Helm template syntax). Preserve surrounding indentation, preserve comments.
- **`remove`**: confirm with the user before deleting (one prompt, listing all `remove` actions in a single batch).
- **`add`**: insert the new key/value into `values.yaml`. Use the upstream chart's default as the value, with a comment line above pointing to the changelog evidence.
- **`review`**: do not auto-apply. Surface to the user with the evidence and let them decide.

After every batch, re-run the relevant grep from Phase 4 Step 4 to confirm no straggler references remain.

### Step 4 — Regenerate schema and ApplicationDefinition (when applicable)

The `generate:` target is **not** universal — at time of writing it is defined in 30 of 159 package Makefiles, split as 22 under `packages/apps/*`, 7 under `packages/extra/*`, and 1 under `packages/library/*` (verify with `find packages -name Makefile -exec grep --files-with-matches '^generate:' {} \;` against the user's checkout). For `packages/system/*` and `packages/core/*` packages this target typically does not exist, and most of those packages have no `values.schema.json` either (they are platform-managed, not exposed as CRDs).

Path:

1. Check whether the target exists by grepping the package Makefile for `^generate:` (more reliable than `make --question` for non-PHONY targets — `--question` returns 0/1/2 based on prerequisite freshness, not target presence, and the cozystack `generate:` recipes are not declared `.PHONY`).
2. If `^generate:` is present: `make --directory $PKG_DIR generate`. This rebuilds `values.schema.json` and writes the corresponding ApplicationDefinition under `packages/system/$(yq '.name' $PKG_DIR/Chart.yaml)-rd/cozyrds/`.
3. If absent: skip silently. Do not warn about a missing schema for `system/*`/`core/*` packages.

### Step 5 — Image-build packages (Pattern B)

For Pattern B, the bump is **not complete** until a fresh image is built and the resulting digest lands in `values.yaml`. There is no CI workflow in the cozystack monorepo that rebuilds and rewrites per-package `values.yaml` at tag time (verify by reading `.github/workflows/` in the cozystack checkout — if that changes, update this section). So a Pattern B commit that bumps `Chart.yaml.appVersion` while leaving the **old** image digest in `values.yaml` is internally inconsistent and ships a broken state.

Three valid paths through this step:

1. **Going to deploy in Phase 9 (default)**: defer the build to the ExternalArtifact + Pattern B sub-path of Phase 9 Step 5 (or the inline-chart path when applicable). Phase 9 builds against the cozystack publish registry (or `ttl.sh` for ephemeral testing — but `ttl.sh` digests must be reverted before Phase 8 commit; see Phase 9 Step 7).
2. **Not deploying, but want a real image bump in this commit**: build right now against the cozystack publish registry:
   ```bash
   # WILL FAIL WITH 403 unless you have push access to ghcr.io/cozystack/cozystack.
   # Only cozystack maintainers have this — for everyone else, take path 3.
   REGISTRY=ghcr.io/cozystack/cozystack TAG=$TARGET_VERSION PLATFORM=linux/amd64 PUSH=1 \
     make --directory $PKG_DIR image
   ```
   The `image` target writes the resulting `<reg>:<tag>@sha256:<digest>` into `values.yaml` via `yq --inplace`.
3. **Not deploying, no push credentials**: this skill cannot complete a Pattern B bump. Stop and tell the user — the bump must go to a maintainer who can push, or be promoted to a deploy + ttl.sh roundtrip + revert flow.

Phase 5's plan gate must surface which path is in use; the gate refuses to proceed past Phase 5 with `--no-deploy` unless the user has confirmed path 2 or path 3.

## Phase 7 — Local verification

Hard gates. If any fails, **stop and report**, do not commit, do not deploy.

```bash
helm template $PKG_DIR --output-dir /tmp/cozy-bump-template-out
helm lint $PKG_DIR
git -C "$REPO_ROOT" diff --stat $PKG_DIR
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

The `Assisted-By: Claude` trailer is mandatory per the cozystack project commit standard (CLAUDE.md: "ALL commits MUST use git commit --signoff" and Claude attribution via this trailer line). Do not strip it.

Run:

```bash
COMMIT_MSG=$(mktemp -t cozy-bump-msg.XXXXXX)
trap 'rm -f "$COMMIT_MSG"' EXIT
cat > "$COMMIT_MSG" <<EOF
chore(packages/$PKG_TYPE/$PKG_NAME): bump $PKG_NAME to $TARGET_VERSION

<changelog summary>

Adaptations:
- ...

Assisted-By: Claude <noreply@anthropic.com>
EOF

git -C "$REPO_ROOT" add "$PKG_DIR"
# Phase 6 Step 4's `make generate` may have emitted into packages/system/<chart-name>-rd/.
# The -rd/ directory is named after the *Chart.yaml chart name*, NOT the package
# directory basename. They diverge — e.g. apps/vpc has Chart.yaml.name =
# virtualprivatecloud, so update-crd.sh writes to system/virtualprivatecloud-rd/.
# Read the chart name and stage that exact path:
CHART_NAME=$(yq '.name' "$PKG_DIR/Chart.yaml")
RD_DIR="$REPO_ROOT/packages/system/${CHART_NAME}-rd"
if [ -d "$RD_DIR" ]; then
  git -C "$REPO_ROOT" add "$RD_DIR"
fi

git -C "$REPO_ROOT" commit --signoff --file "$COMMIT_MSG"
```

**Self-check after staging** (mandatory invariant): for any package that has a `generate:` target, `git diff --cached --stat` must list at least one file under `packages/system/${CHART_NAME}-rd/` — otherwise the ApplicationDefinition is out of sync with the bumped `appVersion` and the commit is a "lying bump". Stop and ask the user.

Why a tempfile rather than `--message`: multi-line bodies via `--message "<<EOF…EOF"` are fragile under shell escaping (backticks, dollar signs, single quotes). The tempfile approach lets the body land verbatim and is cleaned up by the `trap` regardless of exit path.

Why `git -C "$REPO_ROOT"` instead of `cd <repo-root>`: portable across BSD/GNU shells, no implicit working-directory side effects on the caller. `git -C` is the canonical short form — the long form `--directory` does not exist for `git`. Do not try to "fix" this to a long flag.

Why `Chart.yaml.name` and not `$PKG_NAME` for the `-rd/` path: the cozystack `hack/update-crd.sh` script reads the chart name from `Chart.yaml` (not the directory). For most packages they coincide, but `apps/vpc` (chart `virtualprivatecloud`) breaks the assumption. Using `$PKG_NAME` would silently miss the regenerated ApplicationDefinition and ship a desynchronised commit.

GPG signing:
- Respect `commit.gpgsign`. Never use `--no-gpg-sign`. Never use `-c commit.gpgsign=false`.
- If GPG signing fails with "Bad PIN", retry the same command **once** — the user often dismisses the first prompt reflexively. Do not retry beyond two attempts; stop and surface the failure for the user to handle.

Do **not** push, do **not** open a PR. Tell the user the commit landed locally and the next step is theirs.

## Phase 9 — Optional dev-cluster deploy

This phase exists because local `helm template` + `helm lint` only catch syntactic and shallow semantic issues. Real bumps surface their problems on a running cluster — admission webhooks reject CRD changes, init-jobs fail on schema migrations, sidecars get OOMKilled, defaults change in ways that affect a populated workload. Deploy as part of the bump, not as a separate task.

Skip this phase entirely when `--no-deploy` was passed or the user declined Phase 5's preview.

### Step 1 — Confirm deploy intent

Read the current kubectl context **freshly** here (not from any earlier-recorded value) so the gate matches the actual cluster the user is on:

```bash
KUBE_CONTEXT=$(kubectl config current-context)
```

Caveat: if the user has `KUBECONFIG` exporting multiple files, "current" resolves to whichever file the merge strategy lands on first — that may not match their mental model. The Step 1 `AskUserQuestion` (with `pick-context` as one of the options) is the safety net; if the user picks a different name, take that one as authoritative for the rest of Phase 9.

Then ask via `AskUserQuestion`:

> Deploy this bump to a real cluster for verification? Current kubectl context: `$KUBE_CONTEXT`.
>
> What Phase 9 can actually verify on a real cozystack cluster (where every HelmRelease is `chartRef.kind: ExternalArtifact`):
> - **Pattern B (image-only)**: yes — Phase 9 will rebuild the image, suspend Flux, and `kubectl set image` the running pods.
> - **Pattern A (chart-structure)**: no — Flux ignores local `values.yaml`; the bump must land in the source-of-truth GitRepository first. Phase 9 will explain a push-to-fork workaround instead of pretending to deploy.
> - **Pattern C (postgres-style enum)**: depends on whether the bumped pattern is image-shaped or chart-shaped — the skill will branch accordingly.
>
> Options: `yes` / `no` / `dry-run` (print every command without executing) / `pick-context` (choose a different context first).

If the user picks a different context, record their choice into `$KUBE_CONTEXT` and pass `--context $KUBE_CONTEXT` to every subsequent `kubectl` / `cozyhr` call. **Never** call `kubectl config use-context` — switching the global current-context modifies `~/.kube/config` and creates a race with anything else the user is doing in another terminal. Every command in Phase 9 takes `--context` explicitly; that is the safe contract.

### Step 2 — Refuse production contexts

If `$KUBE_CONTEXT` matches `prod`, `production`, or has a recognizable production marker (substring match, case-insensitive), refuse and require an explicit `--allow-prod` style override re-typed by the user (one-shot prompt, do not store). Production rollouts of a freshly-bumped chart bypass this skill entirely — they go through the normal cozystack release process.

### Step 3 — Resolve release name and namespace

Each cozystack package that is deployed via `cozyhr apply` sets `NAME` and `NAMESPACE` in its own Makefile. The values vary widely — there is **no** mechanical rule like `NAMESPACE=cozy-$(NAME)`. Real examples:

- `system/backup-controller/Makefile` → `NAME=backup-controller`, `NAMESPACE=cozy-backup-controller`
- `system/cozystack-api/Makefile` → `NAMESPACE=cozy-system`
- `system/fluxcd-operator/Makefile` → `NAMESPACE=cozy-fluxcd`
- `system/ingress-nginx/Makefile` → `NAME=ingress-nginx-system`
- `apps/postgres/Makefile` → does **not** set `NAME` / `NAMESPACE` at all (apps under `packages/apps/` are templates for tenant-created CRs, not singleton releases).

Read the values from the package Makefile via a portable helper (works on GNU Make 3.81 / BSD make / modern GNU Make — `--eval` is GNU 3.82+ only and unavailable on stock macOS):

```bash
read_make_var() {
  local pkg_dir="$1" var="$2"
  ( cd "$pkg_dir" && make --no-print-directory --makefile=- "_print_${var}" <<MK
include Makefile
_print_${var}:
	@echo \$(${var})
MK
  )
}
RELEASE=$(read_make_var "$PKG_DIR" NAME)
NAMESPACE=$(read_make_var "$PKG_DIR" NAMESPACE)
```

If either resolves empty, this package is **not** deployable via `cozyhr apply` — typically a templates-only package under `packages/apps/`. Tell the user that Phase 9 is unavailable for this package shape and skip the rest of Phase 9. The bump itself (Phases 6–8) is still valid; the user verifies on a tenant CR via `cozy-deploy` or by hand.

Otherwise, show the resolved `$RELEASE` and `$NAMESPACE` to the user before any cluster call.

### Step 4 — Detect HelmRelease shape

```bash
kubectl --context $KUBE_CONTEXT --namespace $NAMESPACE get helmrelease $RELEASE \
  --output jsonpath='{.spec.chartRef.kind}{"\t"}{.spec.suspend}{"\n"}'
```

Outcomes (in order of frequency on real cozystack clusters):

- **ExternalArtifact** — the rule. The cozystack platform operator creates every managed HelmRelease this way. Go to Step 5 ExternalArtifact branch.
- **HelmChart** / inline `chart` — uncommon. Only happens on bootstrap before the operator reconciled, on a kind cluster used purely for chart-syntax testing, or on a release the user installed by hand. Go to Step 5 inline branch.
- **NotFound** — the release has not been installed yet on this cluster. Ask the user whether to install fresh (`make apply`, treat as inline-chart) or pick a different context.

### Step 5 — Deploy by shape × pattern

#### ExternalArtifact + Pattern B (image-only) — primary path

Flux ignores local `values.yaml`; the chart on the cluster is whatever the platform operator built. But the running pods can be reimaged directly:

```bash
cozyhr --context $KUBE_CONTEXT suspend --namespace $NAMESPACE $RELEASE

# Generate an ephemeral registry once per cozy-bump session (24h TTL).
if [ -z "$REGISTRY" ]; then
  UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  REGISTRY="ttl.sh/$UUID"
  echo "Using ephemeral registry: $REGISTRY (24h TTL — image will expire)"
fi
TAG="bump-$TARGET_VERSION-$(TZ=UTC date +%Y%m%d-%H%M%S)"  # TZ=UTC over --utc/-u for BSD+GNU portability

REGISTRY=$REGISTRY TAG=$TAG PLATFORM=linux/amd64 PUSH=1 \
  make --directory $PKG_DIR image
# The image target writes <reg>:<tag>@sha256:<digest> back into $PKG_DIR/values.yaml.

# Read the digest the build just wrote, then patch the live workload(s):
NEW_IMAGE=$(yq '.<key>.image' "$PKG_DIR/values.yaml")
# enumerate workloads owned by the release (see selector derivation in Step 6)
kubectl --context $KUBE_CONTEXT --namespace $NAMESPACE set image \
  <kind>/<name> <container>="$NEW_IMAGE"
```

The `make image` rewrite of `values.yaml` is **transient** — Step 7 will revert it before the Phase 8 commit. Shipping a `ttl.sh/...` reference in a commit would expire in 24h.

#### ExternalArtifact + Pattern A (chart-structure) — push-to-fork handoff

Phase 9 cannot deploy chart-structure changes on this cluster. Stop and explain:

> This release is backed by an ExternalArtifact. Flux reconciles the chart from the cozystack platform's source-of-truth GitRepository, not from your local checkout. To verify the bump on a real cluster:
>
> 1. Push the bump branch to a fork of cozystack/cozystack you control.
> 2. Edit the cluster's `cozystack-system` GitRepository (or equivalent) `spec.url` and `spec.ref.branch` to point at your fork temporarily.
> 3. Wait for Flux to reconcile, then watch the workloads roll out.
> 4. Once verified, restore the original GitRepository spec and submit the bump as a PR.
>
> Alternatively, replicate the change as a temporary inline `HelmRelease` overlay outside cozy-bump's scope.

Do not attempt either path automatically — both modify shared cluster state.

#### Inline chart (any pattern) — uncommon path

```bash
make --directory $PKG_DIR apply NAMESPACE=$NAMESPACE NAME=$RELEASE
```

The `apply` target in `hack/package.mk` is `apply: check suspend` followed by `cozyhr apply -n $(NAMESPACE) $(NAME)`. So suspend is automatic — no separate `cozyhr suspend` needed.

If Pattern B and the image must rebuild before apply, run the image build first (same `make image` invocation as the ExternalArtifact + Pattern B path above), then `make apply`. The same `ttl.sh` revert applies in Step 7.

### Step 6 — Watch rollout

Enumerate all rollouts the package owns (Deployments AND StatefulSets — for storage-shaped packages like CNPG or monitoring there may be no Deployment at all), then watch each:

```bash
kubectl --context $KUBE_CONTEXT --namespace $NAMESPACE \
  get deployment,statefulset --output name |
while read -r workload; do
  kubectl --context $KUBE_CONTEXT --namespace $NAMESPACE \
    rollout status "$workload" --timeout=5m
done
```

`rollout status` accepts `kind/name` for both Deployment and StatefulSet (and DaemonSet). On failure, stream pod logs by reading the workload's actual selector — Helm 3 does **not** inject standard labels (`app.kubernetes.io/instance` and friends) automatically; only what each chart's templates explicitly set. Many cozystack `system/*` packages set none. Derive the selector from the failing workload itself:

```bash
SELECTOR=$(kubectl --context $KUBE_CONTEXT --namespace $NAMESPACE \
  get "$workload" --output go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' |
  sed 's/,$//')
kubectl --context $KUBE_CONTEXT --namespace $NAMESPACE logs \
  --selector "$SELECTOR" --tail=200 --all-containers
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

Then ask via `AskUserQuestion`. The right wording depends on whether the deploy went through the ExternalArtifact + Pattern B path (`kubectl set image` against an artifact-backed release) or the inline-chart path (`make apply` wrote the chart directly):

**ExternalArtifact + Pattern B path** — what's running on the pod is the `ttl.sh` image you just pushed; what's in the source-of-truth artifact is still the **old** image. So:

> Flux is currently suspended for `$RELEASE`. The pod is running your `ttl.sh` build; the platform's source-of-truth artifact still holds the **old** image. Resuming Flux will reconcile the pod **back to the old image** — your bump never landed in the artifact and is not on this cluster permanently.
>
> - `resume` — release Flux. The platform operator reconciles the workload back to the source-of-truth digest (the **old** image). Use this when verification is done and you want the cluster restored to baseline.
> - `keep-suspended` — leave Flux off so you can iterate (`make image` again, `kubectl set image` again).
> - `revert` — same end state as `resume` (Flux reverts the kubectl set image), plus restore `values.yaml` locally (`git -C "$REPO_ROOT" checkout -- "$PKG_DIR/values.yaml"`) so the `ttl.sh` digest does not accidentally land in the Phase 8 commit.

`resume` and `revert` end at the same cluster state for this path. The difference is whether your local `values.yaml` carries the ephemeral `ttl.sh` digest — `revert` cleans it; `resume` alone does not. **Always** clean local `values.yaml` before Phase 8 commits — the guardrail at the bottom of this SKILL is non-negotiable.

**Inline-chart path** — `make apply` actually installed the bumped chart. So:

> Flux is currently suspended for `$RELEASE`. The bumped chart is installed on this cluster.
>
> - `resume` — `cozyhr resume` to release Flux. Flux will reconcile against the bumped chart you applied; the bump persists on this cluster.
> - `keep-suspended` — leave Flux off so you can iterate (re-run `make apply`).
> - `revert` — `git -C "$REPO_ROOT" checkout -- "$PKG_DIR"` to restore the previous chart, then `make --directory $PKG_DIR apply NAMESPACE=$NAMESPACE NAME=$RELEASE` to install the prior version, then `cozyhr resume`.

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
- **Always** pass `--context $KUBE_CONTEXT` and `--namespace $NAMESPACE` to every `kubectl` and `cozyhr` call in Phase 9 — never rely on the global current-context.
- **Always** use full flag names (`--raw-output`, not `-r`; `--output name`, not `-o name`; `--directory`, not `-C`) per the cozystack project standard. Short flags in prescribed commands train the user to mix conventions.
- **Always** prefer portable shell idioms — `TZ=UTC date +...` over `date --utc`/`date -u`, `make --makefile=- <<MK ... MK` over `make --eval='...'`. The skill must run unchanged on macOS (GNU Make 3.81, BSD coreutils) and Linux.

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
