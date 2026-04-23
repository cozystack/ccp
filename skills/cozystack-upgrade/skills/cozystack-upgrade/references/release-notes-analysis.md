# Release Notes Analysis

Read this when on Step 1 of the upgrade. The point: turn a pile of release notes into a focused list of post-upgrade checks, one per "heavily changed" area.

## Fetch notes

```bash
# List recent stable releases
gh release list --repo cozystack/cozystack --limit 20

# Fetch specific release notes
gh release view vX.Y.Z --repo cozystack/cozystack

# Or browse: https://github.com/cozystack/cozystack/releases
```

Read **every release between current and target**, not just the target. A patch release can land migrations.

## Change-signal mapping table

When you see this in notes → what it means → check to add in Step 7.

| Signal in release notes | What it means | Post-upgrade check to add |
|---|---|---|
| "Breaking change" / "BREAKING" | Format migration, API shape change | Targeted check of affected resources (see post-upgrade-checks.md) |
| "Migration" | Automatic data/resource rename | Verify old → new rename landed; no orphans |
| "Removed" / "Deprecated" | App or feature gone | Check no references remain; back up data if needed |
| "CRD" changes | New kind or version | `kubectl get crd \| grep <kind>`; `kubectl explain` |
| Component rename (e.g. `mysql`→`mariadb`) | DNS/Service names change | Check workloads using old service DNS |
| Dependency bumps (kamaji, flux, cilium, linstor) | Upstream behavior change | Check those operators' pods + CRDs |
| Tenant chart changes | Every tenant reconciles | All tenant HRs + TenantControlPlanes Ready |
| Chart `values.schema.json` tightening | Existing Package values may fail validation | `kubectl get packages.cozystack.io -A` all Ready |
| Cilium policy changes | Pods may lose connectivity | Inspect `CiliumNetworkPolicies`; check pods with new label requirements |
| Kubernetes version bump in kubernetes chart | Tenant kube-apiserver upgrade path | `TenantControlPlane.status.version == spec.version` |
| Operator RBAC tightening | Operator may fail after upgrade | Check `cozystack-operator` logs post-upgrade |

## Change-risk summary (produce for user)

Synthesize notes into a summary in this format:

```
Upgrading v1.1.1 → v1.2.0

Components with breaking changes:
  - MongoDB: user/database config format restructured → 3 MongoDB CRs in cluster
  - VPC subnets: map → array → 1 VPC affected (tenant-root)

Components heavily changed:
  - kamaji: v0.7 → v0.8 → check tenant control planes after
  - cilium: chart values reshuffled → verify CiliumNetworkPolicies survive

Components removed:
  - FerretDB → no instances running, safe
```

If a release has only bugfixes and dependency patch bumps, say so explicitly — don't hide that nothing needed targeted checks. But still list the releases you reviewed.

## Notes across many releases

For larger jumps (e.g. v1.1.0 → v1.4.0 spanning 10 patches + 3 minors), sort change-risk items by severity (breaking > migration > removal > dependency). Present the top 5–7 items to the user, not an exhaustive dump.
