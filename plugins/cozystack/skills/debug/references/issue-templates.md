# Issue body templates per repo

Phase 5 of `cozystack:debug` renders one of these templates into `<config-dir>/diagnostics-<ts>/issue-body.md`, then prints the `gh issue create` command for the operator to review. Public-content rules apply: English, singular first person, no private cluster names, no internal tool names (no `cozystack:debug` mention in the body — operator's perspective: "I hit this while running Cozystack v1.3.x"), no `@mentions`.

## Common preamble (every template)

```markdown
**Cozystack version**: <X.Y.Z>
**Kubernetes**: <distro> <version>
**Platform variant**: <isp-full | isp-full-generic | isp-hosted | default>
**Install path**: <bare-metal-talos | bare-metal-ubuntu | existing-k8s | managed-k8s>
**Nodes**: <N> × <arch> on <OS>

(Diagnostic bundle attached: `cozystack-diagnostics-<ts>.tar.gz` — logs redacted of secrets.)
```

## cozystack/cozystack — operator / chart / package CR bug

```markdown
### What happened

<one paragraph: which HelmRelease / Package CR / operator behaviour is wrong. Quote the failing condition / log line verbatim in a fenced block.>

### Expected behaviour

<one sentence — what the docs / chart values / CRD schema imply should happen.>

### Steps to reproduce

1. Fresh <distribution> v<version> cluster, bootstrapped per `docs/v<X.Y>/install/kubernetes/<distro>/`.
2. `helm upgrade --install cozy-installer oci://ghcr.io/cozystack/cozystack/cozy-installer --version <X.Y.Z> --namespace kube-system --set cozystackOperator.variant=<variant> --set cozystack.apiServerHost=<IP>`
3. Apply Platform Package with `spec.variant: <platform-variant>`. Full Package YAML attached at `values.yaml` in the bundle.
4. Observe `<which HR / pod / event>` — <symptom>.

### Source

The failing path looks like:

- `<repo path>:<line>` — <one-line summary>

(If unsure, leave this section as "I haven't pinpointed the exact source location — pointers welcome.")

### Workaround

<if known — describe; if not — "None known.">

### Logs and manifests

Diagnostic bundle attached. Key files:

- `helmreleases.yaml` — all HR statuses at the time of failure
- `operator.log` — cozystack-operator last 2000 lines
- `helm-controller.log` — helm-controller last 2000 lines
- `hr-<ns>-<name>.txt` — detailed describe of the failing HR
- `values.yaml` — the Package CR I applied (secrets redacted)
```

## cozystack/cozystack (feature request — missing value key)

```markdown
### Use case

<one paragraph — what I'm trying to do and why the supported configuration doesn't cover it.>

### Current state

<what cozystack does today; what values keys exist; why none of them solve the use case.>

### Proposed extension

<which values key would solve this, with a short example YAML.>

### Why not solve it locally

<why the operator can't just patch the chart in their own fork — usually because the change is generic, or because the operator wants the cozystack-managed upgrade path.>

### Workaround currently in use

<if any — describe; if none — "I'm blocked.">
```

## cozystack/website — doc gap

```markdown
### Documentation page

`https://cozystack.io/docs/v<X.Y>/install/kubernetes/<page>/`
(local path: `content/en/docs/v<X.Y>/install/kubernetes/<page>.md`)

### What I expected to find

<the question I had / the step I needed.>

### What the page says

<quote the relevant section, or note it's absent.>

### What I had to do instead

<the workaround I figured out, with commands.>

### Suggested change

<one paragraph — what addition would have unblocked a first-time installer.>
```

## cozystack/website — doc contradicts reality

```markdown
### Documentation page

`https://cozystack.io/docs/v<X.Y>/<section>/<page>/`
(local path: `content/en/docs/v<X.Y>/<section>/<page>.md`)

### What the page says

<verbatim quote>

### What the system does

<describe — with the relevant CRD / chart / log line that contradicts.>

### Suggested change

<which way to reconcile — change the doc, or change the implementation. If both, file a paired issue in cozystack/cozystack.>
```

## cozystack/ansible-cozystack — playbook gap

```markdown
### Distribution / OS

<exact OS version, kernel, init system. Output of `cat /etc/os-release; uname -r` on the affected node.>

### Task that should exist but doesn't

<which step from `docs/v<X.Y>/install/kubernetes/generic.md` (or equivalent) the role does not automate, with quoted lines from the doc.>

### Manual workaround

<the commands I ran by hand to get past the gap, with output snippets.>

### Suggested role change

<one paragraph — a new task or a new default. Reference an existing similar task in the role for style.>
```

## cozystack/ansible-cozystack — playbook broken on a distro

```markdown
### Distribution / version

<OS + version + kernel + ansible version>

### Symptom

<which playbook + which task fails, with the error from ansible's output.>

### Reproduction

```bash
cd ~/git/github.com/cozystack/ansible-cozystack/examples/<distro>
ansible-galaxy collection install --requirements-file requirements.yml
ansible-playbook --inventory inventory.yml site.yml
# Fails at task '<task name>' on '<host>'
```

### Workaround

<if any — describe the manual fix that lets the install proceed.>

### Suggested fix

<which task needs to change, with a proposed diff if obvious.>
```

## cozystack/talm — chart preset bug

```markdown
### Symptom

<which generated machine-config field is wrong, or which talm command fails.>

### Reproduction

```bash
cd <my-cluster-config-dir>
talm init --preset cozystack --endpoint https://<CP1_IP>:6443
# nodes/cp1.yaml is missing <X> / contains <Y> when it should contain <Z>
```

### Source

`~/git/github.com/cozystack/talm/charts/cozystack/templates/_helpers.tpl:<line>` — <one-line summary>

### Suggested fix

<which template needs to change, with a proposed diff if obvious.>
```

## Upstream-upstream (piraeus / LINSTOR / Kube-OVN / Cilium / KubeVirt / cert-manager)

```markdown
**Cross-link**: cozystack/cozystack#NNNN (if filed there too)
**Cozystack context**: Cozystack v<X.Y.Z>, chart at `packages/<area>/<name>/charts/<name>/Chart.yaml` version <V>.

### What happened

<symptom — in upstream-upstream terms, not cozystack terms.>

### Expected behaviour

<from the upstream-upstream docs.>

### Steps to reproduce

<minimal repro that doesn't require Cozystack if possible. If it does require Cozystack, name the cozystack release explicitly.>

### Environment

<as the upstream-upstream project asks for it — usually different from cozystack's required fields.>
```

## Title shape per repo

Keep titles factual, 60–80 chars, no marketing.

| Repo | Title shape |
|---|---|
| cozystack/cozystack | `<area>: <symptom> in <release>` e.g. "dashboard: gatekeeper OIDC discovery times out in v1.3.2" |
| cozystack/website | `docs(<section>): <gap or contradiction>` e.g. "docs(install/generic): missing dm_thin_pool module note for LVM thin" |
| cozystack/ansible-cozystack | `<example>: <task or distro> — <symptom>` e.g. "examples/ubuntu: prepare-ubuntu.yml fails on RHEL 10 ZFS step" |
| cozystack/talm | `chart/cozystack: <symptom>` or `talm: <command bug>` |
| upstream-upstream | follow the project's own convention; check their CONTRIBUTING.md before filing. |

## Don't include in the body

- `cozystack:debug` skill name (operator-visible, not a Cozystack feature; would confuse maintainers).
- Any reference to "claude" / "AI" / the workflow that produced the report — irrelevant to the maintainer triage.
- Slack / Telegram screenshots (use the GitHub-flavored diagnostic bundle).
- Stack traces longer than 200 lines — put them in the bundle, reference by filename.
