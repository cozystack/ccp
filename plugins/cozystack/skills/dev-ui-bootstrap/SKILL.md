---
name: dev-ui-bootstrap
description: Bootstrap a UI dev sandbox — Playwright end-to-end testing scaffolding for the Cozystack console UI (vendored in the monorepo at `packages/system/dashboard/images/console`) plus a Vite dev server connected to a chosen Kubernetes cluster. Use whenever the operator wants to fix, debug, screenshot, or write Playwright tests against the Cozystack console — e.g. "prepare the console UI for a fix", "spin up cozystack-ui against my dev cluster", "install playwright in the console", "give me a UI sandbox pointing at <kubeconfig>". Handles monorepo worktree creation, @playwright/test + Chromium install, playwright.config.ts, dev:e2e / test:e2e scripts, kubectl proxy against a kubeconfig, and a Vite server on a free port so the operator can immediately start poking at the running app.
argument-hint: "[--kubeconfig=<path>] [--worktree=<name>] [--port=<n>] [--proxy-port=<n>] [--no-install] [--no-browser]"
---

# cozystack:dev-ui-bootstrap

This skill puts an operator in front of a running copy of the Cozystack console UI with Playwright wired up, pointed at a real Kubernetes cluster of their choosing. The UI is vendored in-tree in the `cozystack/cozystack` monorepo at `packages/system/dashboard/images/console` (the standalone `cozystack-ui` repo is archived). It is the standard entry point for "I want to fix something in the UI" tasks — every step is reversible and avoids touching the monorepo's main worktree.

Work in reasoning mode. Walk through the phases in order. State which phase you are in as you go, so the operator can interrupt early if a default is wrong for their machine.

Use the phrasing "`cozystack:dev-ui-bootstrap`" (not "the skill") in messages to the operator, and state progress at each phase boundary.

Match the operator's natural language detected from prior conversation messages — use it in prompts, AskUserQuestion options, summaries, and gates. Code identifiers, commands, file paths, and commit messages stay in their canonical form (usually English).

## Phase 1 — Parse arguments

`$ARGUMENTS` is the free-form tail after `/cozystack:dev-ui-bootstrap`. Extract:

- `--kubeconfig=<path>` — kubeconfig the Vite dev server should hit through `kubectl proxy`. If absent: list `~/.kube/*config*` files via `ls`, then `AskUserQuestion` to pick one, defaulting to `~/.kube/config` (or `$KUBECONFIG` if set). Never assume `~/.kube/config` silently — picking the wrong cluster is a frequent footgun.
- `--worktree=<name>` — name (relative to `<repo>/.claude/worktrees/`) for the throwaway monorepo worktree. Default: `fix-app`.
- `--port=<n>` — Vite dev port. Default: pick the first free port starting at `3002` (since `3001` is the console default and is often already in use by another session).
- `--proxy-port=<n>` — `kubectl proxy` port. Default: `8001` (matches the console's `apps/console/vite.config.ts`). If already in use by a proxy pointing at a *different* kubeconfig, pick the next free port (see Phase 7 for the Vite-side consequence).
- `--no-install` — skip `pnpm install` and `@playwright/test` install if they are already present.
- `--no-browser` — skip `npx playwright install chromium`.

## Phase 2 — Locate the console workspace (in-tree in the monorepo)

The console UI is a pnpm workspace inside the monorepo, not a standalone repo. Resolve two paths:

- `$REPO` — the `cozystack/cozystack` monorepo root (git / worktree operations happen here).
- `$CONSOLE` — the workspace root, `$REPO/packages/system/dashboard/images/console` (all `pnpm` / `vite` / `playwright` / file edits happen here; it holds `pnpm-workspace.yaml`, the root `package.json`, `pnpm-lock.yaml`, and `apps/console`).

Resolve `$REPO` in priority order:

1. If `pwd` is inside a cozystack monorepo checkout whose `<toplevel>/packages/system/dashboard/images/console/apps/console/package.json` has `"name": "@cozystack/console"` → use the toplevel from `git rev-parse --show-toplevel`.
2. `~/aenix/cozystack` — the canonical monorepo clone on contributors' workstations.
3. Otherwise — `AskUserQuestion` for the monorepo path. Do not `git clone`; the skill is for an already-cloned working copy.

> The console UI used to live in a standalone `cozystack-ui` repo. It was vendored into the monorepo (cozystack/cozystack#2963) and that repo is archived — there is no `~/aenix/cozystack-ui` to use anymore.

Verify `pnpm` and `kubectl` are on `$PATH`, and that `$CONSOLE/package.json` has `"packageManager": "pnpm@..."`. If either binary is missing, stop and tell the operator to install it — do not auto-install package managers or CLIs. Catching this here avoids failing five phases deeper when `kubectl proxy` is first invoked.

## Phase 3 — Worktree creation

Create a feature worktree of the **monorepo** off `main` for the upcoming fix work. The user's CLAUDE.md is emphatic that the primary working directory must stay on its default branch — multiple Claude sessions share it.

```bash
git -C $REPO worktree add $REPO/.claude/worktrees/<name> -b fix/<name> main
```

If a worktree at that path already exists:

- If clean and on the expected branch → reuse it; no `git worktree add`.
- If dirty or on a different branch → `AskUserQuestion`: reuse / pick a new name / cancel.

Set `$WT` to the absolute worktree path, and re-point `$CONSOLE` into it: `$CONSOLE="$WT/packages/system/dashboard/images/console"`. Every subsequent `pnpm` / `vite` / `playwright` / file command in this skill runs from `$CONSOLE`; only `git` and worktree operations use `$REPO` / `$WT`.

## Phase 4 — Install dependencies

Always run `pnpm install` once in `$CONSOLE` (fast no-op if the lockfile is satisfied) — workspace symlinks must exist before Playwright lands. (Run it from `$CONSOLE`, not `$WT`: the monorepo root is not a pnpm workspace; the console subdirectory is.)

Then, unless `--no-install`:

```bash
cd $CONSOLE && pnpm --filter @cozystack/console add -D @playwright/test
```

Unless `--no-browser`:

```bash
cd $CONSOLE/apps/console && pnpm exec playwright install chromium
```

Chromium is ~120 MB. Note the size in the running commentary so an operator on a slow link knows what is happening. The download lives in `~/.cache/ms-playwright/` and is shared across worktrees — usually a one-time cost.

## Phase 5 — Write Playwright config + scripts

Idempotency: if `$CONSOLE/apps/console/playwright.config.ts` already exists, diff against the template below and ask before overwriting — the operator may have customised it.

Write `$CONSOLE/apps/console/playwright.config.ts`:

```ts
import { defineConfig, devices } from "@playwright/test"

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: "list",
  use: {
    baseURL: process.env.E2E_BASE_URL ?? "http://localhost:<PORT>",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
  ],
})
```

Replace `<PORT>` with the resolved Vite dev port. The `E2E_BASE_URL` env-var override lets CI or another session point Playwright at a different running instance.

Create `$CONSOLE/apps/console/e2e/` (empty — tests land here as the operator writes them).

Patch `$CONSOLE/apps/console/package.json` `"scripts"` with `Edit` — preserve unrelated keys, do not rewrite the whole file:

- Add `"dev:e2e": "vite --port <PORT>"` next to `"dev"`.
- Add `"test:e2e": "playwright test"` next to `"test"`.

No semicolons in the config file — the console's `CLAUDE.md` is strict: every file in the tree is semicolon-free, and reformatting unrelated files is forbidden.

## Phase 6 — Bring up `kubectl proxy`

Goal: a `kubectl proxy` instance is reachable on `$PROXY_PORT` and is talking to **the kubeconfig the operator picked**, not whatever happened to be active in the shell.

1. Check whether `lsof -nP -iTCP:$PROXY_PORT -sTCP:LISTEN` (or `ss -tlnp`) already has a listener.
2. If yes, inspect the existing process command line (`ps -p <pid> -o args=`). If it is a `kubectl proxy` pointing at the same kubeconfig (look for `--kubeconfig` in the args; if absent, check `KUBECONFIG` env in `/proc/<pid>/environ`), reuse it. If it is something else (different kubeconfig, unrelated process), stop and `AskUserQuestion`: kill the occupant, pick a different proxy port (and accept the Phase 7 `vite.config.ts` edit gate), or cancel. Do not silently switch ports — Phase 7 prefers leaving `vite.config.ts` untouched, so a port switch is an operator-driven decision.
3. If no listener, resolve the target context and start a new proxy in the background:
   ```bash
   CTX=$(kubectl --kubeconfig <path> config current-context)
   kubectl --kubeconfig <path> --context $CTX proxy --port=$PROXY_PORT &
   ```
4. Smoke-test with `curl -sS -o /dev/null -w "%{http_code}" http://localhost:$PROXY_PORT/api`. Expect `200`. `/api` is the unauthenticated API-group discovery endpoint — it returns `200` from any reachable apiserver and avoids false negatives from RBAC-restricted kubeconfigs that cannot `get namespaces/default`. On `401`/`403` the kubeconfig is wrong or expired — surface the error and stop. On connection refused, wait up to 5 s for the proxy to come up before failing.

Capture the proxy process ID and the kubeconfig path in a marker file at `$CONSOLE/.cozystack-dev-ui-bootstrap-proxy` so a follow-up session knows what is running. Never write secrets there — kubeconfig path and context name only.

## Phase 7 — Start the Vite dev server

If `$PROXY_PORT` is non-default (8001), the dev server still hard-codes `http://localhost:8001` in `apps/console/vite.config.ts`. Two options:

- Preferred: keep the default proxy port `8001` and explain why. The console treats `vite.config.ts` as load-bearing and edits there are best left for a separate PR.
- If the operator explicitly said "change the proxy port", `AskUserQuestion` before touching `vite.config.ts`.

Start the dev server in the background, redirecting output to a log file under `$CONSOLE` so the polling loop has something to grep:

```bash
cd $CONSOLE && pnpm --filter @cozystack/console dev:e2e \
  >$CONSOLE/.cozystack-dev-ui-bootstrap-vite.log 2>&1 &
```

Wait for the `ready in` / `Local:` line via a polling loop against that log file (`until grep -q "ready in" $CONSOLE/.cozystack-dev-ui-bootstrap-vite.log; do sleep 0.5; done`, with a 30 s timeout guard). Then `curl -sS -o /dev/null -w "%{http_code}" http://localhost:$PORT/` and expect `200`.

If the server fails to bind (port already in use after the free-port scan), the cause is usually a stale `vite` from a prior crashed session. Run `lsof -nP -iTCP:$PORT -sTCP:LISTEN` and show the result — let the operator decide whether to kill it.

## Phase 8 — Summary

Print a compact handoff:

- Monorepo worktree: `$WT` (branch `fix/<name>`); console workspace at `$CONSOLE`
- Repo state: clean / dirty (one-line `git -C $WT status -s`)
- Kubeconfig: `<path>` → cluster context `<name>` (resolved in Phase 6)
- `kubectl proxy`: `pid <n>` on `http://localhost:$PROXY_PORT` (smoke `200`)
- Vite dev: `pid <n>` on `http://localhost:$PORT` (smoke `200`)
- Playwright: configured at `$CONSOLE/apps/console/playwright.config.ts`, run with `pnpm --filter @cozystack/console test:e2e` from `$CONSOLE`
- Next steps the operator can take, e.g.: "Tell me what to fix, or paste a Playwright test idea and I will draft it."

Do **not** open the browser. Leave that to the operator — the dev server is reachable and the operator may want to attach an authenticated session, devtools, or a screen recorder of their own choice.

## Guardrails

- **Never** run `git checkout` in the primary cozystack monorepo working tree. All branch work happens inside the worktree from Phase 3.
- **Never** edit files in the primary monorepo working tree — only inside `$WT` / `$CONSOLE`.
- **Never** commit, push, or open a PR as part of this skill. The skill *prepares* the environment; the fix itself is a separate, operator-driven step that goes through the normal commit / PR gates.
- **Never** start a `kubectl proxy` with a kubeconfig the operator did not explicitly pick. If `--kubeconfig` is absent, ask.
- **Never** kill a process the operator did not authorise. If a port is occupied, show what is on it and stop.
- **Never** add a new top-level dependency to the console workspace other than `@playwright/test`. The console's `CLAUDE.md` is strict about bundle size; Playwright is dev-only and acceptable.
- Refuse to run against a kubeconfig whose current-context name contains `prod` unless the operator re-confirms with `AskUserQuestion`. The console is read/write — pointing it at production is a deploy-shaped risk.

## References

All paths below are relative to `$CONSOLE` (`packages/system/dashboard/images/console` inside the monorepo):

- `apps/console/vite.config.ts` — the existing dev server proxy contract (`/api`, `/apis`, `/k8s` → `http://localhost:8001`).
- `apps/console/package.json` — where the new `dev:e2e` and `test:e2e` scripts land.
- `CLAUDE.md` (at `$CONSOLE`) — code style (no semicolons, `.ts` extensions in imports, no `any`, etc.). The monorepo root `AGENTS.md` covers the broader worktree mandate.
- `~/.kube/` — separate kubeconfigs per cluster (this host uses one-file-per-cluster, not a merged config).
