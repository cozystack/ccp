---
name: cozy-deploy
description: Deploy a Cozystack package to a dev cluster via make + cozyhr. Handles both fresh install and dev-loop iteration — builds a custom image, detects whether the HelmRelease uses ExternalArtifact (in which case local values.yaml is ignored and kubectl set image is required), applies the change, waits for rollout, and offers to resume Flux afterwards. Use when iterating on a PR branch and wanting the change to land on a running cluster for manual verification or a screenshot.
argument-hint: "<package> [--registry=<reg>] [--tag=<tag>] [--context=<ctx>] [--namespace=<ns>] [--release=<name>] [--skip-build] [--no-resume] [--keep-values]"
---

# cozy-deploy

This skill deploys a single Cozystack package (`packages/system/<pkg>` or `packages/apps/<pkg>`) from the current checkout to a Kubernetes cluster, using the repo's own `make` targets and the `cozyhr` wrapper. It is designed for developer iteration against a dev cluster — **do not run it against production**. Touching a real cluster requires explicit confirmation at a gate below.

Work in reasoning mode. Follow the phases in order. Skip steps only when the argument flags explicitly say so. When a step fails, stop and report — do not try to work around by disabling safety checks.

Use the phrasing "`cozy-deploy`" (not "the skill") in messages to the user, and state progress at each phase boundary.

## Phase 1 — Parse arguments

`$ARGUMENTS` contains the free-form tail after `/cozy-deploy`. Extract:

- Positional `<package>` — the directory name under `packages/system/` or `packages/apps/`. Required.
- `--registry=<reg>` — container registry to push to (e.g., `ghcr.io/lexfrei`). If unset, fall back to a private `ttl.sh/<uuid>` path (Phase 4).
- `--tag=<tag>` — image tag. Default: `latest` (since `TAG` in `hack/common-envs.mk` resolves to `latest` outside of a git tag).
- `--context=<ctx>` — `kubectl` context to target. Default: whatever `kubectl config current-context` returns (with confirmation in Phase 3).
- `--namespace=<ns>` — Kubernetes namespace. Default: value of `NAMESPACE` in the package `Makefile`.
- `--release=<name>` — Helm release name. Default: value of `NAME` in the package `Makefile`.
- `--skip-build` — skip `make image`; use whatever image digest is already in `values.yaml`.
- `--no-resume` — after deploy, do not prompt to resume the suspended HelmRelease. Useful for leaving the cluster on the custom build while iterating further.
- `--keep-values` — do not revert `packages/…/values.yaml` at the end. Useful if the user wants to inspect what `make image` wrote.

If `<package>` is missing, use `AskUserQuestion` to pick one. Offer the 4-5 most recently modified `packages/*/*/Makefile` entries as options.

## Phase 2 — Pre-flight checks

Bail early if any check fails — do not try partial workflows.

1. **Repository**: `git rev-parse --show-toplevel` must point at a path containing `hack/common-envs.mk`, `hack/package.mk`, and a `packages/` directory. If not, tell the user to `cd` into the Cozystack checkout and re-run.
2. **`cozyhr` installed**: `command -v cozyhr`. If missing, report the release URL (`https://github.com/cozystack/cozyhr/releases/latest`) and the install pattern (download tarball matching `uname`/`arch`, extract, move to a `$PATH` directory like `~/.local/bin`). Do not install it automatically.
3. **Package directory exists**: resolve `PKG_DIR` in priority order: `packages/system/<pkg>` then `packages/apps/<pkg>` then `packages/extra/<pkg>`. If none exists, list the available packages from `packages/*/` and ask the user.
4. **Extract `NAME` and `NAMESPACE`** from `$PKG_DIR/Makefile` (look for `NAME=` and `NAMESPACE=` lines near the top). Override with the flags if given.
5. **Container / Deployment names** — grep `$PKG_DIR/templates/*.yaml` for Deployment names and per-container `- name:` values under `containers:`. Needed later for Mode B. If the package has no Deployment template (some chart-only packages), note it and skip Mode B steps.
6. **Arm64 + amd64 cross-build prerequisites** (only matters if target cluster nodes are amd64 — check with `kubectl --context <ctx> get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}'` later; if `amd64` and local `uname -m` is `arm64`):
   - `docker buildx ls` — look for a builder advertising both `linux/amd64` and `linux/arm64`. If the default builder only lists one, the user needs a `docker-container` builder.
   - `colima status` — if running but without Rosetta, builds of Go-based images will segfault inside QEMU emulation. Check `~/.colima/default/colima.yaml` for `rosetta: true`.
   - If any of the above is missing, print the exact remediation commands and **stop**:
     ```bash
     colima stop
     colima start --vz-rosetta
     docker buildx create --name multi --driver docker-container --platform linux/amd64,linux/arm64 --use
     ```

## Phase 3 — Cluster confirmation gate (MANDATORY)

Use `AskUserQuestion` to confirm the target cluster. Never skip this gate, even if `--context` is explicitly passed.

Show:

- `$CONTEXT`
- `kubectl --context $CONTEXT cluster-info | head -1` (the API server URL)
- `$NAMESPACE` and `$RELEASE`
- A one-line summary of what the skill is about to do (build image, set image, or apply), based on the mode that will be selected in Phase 6

Options: `Deploy here` / `Cancel`. Only proceed on explicit confirmation.

If the context name contains `prod`, or the API server URL matches a known production pattern the user has flagged, add an extra warning line — but still honour an explicit confirmation.

## Phase 4 — Registry resolution

If `--registry` is set, use it as `$REGISTRY`.

Otherwise, generate a private, non-guessable ttl.sh path:

```bash
UUID=$(uuidgen | tr 'A-Z' 'a-z')
REGISTRY="ttl.sh/$UUID"
```

Full image path becomes `ttl.sh/<uuid>/<pkg>:<tag>@sha256:<digest>`. Emit a note:

- "Image pushed to `ttl.sh/<uuid>/…` — 24-hour TTL, name is not discoverable."
- "To redeploy the exact same build later, pass `--registry=ttl.sh/<uuid>` — otherwise a new UUID will be generated."

## Phase 5 — Build (unless `--skip-build`)

Run from the repo root:

```bash
REGISTRY=$REGISTRY TAG=$TAG PLATFORM=linux/amd64 BUILDER=multi PUSH=1 \
  make --directory packages/<section>/<pkg> image
```

Notes:

- `PLATFORM` should be `linux/amd64` for `dev9`-like clusters; detect from `kubectl --context $CONTEXT get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}'` and set accordingly.
- `BUILDER=multi` matches the name from Phase 2 — if the user already had a builder with a different name, use that.
- `make image` will re-write the package's `values.yaml` in place (via `yq -i`) to inject the resolved `<image>@sha256:<digest>`. Verify the diff:
  ```bash
  git diff --quiet packages/<section>/<pkg>/values.yaml || echo "values.yaml updated"
  ```
  If unchanged, something went wrong (e.g., image build silently succeeded but push failed — check the `make` output for `pushing manifest` lines).

Record the resulting digests per container image — you will need them in Mode B.

## Phase 6 — HelmRelease state detection

```bash
kubectl --context $CONTEXT --namespace $NAMESPACE get helmrelease $RELEASE \
  -o jsonpath='{.spec.chartRef.kind}{"\t"}{.spec.suspend}{"\n"}' 2>/dev/null
```

Decide mode:

- **Mode A — Fresh install**: the command returns nothing / errors with NotFound. No existing release.
- **Mode B — Dev-loop (ExternalArtifact)**: `.spec.chartRef.kind` is `ExternalArtifact`. `cozyhr apply` will pull the chart from the artifact and **ignore** local `values.yaml`, so we must bypass it with `kubectl set image` after suspending.
- **Mode C — Dev-loop (inline chart)**: release exists and `.spec.chartRef.kind` is empty (chart is described inline via `chart.spec.*`). `cozyhr apply` respects local `values.yaml` here.

State which mode was selected in your running commentary.

## Phase 7 — Deploy

### Mode A — Fresh install

```bash
make --directory packages/<section>/<pkg> apply NAMESPACE=$NAMESPACE NAME=$RELEASE
```

`cozyhr apply` will create the release with the local chart + local values.

### Mode B — Dev-loop with ExternalArtifact

The chartRef ignores local values, so don't try `cozyhr apply` with the hope it will propagate your new image. Instead:

1. Suspend the HelmRelease so Flux does not fight back:
   ```bash
   cozyhr --context $CONTEXT suspend --namespace $NAMESPACE $RELEASE
   ```
2. For each Deployment in the package that carries a container whose image was just rebuilt, patch directly:
   ```bash
   kubectl --context $CONTEXT --namespace $NAMESPACE set image \
     deploy/$DEPLOY $CONTAINER=$FULL_IMAGE_WITH_DIGEST
   ```
   Use the container names you collected in Phase 2 and the image strings produced by Phase 5 (read back from `values.yaml` with `yq`).

### Mode C — Dev-loop with inline chart

```bash
make --directory packages/<section>/<pkg> apply NAMESPACE=$NAMESPACE NAME=$RELEASE
```

`cozyhr apply` already handles the suspend.

## Phase 8 — Rollout wait

For each Deployment name discovered in Phase 2:

```bash
kubectl --context $CONTEXT --namespace $NAMESPACE rollout status deploy/$DEPLOY --timeout=5m
```

If a rollout times out, gather diagnostics before declaring failure:

```bash
kubectl --context $CONTEXT --namespace $NAMESPACE describe deploy/$DEPLOY
kubectl --context $CONTEXT --namespace $NAMESPACE logs deploy/$DEPLOY --tail=100 --all-containers --prefix
```

Show the output to the user, then stop. Do not auto-rollback.

## Phase 9 — Post-deploy verification

Print the actual image running on each pod — this is how you confirm the custom build landed (especially important in Mode B, where `helm` history will lie about what's deployed):

```bash
kubectl --context $CONTEXT --namespace $NAMESPACE get pods -l app=<app-label> \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

Match the digest against what was pushed in Phase 5. If they don't match, investigate (e.g., old ReplicaSet still around, image pull secret missing, stale HelmRelease reconciled in a race).

## Phase 10 — Resume gate

If `--no-resume` was passed: print a reminder that the HelmRelease is suspended and how to resume it later:

```bash
cozyhr --context $CONTEXT resume --namespace $NAMESPACE $RELEASE
```

Otherwise, `AskUserQuestion`: "Resume the HelmRelease now? Flux will reconcile to the upstream image within ~5 minutes, reverting the dev build."

- If yes — run the resume command, then watch the pods for a minute to confirm Flux pulls back control:
  ```bash
  cozyhr --context $CONTEXT resume --namespace $NAMESPACE $RELEASE
  kubectl --context $CONTEXT --namespace $NAMESPACE get pods -l app=<app-label> --watch
  ```
  (Let the watcher exit on Ctrl-C once upstream digest is visible.)
- If no — print the same reminder as the `--no-resume` path.

## Phase 11 — Cleanup

Unless `--keep-values` was passed, revert the values.yaml changes so a subsequent `git commit -a` does not accidentally bake the ttl.sh digest into the PR:

```bash
git --git-dir=<repo>/.git --work-tree=<repo> checkout -- packages/<section>/<pkg>/values.yaml
```

This does **not** undo anything on the cluster.

## Phase 12 — Summary

Emit a compact report:

- Package: `packages/<section>/<pkg>`
- Source commit: `git rev-parse --short HEAD`
- Image: `$FULL_IMAGE_WITH_DIGEST`
- Registry: `$REGISTRY` (flag UUID-based ttl.sh paths as "private, 24h TTL")
- Cluster: `$CONTEXT` (`$API_URL`)
- Mode selected: A / B / C
- HelmRelease status: resumed / suspended (with the resume command if suspended)
- Any warnings encountered (e.g., "pods still showing old digest after 5m")

## Guardrails

- **Never** run `kubectl apply --filename` directly — this skill relies on the cluster being GitOps-managed, and direct apply is reserved for the repo-level GitOps loop. The skill's only direct mutations are `cozyhr suspend/apply/resume` and `kubectl set image` (in Mode B), both of which are designed to coexist with Flux reconciliation.
- **Never** push commits or open PRs on behalf of the user. If a commit of the new image digest is desired, the user does that themselves.
- **Never** install or start services on the host (colima, docker, buildx). If they are missing, print the remediation commands and stop.
- **Never** proceed past Phase 3 without explicit user confirmation of the target cluster.
- **Never** delete a HelmRelease or namespace as part of cleanup.
- If something surprising happens (uncommitted work in `values.yaml` before Phase 5, unexpected suspend state on the HelmRelease, context already different from `--context`), stop and ask.

## References

Read these files on demand when reasoning about the workflow:

- `hack/common-envs.mk` — `REGISTRY`, `TAG`, `PLATFORM`, `BUILDER`, `BUILDX_ARGS`, `settag` macro
- `hack/package.mk` — targets `show`, `apply`, `diff`, `suspend`, `resume`, `delete`
- `packages/<section>/<pkg>/Makefile` — per-package `image` target and `NAME`/`NAMESPACE`
- `packages/<section>/<pkg>/values.yaml` — image field(s) rewritten by `make image`
- `packages/<section>/<pkg>/templates/*.yaml` — Deployment and container names for `kubectl set image`
