---
name: debug
description: Investigate and resolve a stuck or broken Cozystack install. Gathers symptoms via kubectl, classifies the failure (operator error / config drift / upstream bug / not-yet-supported), looks up the relevant cozystack docs to verify the operator did the right thing, searches the cozystack monorepo source for the failure path, applies a local fix or workaround when one exists, and on operator approval drafts an upstream issue with the diagnostic bundle. Never opens PRs and never opens issues silently — drafts get an explicit yes/no per filing. The `cozystack:wizard` auto-dispatches this skill whenever a downstream skill in the chain reports `failed_at` in `.state.yaml`. Also callable directly when an already-running cluster develops a problem.
argument-hint: "[--config-dir=<path>] [--context=<kube-context>] [--target=<hr|pod|namespace>] [--no-issue]"
---

# cozystack:debug

Work in reasoning mode. Use the phrasing `cozystack:debug`. Announce phase transitions: `cozystack:debug Phase N — <name>`.

> **Note on language in this SKILL.md** — every operator-facing prompt below is written in English for clarity. At runtime the skill matches the operator's natural language detected from prior conversation messages (or read from `<config-dir>/.state.yaml` `operator_language` when the wizard chain is in progress). Code identifiers, commands, file paths, and any text destined for GitHub stay canonical.

## What this skill does, in one sentence

When something in a Cozystack install is broken or stuck, find out *what*, classify *whose fault*, fix what's fixable locally, and on approval prepare a clean upstream issue for what isn't.

## Two invocation paths

- **From `cozystack:wizard`** — automatically dispatched when any chain step writes `status.<skill>.failed_at` to `<config-dir>/.state.yaml`. Inherits `config_dir`, `cluster.context`, and the failing skill's error string.
- **Direct** — operator invokes `/cozystack:debug` against an already-running cluster. Interviews for `--config-dir` (default `$PWD`), `--context` (default `kubectl config current-context`), and what hurts.

## Core principles

- Match the operator's natural language. Read from `state.operator_language` (set by `cozystack:wizard` Phase 0) or, when invoked directly, detect from the operator's previous messages in the conversation. Use that language in every prompt, AskUserQuestion option, summary, and gate. Never ask "what language?" separately. Code identifiers, command examples, file paths, and any text that ends up in a GitHub issue body stay in their canonical form (usually English).
- Read first, mutate second. Phases 1–4 are read-only.
- One valid path → just do it. When Phase 3 classification + Phase 4 action are unambiguous (operator error with a documented fix, config drift with a clear restore command), the skill applies the fix without an extra "ok to apply?" question — the symptom + classification + proposed action were already shown. Gates remain for (a) destructive workarounds (resource recreation, secret regeneration), (b) issue / PR drafts that go public (Phase 5 explicit yes/no per filing).
- Front-load the interview. The only question the debug skill should ask is in Phase 4 when classification + proposed action are ready: a single screen with symptom, classification, root cause, proposed fix / workaround, and the issue-filing question (yes / no / show-draft-first). The operator either approves the lot or names what to change. Phases 1–3 (symptom gathering, doc check, classification) are read-only and run before that screen.
- Layer-pure operator output. The skill never says "returning control to wizard", "the wizard will retry the failing skill", or any other orchestration commentary in the **operator-facing** summary. Whoever invoked the skill (a human directly, or the wizard's auto-dispatch on `failed_at`) figures out what's next on their own. Internal SKILL.md references to `cozystack:wizard` are fine for documentation; `wizard` does not appear in any text shown to the operator.
- Classify before acting. The same symptom can be operator error or upstream bug; the fix is different.
- Doc-check is not optional. Cozystack documentation is the operator's contract; verify the operator's setup against the relevant page **before** declaring upstream fault.
- One filing at a time. If multiple issues surface, finish one before starting the next — operators get confused fast.
- No PRs. v1 only drafts issue bodies. Patches that the operator wants to upstream are out of scope and stay manual.
- No silent filings. Every issue draft is shown for approval. If the operator doesn't have a GitHub account, no problem — the diagnostic bundle is still useful to them.

## Phase 1 — Gather symptoms

Find the failing surface. Sources in priority order:

1. **State file** — if `<config-dir>/.state.yaml` exists and has `status.<skill>.failed_at`, read `error` and `dispatched_at`. This is the wizard-auto-dispatch path.
2. **Operator-supplied target** — `--target=hr/<ns>/<name>` or `--target=pod/<ns>/<name>` or `--target=namespace/<ns>` narrows scope.
3. **Cluster scan** — when nothing's specified, run a broad sweep:

   ```bash
   kubectl --context $CTX get hr -A | grep -v ' True '
   kubectl --context $CTX get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
   kubectl --context $CTX get events -A --sort-by=.lastTimestamp --field-selector=type=Warning
   ```

   Surface the first 10 anomalies and ask the operator which to investigate.

For each candidate failure, pull deeper:

```bash
kubectl --context $CTX --namespace $NS describe hr $NAME | sed -n '/Status:/,$p'
kubectl --context $CTX --namespace $NS get events --sort-by=.lastTimestamp --field-selector involvedObject.kind=HelmRelease,involvedObject.name=$NAME
kubectl --context $CTX --namespace flux-system logs deploy/helm-controller --tail=200 | grep -i "$NAME" || true
kubectl --context $CTX --namespace cozy-system logs deploy/cozystack-operator --tail=200
```

For stuck pods:

```bash
kubectl --context $CTX --namespace $NS describe pod $POD
kubectl --context $CTX --namespace $NS logs $POD --all-containers --tail=200
```

Record findings as a structured **symptom record** the rest of the phases will reference. See `references/diagnostic-bundle.md` for the canonical format.

## Phase 2 — Doc check (is the operator doing the right thing?)

Pull the cozystack docs page relevant to the failing surface. Priority:

1. **For an HR failure** — `https://cozystack.io/docs/v<X.Y>/operations/troubleshooting/<component>/` if it exists, else the install or component page for that namespace (`cozy-dashboard` → dashboard docs, `cozy-linstor` → storage section, etc.).
2. **For a Phase-N failure surfaced by the wizard** — the corresponding section in the install guide (`https://cozystack.io/docs/v<X.Y>/install/kubernetes/<distro>/`).

The local checkouts are the fastest source:

- `~/git/github.com/cozystack/website/content/en/docs/v<X.Y>/...`
- `~/git/github.com/cozystack/cozystack/docs/changelogs/v<X.Y>.md`
- `~/git/github.com/cozystack/ansible-cozystack/CHANGELOG.rst`

Compare the operator's actual state (`.state.yaml`, `cozystack-platform-package.yaml`, `inventory.yml`) against what the docs say should be set. Surface deltas:

```text
doc check — cozy-dashboard HR stuck

cozystack/docs/v1.3/install/kubernetes/generic.md line 160 says:
   "Run kubectl patch tenants/root --type=merge --patch '{\"spec\":{\"ingress\":true}}' after Platform Package apply."

your state:
   - cluster-install Phase 8 watch loop applied the patch inline at 17:25 UTC
   - root Tenant CR shows .spec.ingress=true
   - root-ingress-controller Service has EXTERNAL-IP 10.0.0.50 — Ready

verdict: operator did the documented step. The failure is downstream.
```

This is the **operator-not-dumb** check. If the verdict is `operator did NOT do the documented step`, the fix is to do that step, not to file an upstream issue.

## Phase 3 — Classify

After the doc check, place the failure into one of four buckets:

| Bucket | Signal | Action in Phase 4 |
|---|---|---|
| **operator error** | The docs prescribed step X, the operator's state shows X not done. | Walk operator through doing X. No issue. |
| **config drift** | Something on the cluster changed since install (manual `kubectl edit`, third-party operator, etc.) that breaks the documented invariant. | Restore the invariant. Maybe file a note in the operator's runbook; no upstream issue. |
| **upstream bug** | Operator followed docs, state matches what docs prescribe, but the system behaves contrary to documented behaviour. | Apply local workaround if known. Offer to draft an upstream issue. |
| **not-yet-supported** | Operator is asking the system to do something the docs explicitly say is unsupported (RHEL 10 ZFS, LVM thin in v1, etc.). | Print the unsupported-by-design note. Offer to draft a feature-request issue. |

If the bucket is ambiguous after one round of investigation, **ask the operator** to clarify the path — don't guess. Two rounds of bad classification waste more time than one explicit question.

## Phase 4 — Act

### operator error
Print the missing step from the docs verbatim, with the exact command and approve prompt. If the operator approves, run it. If not, stop and let them.

### config drift
Show the divergence (what doc said vs what state shows now), propose the corrective command, ask approve. After the fix lands, suggest the operator add it to their cluster runbook.

### upstream bug
Look up the failure in the cozystack source. See `references/source-search.md` for the grep pattern that maps HR names / error strings → file paths in the monorepo. Common shapes:

- Error message from `cozystack-operator` logs → grep the operator Go source for the format string.
- Chart render failure → grep the failing chart's `templates/` for the broken template path; check `values.yaml` for the unset key.
- LinstorSatelliteConfiguration / piraeus issues → forward to `linstor:recover` skill instead of this one.

If a local workaround exists (`cluster-install/references/known-failures.md` is the catalogue), apply it on approve. Track the upstream root cause separately:

```text
workaround applied: <description>
root cause:        <upstream file:line + 1-line summary>

The workaround keeps your cluster running. The root cause is a real upstream bug.

Open an issue in <repo> with the diagnostic bundle?

  - Yes — I'll prepare the issue body and the gh command for you to review.
  - No  — skip the upstream filing.
  - Not sure — show me how the issue draft would look first.
```

### not-yet-supported
Print the relevant doc section that says "not supported". Operator can still ask to file a feature request:

```text
This is not currently supported by Cozystack:
  - <quote from docs>
  - <link to docs>

Options:
  - Use a supported alternative — <describe>
  - Open a feature-request issue in cozystack/cozystack
  - Drop the requirement
```

## Phase 5 — Issue draft (only on Phase 4 yes)

Skip entirely if the operator said no or chose a local-only resolution.

1. **Search existing issues first** — duplicates are noise:

   ```bash
   gh issue list --repo cozystack/<repo> --state all --search "<key terms from symptom>"
   ```

   If something looks like a match, surface the existing issue number and ask: comment on the existing thread, or open a new one with cross-link?

2. **Choose the repo** — see `references/upstream-routing.md`. The fast table:

   | Failure shape | Repo |
   |---|---|
   | Chart render / operator runtime / Package CR semantics | `cozystack/cozystack` |
   | Install doc gap / contradicts reality | `cozystack/website` |
   | ansible-cozystack playbook missing a step or broken on a distro | `cozystack/ansible-cozystack` |
   | talm tool / chart preset | `cozystack/talm` |
   | boot-to-talos | `cozystack/boot-to-talos` |
   | piraeus-operator / LINSTOR / DRBD / kube-ovn upstream-of-cozystack | direct to the upstream-upstream repo, mention cozystack version in the body |

3. **Render the issue body** from the symptom record + doc-check delta + diagnostic bundle reference. Templates per repo in `references/issue-templates.md`. Public-content rules apply: English, singular first person, no private cluster names, no internal tool names, no `@mentions`.

4. **Print the exact `gh` command** but **do not execute it**:

   ```bash
   gh issue create --repo cozystack/<repo> \
     --title "<short factual title>" \
     --body-file <config-dir>/diagnostics-<ts>/issue-body.md
   ```

   Tell the operator if they don't have a GitHub account, the diagnostic bundle at `<config-dir>/diagnostics-<ts>/` is still useful — they can hand it to someone who does, or attach it to a Slack thread / support ticket.

## Phase 6 — Update state and hand back

If invoked from `cozystack:wizard`, write to `<config-dir>/.state.yaml`:

```yaml
status:
  debug:
    completed_at: <ISO_TS>
    target: <hr|pod|namespace>/<ns>/<name>
    classification: <operator-error | config-drift | upstream-bug | not-supported>
    action: <resolved | workaround | issue-drafted | no-action>
    issue_repo: <repo or "">
```

The wizard's dispatch loop reads this and decides next step:

- `classification: operator-error` + `action: resolved` → retry the originally-failing skill (e.g. re-run `cluster-install` Phase 8 wait).
- `classification: upstream-bug` + `action: workaround` → retry the originally-failing skill.
- `classification: upstream-bug` + `action: issue-drafted` (no workaround) → wizard pauses, offers Cancel / Skip the failing step.
- `classification: not-supported` → wizard offers Cancel.

If invoked directly, print a one-page summary instead.

## Guardrails

- NEVER open a GitHub issue automatically. Always show the draft body and the gh command, then wait for the operator. If they say no, drop it.
- NEVER open a pull request. v1 only drafts issue bodies. Patches that the operator wants to send upstream are a manual follow-up.
- NEVER skip the doc-check in Phase 2. Even if the failure looks obviously upstream, verify the operator's state against docs first — saves filing a duplicate or wrong issue.
- NEVER classify as "upstream bug" without naming the source location (file:line in a cozystack/* repo). "Something is wrong somewhere in cozystack" is not a classification.
- NEVER apply a destructive workaround without explicit approve. Per-step gate.
- NEVER include private infrastructure names in issue bodies. Replace with generic placeholders.
- ALWAYS prefer to extend the local `known-failures.md` catalogue when a new workaround surfaces — that's how the catalogue gets useful.
- ALWAYS leave the operator with a clear next step, even if the skill couldn't resolve anything.

## References

- `references/classification.md` — decision tree operator vs upstream + signals per bucket.
- `references/diagnostic-bundle.md` — symptom-record format + the bundle script (shares the script with `cluster-install/references/issue-templates.md`).
- `references/source-search.md` — how to grep the cozystack monorepo from a symptom (error string / chart name / namespace / operator log line).
- `references/upstream-routing.md` — per-repo routing for issue filings.
- `references/issue-templates.md` — per-repo issue body templates with placeholders.

Cross-references:

- `/cozystack:cluster-install`'s `known-failures` catalogue at `plugins/cozystack/skills/cluster-install/references/known-failures.md` — catalogue of known failures with workarounds; reuse before reinventing.
- `/linstor:recover` — for DRBD / LINSTOR storage failures, prefer that skill; it's more specialised.
- `/cozystack:wizard` — auto-dispatches this skill when downstream `failed_at` is set.
