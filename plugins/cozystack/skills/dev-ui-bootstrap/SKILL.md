---
name: dev-ui-bootstrap
description: Bootstrap a UI dev sandbox — Playwright end-to-end testing scaffolding for the cozystack-ui SPA plus a Vite dev server connected to a chosen Kubernetes cluster. Use whenever the operator wants to fix, debug, screenshot, or write Playwright tests against the Cozystack console — e.g. "prepare cozystack-ui for a fix", "spin up the UI against my dev cluster", "install playwright in cozystack-ui", "give me a UI sandbox pointing at <kubeconfig>". Handles worktree creation, @playwright/test + Chromium install, playwright.config.ts, dev:e2e / test:e2e scripts, kubectl proxy against a kubeconfig, and a Vite server on a free port so the operator can immediately start poking at the running app.
argument-hint: "[--kubeconfig=<path>] [--worktree=<name>] [--port=<n>] [--proxy-port=<n>] [--no-install] [--no-browser]"
---

# cozystack:dev-ui-bootstrap

This skill puts an operator in front of a running, working copy of `cozystack-ui` with Playwright wired up, pointed at a real Kubernetes cluster of their choosing. It is the standard entry point for "I want to fix something in the UI" tasks — every step is reversible and avoids touching the repo's main worktree.

Work in reasoning mode. Walk through the phases in order. State which phase you are in as you go, so the operator can interrupt early if a default is wrong for their machine.

Use the phrasing "`cozystack:dev-ui-bootstrap`" (not "the skill") in messages to the operator, and state progress at each phase boundary.

Match the operator's natural language detected from prior conversation messages — use it in prompts, AskUserQuestion options, summaries, and gates. Code identifiers, commands, file paths, and commit messages stay in their canonical form (usually English).

## Phase 1 — Parse arguments

`$ARGUMENTS` is the free-form tail after `/cozystack:dev-ui-bootstrap`. Extract:

- `--kubeconfig=<path>` — kubeconfig the Vite dev server should hit through `kubectl proxy`. If absent: list `~/.kube/*config*` files via `ls`, then `AskUserQuestion` to pick one, defaulting to `~/.kube/config` (or `$KUBECONFIG` if set). Never assume `~/.kube/config` silently — picking the wrong cluster is a frequent footgun.
- `--worktree=<name>` — name (relative to `<repo>/.claude/worktrees/`) for the throwaway worktree. Default: `fix-app` (matches the in-tree convention).
- `--port=<n>` — Vite dev port. Default: pick the first free port starting at `3002` (since `3001` is the repo default and is often already in use by another session).
- `--proxy-port=<n>` — `kubectl proxy` port. Default: `8001` (matches `apps/console/vite.config.ts`). If already in use by a proxy pointing at a *different* kubeconfig, pick the next free port (see Phase 7 for the Vite-side consequence).
- `--no-install` — skip `pnpm install` and `@playwright/test` install if they are already present.
- `--no-browser` — skip `npx playwright install chromium`.

## Phase 2 — Locate the cozystack-ui repo

Resolve in priority order:

1. If `pwd` is inside a checkout of `cozystack-ui` (contains `apps/console/package.json` with `"name": "@cozystack/console"`) → use the repo root from `git rev-parse --show-toplevel`.
2. `~/aenix/cozystack-ui` — the canonical clone on contributors' workstations.
3. Otherwise — `AskUserQuestion` for the path. Do not `git clone`; the skill is for an already-cloned working copy.

Verify `pnpm` and `kubectl` are on `$PATH`, and that the workspace's `package.json` has `"packageManager": "pnpm@..."`. If either binary is missing, stop and tell the operator to install it — do not auto-install package managers or CLIs. Catching this here avoids failing five phases deeper when `kubectl proxy` is first invoked.

## Phase 3 — Worktree creation

Create a feature worktree off `main` for the upcoming fix work. The repo's CLAUDE.md is emphatic that the primary working directory must stay on its default branch — multiple Claude sessions share it.

```bash
git -C <repo> worktree add <repo>/.claude/worktrees/<name> -b fix/<name> main
```

If a worktree at that path already exists:

- If clean and on the expected branch → reuse it; no `git worktree add`.
- If dirty or on a different branch → `AskUserQuestion`: reuse / pick a new name / cancel.

Set `$WT` to the absolute worktree path. Every subsequent command in this skill runs from `$WT`.

## Phase 4 — Install dependencies

Always run `pnpm install` once in `$WT` (fast no-op if the lockfile is satisfied) — workspace symlinks must exist before Playwright lands.

Then, unless `--no-install`:

```bash
pnpm --filter @cozystack/console add -D @playwright/test
```

Unless `--no-browser`:

```bash
cd $WT/apps/console && pnpm exec playwright install chromium
```

Chromium is ~120 MB. Note the size in the running commentary so an operator on a slow link knows what is happening. The download lives in `~/.cache/ms-playwright/` and is shared across worktrees — usually a one-time cost.

## Phase 5 — Write Playwright config + scripts

Idempotency: if `apps/console/playwright.config.ts` already exists, diff against the template below and ask before overwriting — the operator may have customised it.

Write `$WT/apps/console/playwright.config.ts`:

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

Create `$WT/apps/console/e2e/` (empty — tests land here as the operator writes them).

Patch `$WT/apps/console/package.json` `"scripts"` with `Edit` — preserve unrelated keys, do not rewrite the whole file:

- Add `"dev:e2e": "vite --port <PORT>"` next to `"dev"`.
- Add `"test:e2e": "playwright test"` next to `"test"`.

No semicolons in the config file — the repo's CLAUDE.md is strict: every file in the tree is semicolon-free, and reformatting unrelated files is forbidden.

## Phase 6 — Bring up `kubectl proxy`

Goal: a `kubectl proxy` instance is reachable on `$PROXY_PORT` and is talking to **the kubeconfig the operator picked**, not whatever happened to be active in the shell.

1. Check whether `lsof -nP -iTCP:$PROXY_PORT -sTCP:LISTEN` (or `ss -tlnp`) already has a listener.
2. If yes, inspect the existing process command line (`ps -p <pid> -o args=`). If it is a `kubectl proxy` pointing at the same kubeconfig (look for `--kubeconfig` in the args; if absent, check `KUBECONFIG` env in `/proc/<pid>/environ`), reuse it. Otherwise pick the next free port (start at `$PROXY_PORT+1`) and rewrite Vite's proxy `target` accordingly (see Phase 7).
3. If no listener, resolve the target context and start a new proxy in the background:
   ```bash
   CTX=$(kubectl --kubeconfig <path> config current-context)
   kubectl --kubeconfig <path> --context $CTX proxy --port=$PROXY_PORT &
   ```
4. Smoke-test with `curl -sS -o /dev/null -w "%{http_code}" http://localhost:$PROXY_PORT/api/v1/namespaces/default`. Expect `200`. On `401`/`403` the kubeconfig is wrong or expired — surface the error and stop. On connection refused, wait up to 5 s for the proxy to come up before failing.

Capture the proxy process ID and the kubeconfig path in a marker file at `$WT/.cozystack-dev-ui-bootstrap-proxy` so a follow-up session knows what is running. Never write secrets there — kubeconfig path and context name only.

## Phase 7 — Start the Vite dev server

If `$PROXY_PORT` is non-default (8001), the dev server still hard-codes `http://localhost:8001` in `vite.config.ts`. Two options:

- Preferred: keep the default proxy port `8001` and explain why. The repo treats `vite.config.ts` as load-bearing and edits there are best left for a separate PR.
- If the operator explicitly said "change the proxy port", `AskUserQuestion` before touching `vite.config.ts`.

Start the dev server in the background, capturing output:

```bash
cd $WT && pnpm --filter @cozystack/console dev:e2e
```

Wait for the `ready in` / `Local:` line via a polling loop (`until grep -q ...`). Then `curl -sS -o /dev/null -w "%{http_code}" http://localhost:$PORT/` and expect `200`.

If the server fails to bind (port already in use after the free-port scan), the cause is usually a stale `vite` from a prior crashed session. Run `lsof -nP -iTCP:$PORT -sTCP:LISTEN` and show the result — let the operator decide whether to kill it.

## Phase 8 — Summary

Print a compact handoff:

- Worktree: `$WT` (branch `fix/<name>`)
- Repo state: clean / dirty (one-line `git status -s`)
- Kubeconfig: `<path>` → cluster context `<name>` (resolved in Phase 6)
- `kubectl proxy`: `pid <n>` on `http://localhost:$PROXY_PORT` (smoke `200`)
- Vite dev: `pid <n>` on `http://localhost:$PORT` (smoke `200`)
- Playwright: configured at `apps/console/playwright.config.ts`, run with `pnpm --filter @cozystack/console test:e2e`
- Next steps the operator can take, e.g.: "Tell me what to fix, or paste a Playwright test idea and I will draft it."

Do **not** open the browser. Leave that to the operator — the dev server is reachable and the operator may want to attach an authenticated session, devtools, or a screen recorder of their own choice.

## Guardrails

- **Never** run `git checkout` in the primary `cozystack-ui` working tree. All branch work happens inside the worktree from Phase 3.
- **Never** edit files in the primary working tree of `cozystack-ui` — only inside `$WT`.
- **Never** commit, push, or open a PR as part of this skill. The skill *prepares* the environment; the fix itself is a separate, operator-driven step that goes through the normal commit / PR gates.
- **Never** start a `kubectl proxy` with a kubeconfig the operator did not explicitly pick. If `--kubeconfig` is absent, ask.
- **Never** kill a process the operator did not authorise. If a port is occupied, show what is on it and stop.
- **Never** add a new top-level dependency to the cozystack-ui workspace other than `@playwright/test`. The repo's CLAUDE.md is strict about bundle size; Playwright is dev-only and acceptable.
- Refuse to run against a kubeconfig whose current-context name contains `prod` unless the operator re-confirms with `AskUserQuestion`. The console is read/write — pointing it at production is a deploy-shaped risk.

## References

- `apps/console/vite.config.ts` — the existing dev server proxy contract (`/api`, `/apis`, `/k8s` → `http://localhost:8001`).
- `apps/console/package.json` — where the new `dev:e2e` and `test:e2e` scripts land.
- `CLAUDE.md` (repo root) — code style (no semicolons, `.ts` extensions in imports, no `any`, etc.) and the worktree mandate.
- `~/.kube/` — separate kubeconfigs per cluster (this host uses one-file-per-cluster, not a merged config).
