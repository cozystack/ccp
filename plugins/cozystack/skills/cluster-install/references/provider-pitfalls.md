# Provider-specific networking and runtime pitfalls

Things that aren't deducible from "all HRs Ready" or from generic Kubernetes docs — they bite during a Cozystack install on specific providers and were each a multi-hour debug episode in a real install run. Cross-reference from SKILL.md Phase 4 (publishing slot) and Phase 5.5 (storage).

## OCI 1:1 NAT — externalIPs must be internal

**Symptom**: every HelmRelease is `Ready=True`, dashboard ingress controller pods are Running, dashboard URL resolves correctly via DNS, but `curl https://dashboard.<host>/` from the workstation returns `Connection refused` (TCP RST) or `Connection reset by peer`. cert-manager challenges sit `pending` because Let's Encrypt validators get the same RST on port 80.

**Mechanism**: Oracle Cloud Infrastructure attaches a public IP to a VM via 1:1 NAT on the OCI virtual network fabric. Packets destined for the public IP are rewritten to the VM's VCN-internal address (`10.X.X.X`) **before** they reach the VM's NIC — the kernel never sees the public IP on any interface. Cilium's `externalIPs` BPF program matches on the packet's destination IP as observed by the host kernel; since the public IP is not present there, the match fails, no NAT rule applies, and the packet falls through to the default `tcp.reset` reply.

**Fix**: set `Service.spec.externalIPs` (and Cozystack's `publishing.externalIPs`) to the VCN-internal IPs of each CP node, not the public IPs. OCI handles the public→internal NAT itself; from the cluster's point of view, the internal IPs are the only addresses that matter.

How `cozystack:cluster-install` Phase 4 catches this:

- Reads `cozystack_intake.external_ips.strategy` from the wizard (default `internal` when `intent_hints.platform: oci`).
- Validates against `Node.status.addresses`: when `InternalIP` ≠ `ExternalIP` on a NAT-fronted platform, refuses the `external` strategy and explains the failure mode.

## OCI: current Talos disk images don't boot from qcow2 — import as streamOptimized VMDK

**Scope note**: Talos node imaging is `cozystack:talos-bootstrap` territory, not `cluster-install`. This lives here as a cross-reference because it bites OCI installs before a cluster ever exists — a non-booting image is discovered as "the whole cluster is dead", not as a node-prep detail.

**Symptom**: a fresh OCI Custom Image built from a Talos `nocloud`/metal `qcow2` (Talos 1.11.5+) never comes up. With UEFI firmware the instance drops to the UEFI shell; with BIOS firmware the serial console stays empty; the Talos API (`:50000`) never answers, so `talm`/`talosctl` time out. Tracked upstream as siderolabs/talos#12557.

**Mechanism**: OCI's qcow2 import path produces a disk the instance firmware won't boot for current Talos images. The same Talos disk boots fine when imported in a different container format.

**Fix**: convert the identical Talos disk to a **streamOptimized VMDK** and import it with `--source-image-type VMDK`, launch profile firmware **BIOS**:

```bash
# Produce a streamOptimized VMDK from the Talos raw/qcow2 disk.
qemu-img convert -O vmdk -o subformat=streamOptimized \
  talos-oci.raw talos-oci.vmdk
# Upload to object storage, then:
#   oci compute image import from-object ... --source-image-type VMDK
# and launch instances with the BIOS launch mode (not UEFI).
```

**Practice — verify BOOT before recreating the cluster**: import + launch the new image on a single throwaway instance and confirm the serial console shows a Linux boot line and `enabling system extension schematic <id>` BEFORE wiring the image into IaC and recreating every node. A non-booting image discovered after a full recreate is a far longer outage than a one-instance smoke test.

## GCP NAT'd external IPs

**Symptom**: same as OCI — `Ready=True`, dashboard unreachable, RST/timeout.

**Mechanism**: GCP VMs reached via Cloud NAT or alias IP mappings exhibit the same 1:1 NAT behaviour as OCI. Public IPs from `--external-ip` or via Cloud NAT egress are translated to the VM's internal IP before delivery; same Cilium-externalIPs miss.

**Fix**: same as OCI — pick internal IPs for `Service.externalIPs`. Phase 4's NAT-provider gate (`intent_hints.platform: gcp-with-nat`) forces internal.

Exception: GCP VMs with a directly-attached public ephemeral IP (not via Cloud NAT) **may** have the public IP on the interface — verify with `kubectl debug node` + `ip addr show`. When the public IP is present on the host interface, `external` strategy works. When it isn't, use `internal`.

## AWS Elastic IP / NLB Proxy Protocol

**Symptom**: TCP-level connectivity works but the dashboard backend logs every request as coming from the NLB's internal address, breaking RBAC and source-IP-based features. Or: HTTP 502 because the backend sees PROXY-protocol header bytes as garbage HTTP.

**Mechanism**: AWS NLB in proxy-protocol mode prepends a PROXY v1/v2 header to each connection containing the real client IP. Workloads that don't speak proxy-protocol see the header bytes inside the TCP stream and return errors.

**Fix**: either disable proxy-protocol on the NLB and use NLB's internal source-IP preservation (set `service.beta.kubernetes.io/aws-load-balancer-proxy-protocol: ""` to none), or enable proxy-protocol in the ingress controller (ingress-nginx supports it via `use-proxy-protocol: "true"` in its ConfigMap; cozystack's root-ingress-controller does not by default in v1.3.x — out of scope to enable here).

EIP-only (no NLB): direct attachment behaves like a public IP on the interface, so `external` strategy works. Verify with `ip addr show` on the host.

## Talos system-extension binaries unavailable outside `ext-*` namespaces

**Symptom**: `kubectl debug node --image=alpine:3 -- chroot /host zpool create` fails with `relocation error: /lib64/ld-linux-x86-64.so.2: not found` or `/bin/sh: not found`.

**Mechanism**: Talos's host rootfs is musl-statically-linked and contains only the `machined` Go binary at PID 1. System extensions (zfs, drbd, openvswitch userspace) live in dedicated namespaces (`ext-zfs-service`, etc.) with their own glibc rootfs and dependencies. The host rootfs that `kubectl debug ... chroot /host` exposes has neither the glibc loader nor `/bin/sh`.

**Fix**: see SKILL.md Phase 5.5 (Talos path) and `references/storage-backends.md` (Talos privileged DaemonSet bootstrap pattern). Run a privileged Pod from `ubuntu:24.04`, `apt-get install zfsutils-linux`, bind-mount `/dev/zfs` and the target disk, partition manually with `sgdisk`, then `zpool create`.

## Pod Security Admission `baseline` blocks `kubectl debug node`

**Symptom**: `kubectl debug node/<name> --image=... --profile=sysadmin` fails with `pods "node-debugger-..." is forbidden: violates PodSecurity "baseline:v1.28": host namespaces (hostPID=true), hostPath volumes (volume "host-root"), allowPrivilegeEscalation != false (container "container-00")` — on a default `kube-system` or `default` namespace.

**Mechanism**: k8s 1.25+ enforces PodSecurity `baseline` by default on every namespace without an explicit label override. The `sysadmin` profile of `kubectl debug` needs `hostPID`, `hostPath`, and `allowPrivilegeEscalation: true` — all forbidden by `baseline`.

**Fix**: create a dedicated namespace with `pod-security.kubernetes.io/enforce=privileged`:

```bash
kubectl --context $CTX create ns cozy-storage-bootstrap
kubectl --context $CTX label ns cozy-storage-bootstrap \
  pod-security.kubernetes.io/enforce=privileged --overwrite
```

Then run the debug Pod (or any privileged bootstrap workload) in that namespace. Delete the namespace after the bootstrap completes.

## Talos `talosctl reset` leaves user disks intact

**Symptom**: re-installing Cozystack on previously-Cozystack'd Talos nodes: `zpool create` fails with `EBUSY` or silently produces a `DEGRADED` pool. `pvs` shows leftover LVM VG; `dmsetup ls` shows `linstor_data-thinpool-tdata` mappings; `linstor storage-pool list` would have shown them as registered before the reset.

**Mechanism**: `talosctl reset` wipes the system disk (the one in `machine.install.disk`) but **does not** touch user/data disks by default. Previous-install LINSTOR LVM-thin pool state on `/dev/sdb` survives `talosctl reset` even with the maintenance-mode reset profile. dm-thin devices stay mapped, LVM PV signatures stay readable, `zpool create` then either refuses or creates a degraded pool that loses data on the next reboot.

**Fix**: before `zpool create`, wipe explicitly:

```bash
# Inside the privileged bootstrap Pod
vgchange -an                                  # deactivate all LVM VGs
dmsetup ls | grep linstor | awk '{print $1}' | xargs --no-run-if-empty dmsetup remove --force
dd if=/dev/zero of="$DEVICE" bs=1M count=10   # wipe header
sgdisk --zap-all "$DEVICE"
wipefs --all "$DEVICE"
```

The skill's Phase 5.5 step 7 (pre-existing-data check) catches this before `zpool create` and refuses to proceed without operator approval of the wipe.

## Cozystack does not create StorageClasses automatically (v1.3.x and v1.4.2)

**Symptom**: cluster reaches "all HRs Ready", but every stateful tenant workload sits in `Pending: pod has unbound immediate PersistentVolumeClaims`. `kubectl get storageclass` returns no rows.

**Mechanism**: neither the cozy-installer chart nor the Platform Package emits StorageClasses; the operator must apply them by hand after `linstor storage-pool create`. An earlier assumption that v1.4+ exposes `tenants.apps.cozystack.io spec.storageClasses` and auto-creates the classes is **false** — the field is absent from the shipped tenant CRD on v1.4.2 (`kubectl get crd tenants.apps.cozystack.io -o yaml | grep -c storageClass` → `0`) and from the monorepo source through current HEAD, so nothing auto-creates them on v1.4 either.

**Fix**: SKILL.md Phase 8.6 creates `local` (placementCount=1) and `replicated` (placementCount=3, isDefaultClass=true) whenever the live cluster comes up with no StorageClasses. The gate is the live `kubectl get storageclass` check, not a version number, so it self-skips if a future release ever starts creating them.

## Cozystack v1.3.3 `isp-full` bundle does not include Keycloak

**Symptom**: dashboard SSO link fails — operator expected Keycloak admin URL but `cozy-keycloak` namespace is absent.

**Mechanism**: in v1.3.x the `isp-full` overlay does not enable Keycloak; cozystack's dashboard ships its own self-issued OIDC provider (`cozystack-issuer`). Keycloak is opt-in via a separate bundle. v1.4+ may change this.

**Fix**: version-dependent. On v1.3.x the dashboard works without Keycloak via the bundled self-issued OIDC (`cozystack-issuer`); external SSO needs Keycloak layered by hand. On v1.4.x the OIDC-off token-proxy dashboard is broken (`/ping` liveness CrashLoop), so Keycloak/OIDC must be enabled at install for a working web dashboard. On v1.5.0+ the token-proxy was fixed (a `startupProbe` backstop landed in v1.5.0), so `cozystack:cluster-install` installs with OIDC OFF and flips it on after the platform converges (SKILL.md Phase 8) — not at install, because on 1.6.x OIDC-at-install deadlocks the platform behind the root-ingress/dashboard cycle.

## `api.<host>` ingress speaks TCP passthrough, not HTTP

**Symptom**: `curl https://api.<host>/healthz` returns HTTP 401 with a self-signed certificate that browsers reject, even though `dashboard.<host>` returns a valid Let's Encrypt R12 cert.

**Mechanism**: cozystack's `api.<host>` ingress is a TCP passthrough to `kube-apiserver:6443`. apiserver terminates TLS itself with its own PKI (not cert-manager-issued); the ingress controller only forwards the encrypted bytes. The 401 is apiserver's auth challenge — expected. The self-signed cert is apiserver's, also expected.

**Fix**: this is by design — the `api.<host>` endpoint is for `kubectl` consumers, not for browsers. Use the apiserver's own kubeconfig CA bundle, not the public-CA chain. Cozystack docs call this out at "after install, access the cluster with `kubectl --kubeconfig <fetched-kubeconfig>`".

## HelmRelease count varies during install

**Symptom**: Phase 8 watch loop sees 84 HRs at the 1-minute mark, 86 HRs at the 4-minute mark, 88 HRs at the 8-minute mark. An operator who hard-codes "wait for 88 Ready" may declare success at 84/84 before the missing 4 HRs land.

**Mechanism**: cozystack's Platform Package is unfolded incrementally by cozystack-operator as dependencies become available. Some HRs only get created after their prerequisite chart is Ready (cascading dependency graph).

**Fix**: the SKILL.md Phase 8 watch loop polls the HR-not-Ready list dynamically; it does not depend on a fixed expected count. The list-empty condition is the success signal.

## `kubectl exec linstor` from outside the controller pod requires mTLS client cert

**Symptom**: from the workstation, `linstor --controllers linstor+ssl://10.0.0.10:3371 storage-pool list` fails with `SSL handshake failed: peer not authenticated`.

**Mechanism**: LINSTOR speaks mTLS by default in cozystack's deployment. The controller pod's `/etc/linstor/client/` directory has the client certificate; outside the pod, no certificate exists.

**Fix**: always invoke the CLI inside the controller pod via `kubectl exec`:

```bash
kubectl --context $CTX --namespace cozy-linstor exec deploy/linstor-controller -- linstor <args>
```

The Phase 8 storage-pool registration block and `references/storage-backends.md` both use this form throughout.

## HelmRelease cascade warnings ("secret not found", "rolebinding not found")

**Symptom**: in the first 5–10 minutes of Phase 8 watch loop, `kubectl get events` shows warnings about secrets and rolebindings that don't yet exist. Operators reading the events stream see them as errors.

**Mechanism**: cozystack's HelmReleases reconcile in parallel; some declare cross-namespace references (Secret consumers, ServiceAccount tokens) that race against the producing HRs. Flux retries with backoff; the warnings disappear once the producing HR completes.

**Fix**: not a fix — clarify in operator-facing summary. Phase 8 watch-loop output ignores events older than the most recent reconcile attempt. If an operator surfaces a warning, the skill answers "transient cascade — Flux will retry; if still failing after 10 min on the same error, capture diagnostics".
