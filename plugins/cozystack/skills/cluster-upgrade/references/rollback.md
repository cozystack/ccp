# Rollback

Read this before attempting to roll back a Cozystack upgrade. Rollback is possible but has sharp edges — in many cases restoring from backup is safer than rolling back.

## When rollback is reasonable

- The new version doesn't run (operator CrashLoopBackOff, Package validation fails immediately) AND no automatic data-format migration ran.
- You're rolling back between patch versions within the same minor (e.g., v1.2.3 → v1.2.2).

## When rollback is NOT safe

- The release introduced a data-format migration that ran (MongoDB user shape, VPC subnets array, VM `running`→`runStrategy`, etc.). Rolling back leaves new-format data on old code = broken.
- Minor version jumps where schema tightening happened.
- Any case where tenant HRs have already reconciled under new chart values.

In these cases: **restore from backup**, don't roll back.

## Snapshot before rolling back

Always capture current state first:

```bash
mkdir -p pre-rollback-backup
kubectl --context $CTX get packages.cozystack.io -A -o yaml      > pre-rollback-backup/packages.yaml
kubectl --context $CTX get packagesources.cozystack.io -A -o yaml > pre-rollback-backup/packagesources.yaml
kubectl --context $CTX get hr -A -o yaml                          > pre-rollback-backup/helmreleases.yaml
kubectl --context $CTX get configmap -n cozy-system -o yaml       > pre-rollback-backup/cozy-system-cms.yaml
helm --kube-context $CTX history cozystack -n cozy-system              > pre-rollback-backup/helm-history.txt
```

## Rollback commands

```bash
# 1. Identify target revision
helm --kube-context $CTX history cozystack -n cozy-system

# 2. Show user the target revision's chart version + revision number
#    STOP GATE — explicit user approval required

# 3. Rollback
helm --kube-context $CTX rollback cozystack <previous-revision> -n cozy-system

# 4. Monitor operator reconciliation
kubectl --context $CTX logs -n cozy-system deploy/cozystack-operator -f
kubectl --context $CTX get hr -A | grep -v True
```

## Post-rollback verification

Same checks as post-upgrade (see `post-upgrade-checks.md`), with one addition: **compare to pre-upgrade state**.

```bash
# Compare versions
kubectl --context $CTX -n cozy-system get deployment cozystack-operator \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# Should match the previous running version (before the failed upgrade)

# Compare HR count
kubectl --context $CTX get hr -A --no-headers | wc -l
# Should match the pre-upgrade HR count — sudden drop indicates HRs weren't restored
```

## If rollback makes things worse

Stop. Don't roll forward again. Capture current state, surface to user with:
- What upgrade was attempted (versions)
- What rollback did (helm history)
- Current state (HR/Package failures)

Restoring from backup is likely next step.

## Alternative: suspend + freeze

If rollback isn't safe but the new version is only partially broken (e.g. one HR failing), sometimes the right move is:
- `flux suspend hr <name> -n <ns>` on the failing HR to stop reconcile retries.
- Leave the rest of the cluster on the new version.
- Investigate and fix forward, not back.

Discuss with user before choosing this path.
