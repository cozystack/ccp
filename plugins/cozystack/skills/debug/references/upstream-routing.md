# Upstream routing — which repo gets the issue

Phase 5 of `cozystack:debug` picks one repo per filing. Wrong-repo filings get closed without action and waste everyone's time. Use the table below; when in doubt, ask the operator.

## Routing table

| Failure shape | Repo |
|---|---|
| Chart render error (`templates/*.yaml` fail / missing key / wrong values) | `cozystack/cozystack` |
| cozystack-operator runtime error (panic, reconcile failure, wrong reconcile decision) | `cozystack/cozystack` |
| Package CR rejected by API server (CRD schema / admission webhook) | `cozystack/cozystack` |
| Platform Package template doesn't expose a value the operator needs | `cozystack/cozystack` (feature request) |
| Install doc gap (step missing) | `cozystack/website` |
| Install doc wrong (step exists but contradicts reality) | `cozystack/website` |
| Hardware / supported-matrix question | `cozystack/website` |
| ansible-cozystack playbook missing a task | `cozystack/ansible-cozystack` |
| ansible-cozystack playbook broken on a specific distro / Secure Boot host | `cozystack/ansible-cozystack` |
| ansible-cozystack defaults / variable confusion | `cozystack/ansible-cozystack` |
| talm chart preset missing a kernel module / extension | `cozystack/talm` |
| talm binary bug (parser, render error) | `cozystack/talm` |
| boot-to-talos bug (kexec failure, install mode broken on a hardware family) | `cozystack/boot-to-talos` |
| extractedprism bug | `lexfrei/extractedprism` — independent BSD-3 project; file there for proxy-specific bugs. See README "Third-party dependencies" for the dependency policy. |
| LINSTOR / piraeus-operator behaviour (storage pool not registered, DRBD up but no replicas) | upstream `piraeusdatastore/piraeus-operator` (mention cozystack version + chart version in the body) |
| LINSTOR API issue (`linstor sp l` returns garbage, controller crashes) | upstream `LINBIT/linstor-server` |
| Kube-OVN issue (OVN central crash, IP allocation bug) | upstream `kubeovn/kube-ovn` |
| Cilium issue (CNI not working, kube-proxy replacement broken) | upstream `cilium/cilium` |
| KubeVirt issue (VM not starting, libvirt errors) | upstream `kubevirt/kubevirt` |
| cert-manager issue (Challenge stuck, Issuer wrong) | upstream `cert-manager/cert-manager` |
| Helm or Flux issue (chart not installable, controller stuck) | upstream `helm/helm` / `fluxcd/helm-controller` |

## How to decide between cozystack/cozystack and upstream-upstream

For LINSTOR / Kube-OVN / Cilium / cert-manager — the question is **where the misbehaviour lives**:

- If cozystack's chart values cause the bug (operator follows docs, cozystack values render something wrong upstream gets confused about) → `cozystack/cozystack`. Maintainers there can fix the rendered values.
- If cozystack passes correct values and upstream still misbehaves → upstream-upstream. Include cozystack version + chart version in the body so reviewers know the context.

If unsure, file in `cozystack/cozystack` first. Cozystack maintainers know upstream-upstream code and will redirect or take it on themselves.

## Filing in upstream-upstream

When the issue is in piraeus-operator / LINSTOR / Kube-OVN / Cilium / KubeVirt / cert-manager directly:

- Include cozystack release: `Cozystack v1.3.2 (cozy-installer chart 1.3.2)`.
- Include the upstream version cozystack vendors: read from `packages/<system or apps>/<x>/Chart.yaml` `dependencies[].version` or from the upstream image tag in `values.yaml`.
- Cross-link if you also opened (or are about to open) an issue in `cozystack/cozystack`: "Cross-link: cozystack/cozystack#NNNN".
- Don't open in upstream first and cozystack second. Cozystack maintainers are the operators' first line; they need to know about the issue too even if the fix lives upstream.

## Don't open

- General Kubernetes questions (kubeadm flag X doesn't work) — upstream `kubernetes/kubernetes` is wrong for that volume of churn; ask on the kubernetes slack first.
- "Why doesn't cozystack support X?" without a specific use case — write up the use case first, then a feature request.
- Issues where the bundle reveals private infrastructure that the operator hasn't redacted. Redact first, file second.

## How the skill picks

Phase 5 step 2 reads the symptom record's `classification` + `source.repo` (when set) and matches the table. When `source.repo` is empty but symptom signals point clearly to one repo, the skill proposes that repo and asks the operator to confirm. When signals are mixed (could be cozystack/cozystack or upstream-upstream), the skill asks explicitly.
