# Classification decision tree

Phase 3 of `cozystack:debug` places every failure into one of four buckets. The bucket determines what Phase 4 does — local fix, workaround, upstream issue, or refuse — so getting this right matters. Use the signals below to classify; ask the operator when ambiguous rather than guess.

## The four buckets

### operator error

**Signal**: a documented step is missing from the operator's actual state.

Examples:

- `tenants.apps.cozystack.io/root` has `.spec.ingress=false` and the install guide says to patch it to `true` after Platform Package apply.
- `cozystack_create_platform_package: true` was left at the ansible default but the operator wanted `cozystack:cluster-install` to handle Cozystack — they should have set it to `false`.
- Wrong `cozystack.apiServerHost` value — internal vs public IP confused.
- `cluster-domain` not set to `cozy.local` at k8s bootstrap.

**How Phase 4 acts**: print the missing step from the docs verbatim, with the exact command. If the operator approves, run it. Don't open an upstream issue — the docs are correct, the gap is in execution.

### config drift

**Signal**: something on the cluster changed since install that broke a documented invariant. Operator-side change, not a Cozystack bug.

Examples:

- Manual `kubectl edit deployment/cozystack-operator` that removed `--apiserver-port=7445`.
- Third-party operator installed alongside cozystack that grabbed the `kubernetes` service externalIPs.
- `kubectl delete pod -n cozy-keycloak --all` to "fix" something, killing the long-running migration job.
- DNS records edited away from the configured `publishing.host`.

**How Phase 4 acts**: show the divergence (doc-prescribed value vs current value), propose the corrective command, ask approve. After the fix lands, suggest adding the invariant to the operator's runbook. No upstream issue — cozystack didn't drift, the operator did.

### upstream bug

**Signal**: operator followed docs, state matches what docs prescribe, but the system behaves contrary to documented behaviour.

Examples:

- `helm install cozy-installer` succeeds, `cozystack-operator` is Available, but the operator's logs show `panic: nil pointer in Reconcile(): missing field X` — that's a chart or operator bug.
- `LinstorSatelliteConfiguration` shape exactly matches the CRD, but piraeus-operator's reconcile loop never creates the pool entry in LINSTOR. Source code shows the field is read but never passed downstream.
- Dashboard ingress is up, gatekeeper started, but the OIDC discovery request fails with a TLS error against keycloak's own cert. cert-manager Order is Ready. cozystack chart shipped without `--insecure-skip-verify` and there's no values key to enable it.

**How Phase 4 acts**: look up the failure in cozystack source (see `source-search.md`), apply local workaround if known (see `cluster-install/references/known-failures.md`), draft upstream issue with the diagnostic bundle. The classification **must** name a source file:line — "something is wrong somewhere in cozystack" is not enough.

### not-yet-supported

**Signal**: operator is asking the system to do something the docs explicitly say is unsupported, or that's not in the supported matrix.

Examples:

- RHEL 10 / Rocky 10 / Alma 10 — OpenZFS RPMs don't exist for that family yet; cozystack/docs/v1.3/storage/disk-preparation.md only covers ZFS.
- LVM Thin pool on the LINSTOR backend — cozystack documents only ZFS.
- IPv6-only cluster — not in the supported matrix.
- kubeadm with a non-default cluster CIDR overlapping the cozystack `joinCIDR`.

**How Phase 4 acts**: print the relevant doc section that says "not supported" and the link. Offer the operator a supported alternative + the option to file a feature-request issue in `cozystack/cozystack`. No local workaround — by definition there isn't one.

## When ambiguous, ask

Two rounds of bad classification waste more time than one explicit question. If after Phase 2 doc-check the bucket is unclear:

```text
classification — ambiguous

Symptom: <one-line summary>
Doc check: <what doc said> vs <what state shows>

This could be:
  - operator error (you missed step X — likely if you didn't follow the documented order)
  - config drift (something changed after install — likely if the install was working before)
  - upstream bug (cozystack reading the field but never acting on it — would explain the symptom but unusual)

What happened recently on this cluster? (last `kubectl edit`, addon installed, ansible re-run, etc.)
```

The answer almost always disambiguates.

## Class-shaped signals reference

| Symptom | Most likely bucket | Why |
|---|---|---|
| HR `Failing` with `dependency 'X' is not ready` for over 10 min | upstream bug or operator error | If X is a normal HR that just needs time → operator-error (impatience). If X is permanently broken → upstream. |
| Pod `CrashLoopBackOff` immediately after install | config drift or operator error | Almost always something wrong in the operator's values; rarely an upstream bug. |
| `cluster-install` Phase 5.5 `zpool create` fails with `permission denied` | operator error | Talos / Ubuntu nodes have the right tools but operator skipped node prep. |
| `cluster-install` Phase 8 watch loop reaches "all HRs Ready" but never observed the tenants/root CR appearing (patch not applied) | upstream bug | The tenants CRD or the cozystack-operator that creates the root Tenant never landed. Without the Tenant CR the inline patch has nothing to target; downstream tenant-root-ingress workloads never come up. Source check on cozystack-operator + tenants CRD installation order. |
| cert-manager Order pending → certificates not ready | config drift or operator error | DNS misconfigured or port 80 firewalled — Phase 4 question 7 domain gate should have caught this. |
| `cozystack-operator` panics on startup | upstream bug | Operator never reaches the operator's values — definitionally upstream. |
| Storage class `data` exists but PVCs are Pending forever | upstream bug or config drift | Either piraeus-operator stopped reconciling (drift) or pool registration silently failed (upstream). Investigate. |
| `gh issue list` shows an open issue with the same error string | already known | Comment on the existing thread instead of opening a duplicate. |
