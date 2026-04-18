---
name: cozy-external-app
description: Scaffold a new Cozystack external app package inside an external-apps repository. Generates the full chart skeleton (Chart.yaml, Makefile, values.yaml with cozyvalues-gen annotations, templates), registers it in core/platform (namespace, HelmRepository, HelmChart, HelmRelease, ApplicationDefinition), and wires dependency integration — supports managed CNPG Postgres clusters provisioned in-chart and external secret references for pre-existing services. Use when adding a new application (e.g. Immich, Gitea, Nextcloud) to an external-apps repo that follows the cozystack/external-apps-example layout.
argument-hint: "<app-name> [--depends-on=postgres,redis] [--operator=<chart-repo-url>] [--repo-dir=<path>]"
---

# cozy-external-app

This skill scaffolds a new Cozystack external app package. It creates all files needed for the app to appear in the Cozystack dashboard and be deployable via the GitOps pipeline (GitRepository → Flux HelmRelease → ApplicationDefinition).

This is a **generate-only** skill. It never applies anything to a cluster, never commits, and never pushes. The user handles git operations themselves.

Work in reasoning mode. Follow the phases in order. When a step fails or is ambiguous, stop and ask — do not guess API shapes or secret names.

Use the phrasing "`cozy-external-app`" (not "the skill") in messages to the user, and state progress at each phase boundary.

## Phase 1 — Parse arguments

`$ARGUMENTS` contains the free-form tail after `/cozy-external-app`. Extract:

- Positional `<app-name>` — lowercase, hyphen-separated (e.g., `immich`, `my-app`). Required.
- `--depends-on=<list>` — comma-separated dependency names (e.g., `postgres`, `redis`). Default: none.
- `--operator=<url>` — Helm chart repository URL for a required operator (e.g., `https://immich-app.github.io/immich-charts`). Default: none.
- `--repo-dir=<path>` — path to the external-apps repository root. Default: current working directory.

If `<app-name>` is missing, use `AskUserQuestion` to ask for it.

## Phase 2 — Pre-flight checks

Bail early if any check fails.

1. **Repository structure**: verify `$REPO_DIR` contains `init.yaml`, `packages/core/platform/Chart.yaml`, `scripts/package.mk`, and the five platform template files `packages/core/platform/templates/{namespaces,helmrepositories,helmreleases,helmcharts,cozyrds}.yaml`. If any are missing, tell the user to `cd` into the external-apps repo root or pass `--repo-dir` — Phase 8 appends to all five.
2. **Tools installed**: check that `yq` (v4), `jq`, `base64`, `helm`, and `cozyvalues-gen` are available via `command -v`. If `cozyvalues-gen` is missing, print:
   ```text
   cozyvalues-gen is required. Install it from:
   https://github.com/cozystack/cozyvalues-gen/releases/latest
   ```
   Do not install it automatically. Stop.
3. **No collision**: verify `packages/apps/$APP_NAME/` does not already exist. If it does, stop and ask the user whether to overwrite or pick a different name.
4. **Cozystack contract resolution source**: Phase 4 Step 2 needs to read `packages/system/<dep>-rd/cozyrds/<dep>.yaml` from cozystack. Detect the best available source in this order and record it as `$COZYSTACK_CONTRACT_SOURCE`:
   - `local` — `$COZYSTACK_REPO` is set and points at a cozystack checkout containing `packages/system/`. Fastest, works offline.
   - `github` — `gh` CLI is authenticated (`gh auth status` succeeds). Resolves against `cozystack/cozystack@main`.
   - `cluster` — `kubectl config current-context` succeeds and the target context is a cozystack cluster. Authoritative for that cluster version; read-only.

   If none is available, warn the user. Phase 4 Pattern C will be unavailable; only Patterns A and B remain.

## Phase 3 — Gather app specification

Use `AskUserQuestion` to collect:

1. **Chart source**: is there a maintained first-party Helm chart for this app (official repo, community-run, appeared on Artifact Hub)?
   - **Default: wrap the upstream chart via Flux `HelmRelease`**. You inherit upgrades, init-jobs, probes, PDBs, ingress templates, and every breaking-change mitigation the upstream maintainers ship. Phase 5 will register its `HelmRepository`; Phase 7 emits the wrapping `HelmRelease`.
   - Fall back to **custom templates** only when no upstream chart exists, the upstream is abandoned, or it conflicts with Cozystack conventions in ways that cannot be overridden via values. Custom templates shift lifecycle ownership onto the skill's user — every upstream CVE must then be tracked by hand.
   - Record `$CHART_SOURCE` as `upstream` or `custom`. If `upstream`, collect repo URL + chart name + version here (feeds Phase 5).
2. **Container image**: image reference (e.g., `ghcr.io/immich-app/immich-server:v1.120.0`).
3. **Public port**: does the app expose an HTTP port? If yes, which port number? Should an Ingress template be generated?
4. **Persistent storage**: does the app need a PVC? If yes, default size (e.g., `10Gi`).
5. **Icon**: path to an SVG file for the dashboard. If not available yet, note it — Phase 6 will create a `logos/` placeholder and Phase 9 will fail until the user provides one.
6. **Dashboard metadata**: Display Name (e.g., `Immich`), Description (e.g., `Self-hosted photo and video management solution`), Category (e.g., `Media`), and Tags (comma-separated list, e.g., `photo, video`).
7. **Resource definition**: Kind (e.g., `Immich`) and Plural (e.g., `immichs`) for the `ApplicationDefinition` created in Phase 8.

Record all answers. Proceed only after user confirms the summary.

## Phase 4 — Resolve and gather dependencies

Dependencies are **discovered from the app itself**, not asked blind. The phase runs in five steps: discover what the app needs, resolve each against a cozystack contract, pick the integration pattern, collect spec values, record wiring. Never skip Steps 1–2 — they are what prevent wrong or invented Secret/Service references.

### Step 1 — Chart requirement analysis

Discover candidate dependencies from the chart itself.

**When `$CHART_SOURCE = upstream`:** pull the upstream chart metadata once and inspect it.

```bash
helm repo add --force-update $SOURCE_REPO_NAME $SOURCE_REPO_URL    # HTTPS repos only
helm show chart   $SOURCE_REPO_NAME/$SOURCE_CHART_NAME --version $SOURCE_CHART_VERSION > /tmp/Chart.yaml
helm show values  $SOURCE_REPO_NAME/$SOURCE_CHART_NAME --version $SOURCE_CHART_VERSION > /tmp/values.yaml
helm show readme  $SOURCE_REPO_NAME/$SOURCE_CHART_NAME --version $SOURCE_CHART_VERSION > /tmp/README.md
```

For OCI sources use `oci://$SOURCE_REPO_URL/$SOURCE_CHART_NAME` directly — `helm show` handles OCI without `repo add`.

Extract three signals:

1. **Declared subcharts** from `Chart.yaml → dependencies[]`. Match names from this vocabulary: `postgresql`, `postgresql-ha`, `mariadb`, `mysql`, `redis`, `redis-cluster`, `valkey`, `mongodb`, `kafka`, `clickhouse`, `rabbitmq`, `memcached`, `nats`, `minio`. Every matched subchart is a candidate dep — note its `enabled` default and which values key disables it (typically `<subchart-alias>.enabled: false`).
2. **Config paths** in `values.yaml`. Recurse and record every path matching these keywords until you reach a leaf with `host`, `hostname`, `url`, `dsn`, `uri`, `password`, `user`, `username`, `database`, `dbname`, `port`: `database`, `db`, `postgres*`, `mysql`, `mariadb`, `cache`, `redis`, `valkey`, `session`, `queue`, `broker`, `mongodb`, `kafka`, `rabbitmq`, `memcached`. These paths are the `targetPath` values the app chart will later inject via `valuesFrom`.
3. **README hints** — maintainers usually call out supported databases ("supports PostgreSQL, MySQL, SQLite") near the top and show sample values for external services. Treat this as narrative context, not definitive — the actual schema in `values.yaml` wins on conflict.

Emit findings in a table:

| Dependency | Signals | Wiring path(s) | Subchart to disable |
| --- | --- | --- | --- |
| postgres | Chart dep `postgresql-ha`; values keys `gitea.config.database.*` | `gitea.config.database.HOST`, `…USER`, `…NAME`, `…PASSWD` | `postgresql-ha.enabled: false` |
| redis | Values keys `gitea.config.cache.*`, `gitea.config.session.*` | `gitea.config.cache.HOST`, `…PASSWORD` | `redis-cluster.enabled: false` |

Present the table to the user via `AskUserQuestion`: "Detected these dependencies from the chart. Add, remove, or mark any as optional?" This is where heuristics can be corrected — the user might know the app can use one of several databases, or that a detected cache is optional.

**When `$CHART_SOURCE = custom`:** there is no chart to introspect. Ask the user directly which backing services the app needs and, for each, which config file / env variable the app reads.

### Step 2 — Contract resolution (per dependency)

For each dependency from Step 1, resolve a `$DEP_CONTRACT` from cozystack. Try these sources in order; stop at the first success:

1. **Local cozystack checkout** — when `$COZYSTACK_REPO` is set (or detectable as a sibling dir of `$REPO_DIR`). Read:

   ```bash
   cat $COZYSTACK_REPO/packages/system/<dep>-rd/cozyrds/<dep>.yaml
   ```

2. **GitHub API** — when `gh` CLI is available. Fetch directly from upstream cozystack:

   ```bash
   gh api repos/cozystack/cozystack/contents/packages/system/<dep>-rd/cozyrds/<dep>.yaml \
     --jq .content | base64 --decode
   ```

3. **Live cluster** — when `kubectl` has a usable context (`kubectl config current-context` succeeds) AND the dep's ApplicationDefinition is installed:

   ```bash
   kubectl get applicationdefinition <dep> --output yaml
   ```

Confirm the current context is the intended cozystack cluster before relying on this source (read-only operation, but still worth double-checking). This source is authoritative for *that specific cluster version* — if sources 1 or 2 disagree, prefer the live source and note the drift to the user.

From the resolved document, extract and record `$DEP_CONTRACT.<field>`:

| Contract field | Source path in the ApplicationDefinition |
| --- | --- |
| `kind` | `spec.application.kind` (`Postgres`, `Redis`, `MariaDB`, …) |
| `plural` | `spec.application.plural` |
| `prefix` | `spec.release.prefix` (`postgres-`, `redis-`, …) |
| `secretTemplates` | `spec.secrets.include[].resourceNames` (list of Go-template strings using `{{ .name }}`) |
| `serviceTemplates` | `spec.services.include[].resourceNames` |
| `specSchema` | `spec.application.openAPISchema` (JSON-parseable; drives Step 4) |
| `apiVersion` | `apiVersion` of the ApplicationDefinition itself (typically `cozystack.io/v1alpha1`) |

If all three sources fail, record Pattern C as **unavailable** for this dependency. The user must install the ApplicationDefinition in the target cluster, provide `$COZYSTACK_REPO`, or fall back to Pattern A or B.

### Step 3 — Integration pattern choice

For each dependency with a resolved `$DEP_CONTRACT`, offer the integration pattern via `AskUserQuestion`. Default is **Pattern C**; Pattern A and Pattern B are opt-ins. Pattern C is unavailable (greyed out) when Step 2 failed.

- **Pattern C — Sibling cozystack ApplicationDefinition (recommended for external apps).** The app chart emits a `${DEP_CONTRACT.kind}` CR; cozystack reconciles it into its own HelmRelease; the app consumes the resulting Secret and Service. See the **Pattern C** subsection below.
- **Pattern A — In-chart operator CR (system-style escape hatch).** The app chart creates the operator CR directly (CNPG `Cluster`, Spotahome `RedisFailover`, etc.). Use when no cozystack ApplicationDefinition exists for the dep or when the app is explicitly system-scoped (harbor/keycloak style). See the **Pattern A** subsection.
- **Pattern B — External reference.** The user provides connection details via values; the app chart provisions nothing. See the **Pattern B** subsection.

### Pattern C — Sibling cozystack ApplicationDefinition

The app chart creates a `${DEP_CONTRACT.kind}` CR (e.g., `Postgres`, `Redis`) inside its own templates. The cozystack controller reconciles that CR into a HelmRelease named `${DEP_CONTRACT.prefix}<cr-name>`, deploying the corresponding `packages/apps/<dep>/` chart — the same chart a tenant invokes through the dashboard.

Why this is the default for external apps:

- The sibling instance shows up in the dashboard as a first-class entity. A tenant can list, inspect, back up, and restore it independently of the wrapping app.
- WorkloadMonitor, PodMonitor, backup schedules, and migrations shipped by cozystack's own `apps/<dep>/` chart apply automatically — none of that needs to be re-implemented per app.
- Upgrading cozystack upgrades the dependency wiring for every consumer at once.

All wiring is driven by `$DEP_CONTRACT` from Step 2 — never hardcode prefixes, secret names, or service names. Phase 7 emits one Pattern C template per dep (`templates/<dep>.yaml`) and wires the main workload HelmRelease's `values` / `valuesFrom` against `$DEP_CONTRACT.secretTemplates` and `$DEP_CONTRACT.serviceTemplates` substituted with the CR's own name.

### Pattern A — In-chart operator CR (system-style)

The app chart creates the operator CR itself (e.g., CNPG `Cluster`, Spotahome `RedisFailover`) and owns both the CR and its output Secret. No separate dashboard entity for the dep. Use when a cozystack ApplicationDefinition for the dep is unavailable, or when the app is explicitly system-scoped (harbor, keycloak). For tenant-facing external apps, prefer Pattern C.

Pattern A still requires research: the operator CR shape and its Secret/Service output convention are operator-specific. The **Pattern A catalog** appendix records the verified shapes for CNPG and Spotahome. For any operator not in that catalog, follow the research procedure in the appendix before writing Phase 7 templates.

### Pattern B — External reference

The app expects a pre-existing service. The user provisions it separately and passes connection details as values — typically `postgres.host`, `postgres.port`, `postgres.secretName`. The app chart does not provision anything. Collect which values.yaml fields to expose and how the app consumes them (env vars, config mount).

### Step 4 — Collect spec values

Drive field selection from `$DEP_CONTRACT.specSchema` (Pattern C) or from the operator CR schema researched for Pattern A — not a hand-picked list. For Pattern C postgres, `specSchema` declares `size`, `replicas`, `users`, `databases`, `external`, `storageClass`, etc.; collect defaults for each the user expects to expose. For Pattern B, the values schema is whatever the user and the app agree on.

### Step 5 — Record wiring mapping

The shape of the wiring record depends on chart source:

- **Upstream chart (`$CHART_SOURCE = upstream`)**: record a list of `{targetPath, source}` entries. `targetPath` is one of the value paths surfaced in Step 1; `source` is either an inline value (e.g., the Service hostname) or a `valuesFrom` reference using `$DEP_CONTRACT.secretTemplates` + the CR's name.

  Example for Gitea + Pattern C postgres (CR named `{{ .Release.Name }}-db`, contract prefix `postgres-`, secret template `postgres-{{ .name }}-credentials`):

  ```yaml
  values:
    gitea:
      config:
        database:
          DB_TYPE: postgres
          HOST: postgres-{{ .Release.Name }}-db-rw:5432   # from $DEP_CONTRACT.serviceTemplates
          NAME: {{ .Values.database.name }}
          USER: {{ .Values.database.user }}
  valuesFrom:
    - kind: Secret
      name: postgres-{{ .Release.Name }}-db-credentials   # from $DEP_CONTRACT.secretTemplates
      valuesKey: {{ .Values.database.user }}              # see Secret key convention per catalog entry
      targetPath: gitea.config.database.PASSWD
  ```

- **Custom chart (`$CHART_SOURCE = custom`)**: record container env entries. `valueFrom.secretKeyRef` targets `$DEP_CONTRACT.secretTemplates` (Pattern C) or the operator's output Secret (Pattern A). Inline values come from services or helm expressions.

Present a single summary table of all dependencies with: name, chosen pattern, resolved kind, resolved secret/service, wiring targets. Proceed only after user confirms.

## Phase 5 — Register upstream Helm chart sources (conditional)

Flux reconciles external Helm charts via the `HelmRepository` resource. Two situations require a `HelmRepository` registration in this phase:

1. **App wraps an upstream Helm chart** (see Phase 3 question 1). Example: Gitea wraps `https://dl.gitea.com/charts`.
2. **App requires a dedicated operator** shipped as a separate chart. Example: `minecraft-operator` from `oci://ghcr.io/lexfrei/charts`.

Skip this phase only if BOTH conditions are false (app uses custom templates AND no dedicated operator).

For each source needed, use `AskUserQuestion` to collect:

- `$SOURCE_ROLE` — `main` (upstream chart for the app itself) or `operator` (dedicated operator chart).
- `$SOURCE_REPO_URL` — repository URL. Prefix with `oci://` for OCI registries, otherwise use plain HTTPS.
- `$SOURCE_REPO_TYPE` — `oci` if the URL starts with `oci://`, otherwise leave empty.
- `$SOURCE_CHART_NAME` — chart name inside the repository (e.g., `gitea`, `minecraft-operator`, `immich`).
- `$SOURCE_CHART_VERSION` — pinned version or semver range (e.g., `12.0.1`, `>=1.0.0`). Avoid `'*'` in production use.
- `$SOURCE_REPO_NAME` — alias used as `HelmRepository.metadata.name`. Default: `$APP_NAME` for `main`, `$APP_NAME-operator` for `operator`.
- `$SOURCE_NAMESPACE` — namespace the `HelmRepository` lives in. Default: `external-$APP_NAME-operator` for operator sources, `external-$APP_NAME` for main sources (the same namespace later hosts any app-scoped HelmRelease).

No files are created in this phase. All source and release resources are written in Phase 8 alongside the other platform resources.

## Phase 6 — Create app chart skeleton

Create `packages/apps/$APP_NAME/` with these files:

### Chart.yaml

```yaml
apiVersion: v2
name: $APP_NAME
description: A Helm chart for $APP_DISPLAY_NAME on Cozystack
type: application
version: 0.0.1
appVersion: "$APP_VERSION"
icon: /logos/$APP_NAME.svg
```

### Makefile

The generated Makefile must export `NAME` and `NAMESPACE` — `scripts/package.mk` has a `check:` target (a dependency of `apply`, `show`, `diff`, `delete`, `suspend`, `resume`) that exits with `env NAME is not set!` when either is empty. `$NAMESPACE` should be the operator namespace when the app depends on one, otherwise use `cozy-system`.

```makefile
export NAME=$APP_NAME
export NAMESPACE=<operator-namespace or cozy-system>

include ../../../scripts/package.mk

generate:
	cozyvalues-gen --values values.yaml --schema values.schema.json --readme README.md
```

The reference `external-apps-example` repo does not ship `hack/update-crd.sh` — that script lives only in the cozystack monorepo. Do not call it from the generated Makefile. The `ApplicationDefinition` entry in `cozyrds.yaml` is composed by hand in Phase 8.

### logos/$APP_NAME.svg

If the user provided an icon path, copy it:
```bash
mkdir -p $REPO_DIR/packages/apps/$APP_NAME/logos
cp $ICON_PATH $REPO_DIR/packages/apps/$APP_NAME/logos/$APP_NAME.svg
```

If no icon was provided, create the `logos/` directory and print:
```text
Place your app icon at packages/apps/$APP_NAME/logos/$APP_NAME.svg before running make generate.
```

### values.yaml

Use cozyvalues-gen annotation format. Follow the exact style from the cozystack postgres chart:

```yaml
##
## @section Common parameters
##

## @param {string} [host] - Hostname for external access.
host: ""

## @param {quantity} size - Persistent Volume Claim size for application data.
size: 10Gi

## @param {string} storageClass - StorageClass used to store the data.
storageClass: ""
```

**For Pattern A (managed postgres) dependencies**, add:

```yaml
##
## @section Database configuration
##

## @typedef {struct} Database - PostgreSQL database configuration (provisioned via CloudNativePG).
## @field {quantity} size - Persistent Volume size for database storage.
## @field {int} replicas - Number of database instances.

## @param {Database} database - PostgreSQL database configuration.
database:
  size: 5Gi
  replicas: 2
```

**For Pattern B (external reference) dependencies**, add:

```yaml
##
## @section External PostgreSQL configuration
##

## @typedef {struct} Postgres - External PostgreSQL connection configuration.
## @field {string} host - PostgreSQL host address.
## @field {int} port - PostgreSQL port.
## @field {string} secretName - Name of the Kubernetes Secret containing credentials (keys: username, password, dbname).

## @param {Postgres} postgres - External PostgreSQL connection configuration.
postgres:
  host: ""
  port: 5432
  secretName: ""
```

### values.schema.json

Generate via:
```bash
cd $REPO_DIR/packages/apps/$APP_NAME && cozyvalues-gen -v values.yaml -s values.schema.json -r README.md
```

If `cozyvalues-gen` fails, write a minimal valid JSON schema manually based on values.yaml fields. Verify with:
```bash
jq . values.schema.json > /dev/null
```

### README.md

Generated by `cozyvalues-gen` in the same command above. If manual, create a parameters table matching the mongodb example format.

### .helmignore

```text
logos/
```

## Phase 7 — Create templates

Create `packages/apps/$APP_NAME/templates/` with the following files.

### Main workload — $APP_NAME.yaml

Generate the primary workload template. If Phase 3 recorded `$CHART_SOURCE = upstream`, emit a Flux `HelmRelease` wrapping the upstream chart — the preferred path. If `$CHART_SOURCE = custom`, emit a `Deployment` (or `StatefulSet`) authored from scratch.

#### Upstream chart wrapper (preferred)

The HelmRelease registered below references the `HelmRepository` created in Phase 8 and injects cozystack-wired connection details via `values` and `valuesFrom`. `valuesFrom` is the cleanest way to pipe a password out of a Secret created by a Pattern C sibling CR (see Phase 4 Pattern C, Dependency catalog appendix) directly into the upstream chart's value path — no Deployment env rewriting required.

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: {{ .Release.Name }}
spec:
  interval: 5m
  chart:
    spec:
      chart: $SOURCE_CHART_NAME
      version: $SOURCE_CHART_VERSION
      sourceRef:
        kind: HelmRepository
        name: $SOURCE_REPO_NAME
        namespace: $SOURCE_NAMESPACE
  # dependsOn ensures sibling cozystack CRs reconcile before this release tries to use their outputs.
  # Reference the generated HelmReleases (named `<dep-prefix><dep-cr-name>`) that cozystack controllers
  # produce from the Pattern C sibling CRs you emit in templates/postgres.yaml, templates/redis.yaml, etc.
  dependsOn:
    - name: postgres-{{ .Release.Name }}-db
      namespace: {{ .Release.Namespace }}
    - name: redis-{{ .Release.Name }}-redis
      namespace: {{ .Release.Namespace }}
  # Disable the upstream chart's bundled subcharts — we provide backing services via Pattern C.
  values:
    postgresql:    { enabled: false }
    postgresql-ha: { enabled: false }
    redis:         { enabled: false }
    redis-cluster: { enabled: false }
    # Hostnames/ports are stable from the cozystack ApplicationDefinition naming convention
    # (postgres-<name>-rw, rfs-redis-<name> — see Dependency catalog Pattern C entries).
    # Username, database name, and port values come from the spec recorded in Phase 4.
    app:
      config:
        database:
          host: postgres-{{ .Release.Name }}-db-rw
          port: 5432
          name: $APP_DB_NAME
          user: $APP_DB_USER
        redis:
          host: rfs-redis-{{ .Release.Name }}-redis
          port: 26379
          sentinelMaster: mymaster
  # Secrets must be read at reconcile time — never inline passwords into values.
  valuesFrom:
    - kind: Secret
      name: postgres-{{ .Release.Name }}-db-credentials
      valuesKey: $APP_DB_USER
      targetPath: app.config.database.password
    - kind: Secret
      name: redis-{{ .Release.Name }}-redis-auth
      valuesKey: password
      targetPath: app.config.redis.password
```

Replace the `app.config.*` value paths with the actual schema of your upstream chart — this example uses a generic layout. Common real-world paths: Gitea uses `gitea.config.database.HOST`/`PASSWD`, Immich uses `immich.env.DB_HOSTNAME`/`DB_PASSWORD`, Nextcloud uses `internalDatabase.*`. Verify against the upstream chart's `values.yaml` before wiring.

The referenced `HelmRepository` must exist in the cluster. Phase 8 registers it using the `$SOURCE_*` variables gathered in Phase 5.

#### Custom Deployment (fallback)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    app: {{ .Release.Name }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
      - name: $APP_NAME
        image: $CONTAINER_IMAGE
        ports:
        - name: http
          containerPort: $APP_PORT
        env:
        # Dependency env vars are added per Phase 4 specification
        resources: {}
```

Add env vars for each dependency based on the pattern chosen in Phase 4.

**For Pattern A (managed postgres) env vars:**

```yaml
        env:
        - name: $DB_HOST_ENV
          valueFrom:
            secretKeyRef:
              name: {{ .Release.Name }}-db-app
              key: host
        - name: $DB_PORT_ENV
          valueFrom:
            secretKeyRef:
              name: {{ .Release.Name }}-db-app
              key: port
        - name: $DB_USERNAME_ENV
          valueFrom:
            secretKeyRef:
              name: {{ .Release.Name }}-db-app
              key: username
        - name: $DB_PASSWORD_ENV
          valueFrom:
            secretKeyRef:
              name: {{ .Release.Name }}-db-app
              key: password
        - name: $DB_NAME_ENV
          valueFrom:
            secretKeyRef:
              name: {{ .Release.Name }}-db-app
              key: dbname
```

**For Pattern B (external reference) env vars:**

```yaml
        env:
        - name: $DB_HOST_ENV
          value: {{ .Values.postgres.host | quote }}
        - name: $DB_PORT_ENV
          value: {{ .Values.postgres.port | quote }}
        - name: $DB_PASSWORD_ENV
          valueFrom:
            secretKeyRef:
              name: {{ .Values.postgres.secretName }}
              key: password
```

### Dependency creation templates (Pattern A and Pattern C)

For each Pattern A or Pattern C dependency recorded in Phase 4, emit one template file under `packages/apps/$APP_NAME/templates/`, named after the dependency (`postgres.yaml`, `redis.yaml`, `mariadb.yaml`, …). Each template must reflect the CR identity and wiring captured during Phase 4 — do not reuse the postgres pattern for other dependencies.

The Pattern C examples below are the preferred shape for external apps; the Pattern A examples (system-style, in-chart operator CR) follow for the escape-hatch case. For Pattern B there is no per-dep template to emit — the app chart merely reads connection values the user supplies.

#### postgres.yaml — Pattern C (cozystack `Postgres` sibling CR)

Reference: `cozystack/packages/system/postgres-rd/cozyrds/postgres.yaml` (authoritative contract), `cozystack/packages/apps/postgres/templates/` (what the downstream chart renders). Pattern C is the cleanest path: the app chart creates one cozystack CR, the controller does the rest.

```yaml
---
apiVersion: apps.cozystack.io/v1alpha1
kind: Postgres
metadata:
  name: {{ .Release.Name }}-db
  namespace: {{ .Release.Namespace }}
spec:
  size: {{ .Values.database.size }}
  replicas: {{ .Values.database.replicas }}
  external: false
  {{- with .Values.storageClass }}
  storageClass: {{ . }}
  {{- end }}
  users:
    {{ .Values.database.user }}:
      password: {{ .Values.database.password | default (randAlphaNum 32) | quote }}
  databases:
    {{ .Values.database.name }}:
      roles:
        admin:
          - {{ .Values.database.user }}
```

Outputs (rendered by the downstream `packages/apps/postgres/` chart):

- Secret `postgres-{{ .Release.Name }}-db-credentials` — one key per user, value is the password.
- Services `postgres-{{ .Release.Name }}-db-rw`, `-r`, `-ro`; port `5432`.

Consume these from the main workload HelmRelease via `values` + `valuesFrom` (see Phase 7 Main workload and Dependency catalog Pattern C appendix).

#### redis.yaml — Pattern C (cozystack `Redis` sibling CR)

```yaml
---
apiVersion: apps.cozystack.io/v1alpha1
kind: Redis
metadata:
  name: {{ .Release.Name }}-redis
  namespace: {{ .Release.Namespace }}
spec:
  size: {{ .Values.redis.size }}
  replicas: {{ .Values.redis.replicas }}
  external: false
  authEnabled: true
  {{- with .Values.storageClass }}
  storageClass: {{ . }}
  {{- end }}
```

Outputs (rendered by the downstream `packages/apps/redis/` chart):

- Secret `redis-{{ .Release.Name }}-redis-auth` — key `password`.
- Sentinel service `rfs-redis-{{ .Release.Name }}-redis` on port `26379`.

#### database.yaml — Pattern A (in-chart CloudNativePG `Cluster`)

Reference: `cozystack/packages/system/harbor/templates/database.yaml`.

```yaml
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {{ .Release.Name }}-db
spec:
  instances: {{ .Values.database.replicas }}
  imageName: ghcr.io/cloudnative-pg/postgresql:17.7-standard-trixie
  storage:
    size: {{ .Values.database.size }}
    {{- with .Values.storageClass }}
    storageClass: {{ . }}
    {{- end }}
  bootstrap:
    initdb:
      database: app
      owner: app
      encoding: UTF8
      localeCollate: en_US.UTF-8
      localeCType: en_US.UTF-8
  monitoring:
    enablePodMonitor: true
  inheritedMetadata:
    labels:
      policy.cozystack.io/allow-to-apiserver: "true"
```

Outputs (auto-created by the CNPG operator; no chart-side Secret):

- Secret `{{ .Release.Name }}-db-app` — keys `host`, `port`, `username`, `password`, `dbname`, `uri`, `jdbc-uri`.
- Services `{{ .Release.Name }}-db-rw` (primary), `-db-r` (read replicas), `-db-ro` (read-only).

#### redis.yaml — Pattern A (in-chart Spotahome `RedisFailover`)

Reference: `cozystack/packages/system/harbor/templates/redis.yaml`.

The chart creates the Secret **before** the CR — the operator reads it via `spec.auth.secretPath`:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ .Release.Name }}-redis-auth
stringData:
  password: {{ .Values.redis.password | quote }}
---
apiVersion: databases.spotahome.com/v1
kind: RedisFailover
metadata:
  name: {{ .Release.Name }}-redis
spec:
  sentinel:
    replicas: 3
  redis:
    replicas: {{ .Values.redis.replicas }}
    storage:
      persistentVolumeClaim:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: {{ .Values.redis.size }}
          {{- with .Values.storageClass }}
          storageClassName: {{ . }}
          {{- end }}
  auth:
    secretPath: {{ .Release.Name }}-redis-auth
```

Outputs:

- Secret `{{ .Release.Name }}-redis-auth` (chart-created) — key `password`.
- Sentinel service `rfs-{{ .Release.Name }}-redis` on port `26379`.

If `.Values.redis.password` is empty, generate a password inline so re-renders are stable — see the [`randAlphaNum`](https://pkg.go.dev/github.com/Masterminds/sprig/v3#hdr-String_Functions) Sprig helper and the `lookup` function to reuse an existing Secret on upgrade.

### service.yaml (if app exposes a port)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
spec:
  type: ClusterIP
  ports:
  - name: http
    port: $APP_PORT
    targetPort: http
  selector:
    app: {{ .Release.Name }}
```

### ingress.yaml (if user requested it)

```yaml
{{- if .Values.host }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}-ingress
spec:
  rules:
  - host: {{ .Values.host }}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: {{ .Release.Name }}
            port:
              name: http
{{- end }}
```

Use `AskUserQuestion` to confirm the generated templates before writing them. Show a summary of what will be created.

## Phase 8 — Register in core/platform

Update five files under `packages/core/platform/templates/`. Read each file first, then append.

Before generating any YAML in this phase, extract the GitRepository name from `init.yaml` — it is referenced as `sourceRef.name` in both the operator HelmRelease and the ApplicationDefinition below:

```bash
GIT_REPO_NAME=$(yq -r '.metadata.name' $REPO_DIR/init.yaml | head -1)
```

If `init.yaml` contains multiple documents, pick the `GitRepository` kind explicitly:

```bash
GIT_REPO_NAME=$(yq -r 'select(.kind == "GitRepository") | .metadata.name' $REPO_DIR/init.yaml | head -1)
```

Stop and ask the user if the extracted value is empty.

### namespaces.yaml

Append one namespace per source role recorded in Phase 5:

- Operator source → `external-$APP_NAME-operator` (hosts both the operator `HelmRelease` and its `HelmRepository`).
- Main source → `external-$APP_NAME` (hosts the `HelmRepository` for the upstream app chart; user instances deployed via the dashboard live in tenant namespaces and reference this `HelmRepository` cross-namespace).

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    cozystack.io/system: "true"
  name: $SOURCE_NAMESPACE
```

Emit one entry for each `$SOURCE_NAMESPACE` gathered (deduplicate if operator and main share a namespace by mistake).

### helmrepositories.yaml

For every source gathered in Phase 5 (operator and/or main), append a `HelmRepository`:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: $SOURCE_REPO_NAME
  namespace: $SOURCE_NAMESPACE
spec:
  interval: 5m
  url: $SOURCE_REPO_URL
  # If $SOURCE_REPO_TYPE is `oci`, uncomment the next line:
  # type: oci
```

### helmreleases.yaml

Only **operator** sources get a platform-level `HelmRelease` here. The main upstream chart (when `$CHART_SOURCE = upstream`) is wrapped by a `HelmRelease` rendered *inside the app chart itself* (Phase 7 Main workload) — one per user-deployed instance — and never appears in `packages/core/platform/templates/helmreleases.yaml`.

For each operator source:

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: $SOURCE_REPO_NAME
  namespace: $SOURCE_NAMESPACE
spec:
  interval: 5m
  releaseName: $SOURCE_REPO_NAME
  targetNamespace: $SOURCE_NAMESPACE
  chart:
    spec:
      chart: $SOURCE_CHART_NAME
      sourceRef:
        kind: HelmRepository
        name: $SOURCE_REPO_NAME
      version: '$SOURCE_CHART_VERSION'
```

If the operator must wait on another operator (e.g., CNPG) before reconciling, add `spec.dependsOn` here — dependency ordering belongs on user-authored `HelmRelease`s. The application's own `HelmRelease` is rendered per user-instance from the app chart; it can declare its own `dependsOn` against sibling cozystack-rendered HelmReleases (see Phase 7 Main workload).

### helmcharts.yaml

Always append a flux `HelmChart` that backs the `ApplicationDefinition.spec.release.chartRef` below. Without this entry the `chartRef` has no source and flux cannot produce the chart artifact:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmChart
metadata:
  name: $GIT_REPO_NAME-$APP_NAME
  namespace: cozy-public
spec:
  interval: 5m
  chart: ./packages/apps/$APP_NAME
  sourceRef:
    kind: GitRepository
    name: $GIT_REPO_NAME
  reconcileStrategy: Revision
```

The `metadata.name` here must match the `release.chartRef.name` in the `ApplicationDefinition` below, and the `metadata.namespace` must match `release.chartRef.namespace` (`cozy-public`, same as the GitRepository in `init.yaml`).

### cozyrds.yaml

Append an `ApplicationDefinition` for the app. The `openAPISchema` must match `values.schema.json` content.

`ApplicationDefinition` is cluster-scoped (`scope: Cluster` in the CRD), so `metadata.namespace` must be omitted. The `release.chartRef` field references the flux `HelmChart` defined in `helmcharts.yaml` above — both must use the same name and namespace (`cozy-public`).

```yaml
---
apiVersion: cozystack.io/v1alpha1
kind: ApplicationDefinition
metadata:
  name: $APP_NAME
spec:
  application:
    kind: $APP_KIND
    openAPISchema: |
      <contents of values.schema.json, indented by 6 spaces so every line sits under the `|` block scalar>
    plural: $APP_PLURAL
    singular: $APP_NAME
  release:
    chartRef:
      kind: HelmChart
      name: $GIT_REPO_NAME-$APP_NAME
      namespace: cozy-public
    labels:
      cozystack.io/ui: "true"
    prefix: $APP_NAME-
  dashboard:
    category: $CATEGORY
    singular: $APP_DISPLAY_NAME
    plural: $APP_DISPLAY_NAME
    description: $APP_DESCRIPTION
    tags:
      - $TAG1
    icon: $ICON_B64
    keysOrder:
      - - apiVersion
      - - kind
      - - metadata
      - - metadata
        - name
      # Append one entry per top-level key in values.yaml, in the order the
      # user should see them in the dashboard form. Example:
      # - - spec
      #   - host
      # - - spec
      #   - size
```

To compute `$ICON_B64`:
```bash
base64 < $REPO_DIR/packages/apps/$APP_NAME/logos/$APP_NAME.svg | tr -d '\n'
```

To produce the correctly indented `openAPISchema` block when composing the CRD inline, prefix every line of `values.schema.json` with six spaces so the JSON becomes a valid child of the `|` literal scalar:

```bash
sed 's/^/      /' $REPO_DIR/packages/apps/$APP_NAME/values.schema.json
```

Verify the final YAML with `yq e '.' cozyrds.yaml > /dev/null` before moving on — an off-by-one indentation silently breaks the schema.

Use `AskUserQuestion` to confirm all core/platform changes before writing. Show the diff of what will be appended to each file.

## Phase 9 — Validation

Run the following checks:

1. **Generate schema and README:**
   ```bash
   cd $REPO_DIR/packages/apps/$APP_NAME && make generate
   ```

2. **Helm template render:**
   ```bash
   cd $REPO_DIR/packages/apps/$APP_NAME && helm template test .
   ```
   Fix any template errors before proceeding.

3. **JSON schema validity:**
   ```bash
   jq . $REPO_DIR/packages/apps/$APP_NAME/values.schema.json > /dev/null
   ```

4. **YAML validity of cozyrds:**
   ```bash
   yq e '.' $REPO_DIR/packages/core/platform/templates/cozyrds.yaml > /dev/null
   ```

5. **Platform chart render:**
   ```bash
   cd $REPO_DIR/packages/core/platform && helm template test .
   ```

If any check fails, fix the issue and re-run. If the fix is not obvious, stop and report the error to the user.

## Phase 10 — Summary

Print a report:

- **App name**: `$APP_NAME`
- **Files created** (list all new files with paths relative to repo root)
- **Files modified** (list all modified files under `packages/core/platform/templates/`: `namespaces.yaml`, `helmrepositories.yaml`, `helmreleases.yaml`, `helmcharts.yaml`, `cozyrds.yaml`)
- **Dependencies**: for each dependency, state the chosen pattern (C: sibling cozystack CR / A: in-chart operator CR / B: external reference) and which Secret/Service the app consumes
- **Chart source**: `upstream` (HelmRelease wrapper; note upstream repo + chart name + version) or `custom` (hand-written Deployment/StatefulSet)
- **Operator**: created or not, chart source
- **Dashboard**: category, tags, icon status (present / missing)
- **Next steps for the user**:
  1. Review all generated files
  2. Place icon SVG if not yet provided: `packages/apps/$APP_NAME/logos/$APP_NAME.svg`
  3. Run `cd packages/apps/$APP_NAME && make generate` to regenerate CRD after any values.yaml changes
  4. Commit and push — Flux picks up changes via the GitRepository defined in `init.yaml` (default interval: 1m)
  5. Verify in cluster: `kubectl get $APP_PLURAL.$APP_NAME.apps.cozystack.io --all-namespaces`

## Dependency catalog

Contracts are **resolved at runtime** in Phase 4 Step 2. This appendix is a reference, not a pre-baked list of supported deps — two worked examples below (postgres, redis) show what a correctly resolved `$DEP_CONTRACT` looks like so the assistant can verify its own parsing and the user can eyeball a familiar case.

For any dependency the skill has not seen before, run Phase 4 Step 2 against cozystack itself. There is no need — and no place — to keep a hand-maintained enumeration of every supported dep; cozystack's `packages/system/<dep>-rd/cozyrds/<dep>.yaml` is the single source of truth.

### Interpreting a resolved contract

An ApplicationDefinition document has this structure (minimal view — see `cozystack.io_applicationdefinitions.yaml` CRD for the full schema):

```yaml
apiVersion: cozystack.io/v1alpha1
kind: ApplicationDefinition
metadata:
  name: <dep>
spec:
  application:
    kind: <KindName>            # → $DEP_CONTRACT.kind
    plural: <plural>            # → $DEP_CONTRACT.plural
    openAPISchema: |            # → $DEP_CONTRACT.specSchema (drives Phase 4 Step 4)
      { ... JSON ... }
  release:
    prefix: <prefix>-            # → $DEP_CONTRACT.prefix
    chartRef: ...
  secrets:
    include:
      - resourceNames:
          - <prefix>{{ .name }}-<suffix>    # → $DEP_CONTRACT.secretTemplates
  services:
    include:
      - resourceNames:
          - <prefix>{{ .name }}-<suffix>    # → $DEP_CONTRACT.serviceTemplates
```

`{{ .name }}` in the resourceNames is the **name of the cozystack-level CR the app chart emits**, not the app's own `.Release.Name`. Concretely: when the app chart emits `${DEP_CONTRACT.kind}/{{ .Release.Name }}-db`, substitute `{{ .name }} = <app-release-name>-db` in every template.

The next two sections show the result of the resolution procedure for postgres and redis — verified against upstream cozystack `main` at the time this skill was written. When a cozystack release changes these contracts, the sections below go stale; trust runtime resolution, not this appendix.

### Pattern C — postgres (cozystack `Postgres`)

| Field | Value |
| --- | --- |
| Sibling CR | `apps.cozystack.io/v1alpha1` → `Postgres` |
| Source of truth | `cozystack/packages/system/postgres-rd/cozyrds/postgres.yaml` |
| Downstream HelmRelease | `postgres-{{ .name }}` (prefix `postgres-` from the ApplicationDefinition) |
| Credentials Secret | `postgres-{{ .name }}-credentials` — keys are the usernames configured in `spec.users.<u>.password`. The key's value is the plaintext password. |
| Services | `postgres-{{ .name }}-rw` (primary), `-r` (read replicas), `-ro` (read-only), `-external-write` (LoadBalancer when `spec.external: true`) |
| Port | `5432` |
| Sibling CR spec essentials | `size`, `replicas`, `users` (map `<username>: {password: ...}`), `databases` (map `<dbname>: {roles: {admin: [...usernames]}}`), `external`, `storageClass` |

Example Pattern C CR (rendered from the app chart's `templates/postgres.yaml`):

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Postgres
metadata:
  name: {{ .Release.Name }}-db
  namespace: {{ .Release.Namespace }}
spec:
  size: {{ .Values.database.size }}
  replicas: {{ .Values.database.replicas }}
  external: false
  users:
    {{ .Values.database.user }}:
      password: {{ .Values.database.password | default (randAlphaNum 32) | quote }}
  databases:
    {{ .Values.database.name }}:
      roles:
        admin:
          - {{ .Values.database.user }}
```

Wiring in the main workload HelmRelease:

```yaml
values:
  app:
    config:
      database:
        host: postgres-{{ .Release.Name }}-db-rw
        port: 5432
        name: {{ .Values.database.name }}
        user: {{ .Values.database.user }}
valuesFrom:
  - kind: Secret
    name: postgres-{{ .Release.Name }}-db-credentials
    valuesKey: {{ .Values.database.user }}
    targetPath: app.config.database.password
```

### Pattern C — redis (cozystack `Redis`)

| Field | Value |
| --- | --- |
| Sibling CR | `apps.cozystack.io/v1alpha1` → `Redis` |
| Source of truth | `cozystack/packages/system/redis-rd/cozyrds/redis.yaml` |
| Downstream HelmRelease | `redis-{{ .name }}` (prefix `redis-`) |
| Credentials Secret | `redis-{{ .name }}-auth` — key `password`. Present only when `spec.authEnabled: true` (default). |
| Services | `rfs-redis-{{ .name }}` (sentinel :26379), `rfrm-redis-{{ .name }}` (master), `rfrs-redis-{{ .name }}` (slaves), `redis-{{ .name }}-external-lb` (LoadBalancer when `spec.external: true`) |
| Sibling CR spec essentials | `size`, `replicas`, `authEnabled`, `external`, `version` (`v8`/`v7`), `storageClass` |

Example Pattern C CR (rendered from the app chart's `templates/redis.yaml`):

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Redis
metadata:
  name: {{ .Release.Name }}-redis
  namespace: {{ .Release.Namespace }}
spec:
  size: {{ .Values.redis.size }}
  replicas: {{ .Values.redis.replicas }}
  external: false
  authEnabled: true
```

Wiring in the main workload HelmRelease:

```yaml
values:
  app:
    config:
      redis:
        host: rfs-redis-{{ .Release.Name }}-redis
        port: 26379
        sentinelMaster: mymaster
valuesFrom:
  - kind: Secret
    name: redis-{{ .Release.Name }}-redis-auth
    valuesKey: password
    targetPath: app.config.redis.password
```

### Pattern A — research procedure (for dependencies not in the Pattern A catalog below)

1. Locate a reference in the cozystack monorepo:

   ```bash
   grep -rlE "kind: (Cluster|RedisFailover|PerconaServerMongoDB|Kafka|ClickHouseInstallation|NATS)" \
     $COZYSTACK_REPO/packages/{apps,system}/*/templates/
   ```

2. Read the CR template and the consumer template (typically the app's main workload). Extract:
   - CR `apiVersion` and `kind`.
   - Whether the operator auto-creates a credentials Secret, or the chart must create one itself.
   - Exact Secret name template and key names.
   - Whether the app wires credentials via `env + secretKeyRef`, a mounted volume, or a config file.
3. Record the findings before proceeding to Phase 7. If research does not yield a verified answer, stop and ask the user — do not invent CR shapes or secret key names.

### postgres — CloudNativePG `Cluster`

| Field | Value |
| --- | --- |
| Operator | CloudNativePG (`cnpg.io`) — provided by `packages/system/cnpg-operator` |
| CR | `postgresql.cnpg.io/v1` → `Cluster` |
| Reference template | `cozystack/packages/system/harbor/templates/database.yaml` |
| Reference consumer | `cozystack/packages/system/keycloak/templates/sts.yaml:142-168` |
| Output Secret | Auto-created by the operator. If cluster is named `<release>-db`, the Secret is `<release>-db-app`. |
| Output Secret keys | `host`, `port`, `username`, `password`, `dbname`, `uri`, `jdbc-uri` |
| Superuser Secret | `<release>-db-superuser` (same keys + `superuser`) |
| Services | `<release>-db-rw` (primary), `<release>-db-r` (read replicas), `<release>-db-ro` (read-only) |
| App wiring | env via `secretKeyRef` to the auto-created Secret |

### redis — Spotahome `RedisFailover`

| Field | Value |
| --- | --- |
| Operator | Spotahome Redis Operator (`databases.spotahome.com`) — provided by `packages/system/redis-operator` |
| CR | `databases.spotahome.com/v1` → `RedisFailover` |
| Reference template | `cozystack/packages/system/harbor/templates/redis.yaml` |
| Output Secret | **Not auto-created** — the chart itself creates a Secret alongside the CR (naming is chart-choice, commonly `<release>-redis-auth` with key `password`). |
| CR ↔ Secret wiring | `spec.auth.secretPath: <secret-name>` — the operator reads the Secret by that name. |
| App wiring | The same Secret is mounted or read via env by the app. The chart generates the password (e.g., from `.Values.redis.password` or a randomly generated one) and stores it in the Secret. |

Unlike CNPG, the Spotahome operator does NOT emit connection details. The chart is responsible for password generation and for wiring the same Secret into both the operator (`auth.secretPath`) and the consuming app.

### mongodb — Percona `PerconaServerMongoDB`

| Field | Value |
| --- | --- |
| Operator | Percona Server for MongoDB (`psmdb.percona.com`) — provided by `packages/system/psmdb-operator` |
| CR | `psmdb.percona.com/v1` → `PerconaServerMongoDB` |
| Reference template | `cozystack/packages/apps/mongodb/templates/mongodb.yaml` |
| Seed Secret | **Chart-created**, referenced via `spec.secrets.users` — the operator reads this for initial user/password seeding. |
| App wiring | Depends on the app — typically a `DATABASE_URL` assembled from the Secret. Verify against the specific app's expected env before wiring. |

### kafka — Strimzi `Kafka`

| Field | Value |
| --- | --- |
| Operator | Strimzi (`kafka.strimzi.io`) |
| CR | `kafka.strimzi.io/v1beta2` → `Kafka` (plus `KafkaUser` for SCRAM/TLS) |
| Reference template | `cozystack/packages/apps/kafka/templates/kafka.yaml` |
| Output Secrets | Brokers expose services. Client credentials are issued per `KafkaUser` CR — Strimzi creates a Secret named `<KafkaUser-name>` with `password` (SCRAM) and/or `user.crt`/`user.key` (TLS). |
| App wiring | SCRAM-SHA-512 via env, or TLS via mounted volume. Consult the KafkaUser status to discover the actual Secret layout. |

## Guardrails

- **Never** commit or push on behalf of the user. This is a generate-only skill.
- **Never** apply anything to a cluster — no `kubectl apply`, no `helm install`, no `make apply`. This skill only creates files.
- **Never** overwrite existing `packages/apps/$APP_NAME/` without explicit user confirmation.
- **Never** skip Phase 4 Step 1 (chart requirement analysis) or Step 2 (contract resolution). Every Pattern C dependency must have a `$DEP_CONTRACT` record with `kind`, `prefix`, `secretTemplates`, `serviceTemplates`, and `specSchema` resolved from a cozystack source before Phase 7 emits any template. No speculation — if resolution fails, Pattern C is unavailable for that dep.
- **Never** guess a dependency's CR shape, Secret name, or Secret keys. For Pattern A deps the operator-CR research step is mandatory — use the Pattern A catalog first; for anything not in the catalog, open a reference implementation in the cozystack monorepo before writing templates. If research does not yield a verified answer, stop and ask.
- **Never** copy the postgres/CNPG wiring onto a different dependency. CNPG auto-creates the credentials Secret; Spotahome RedisFailover does not (the chart creates it). Other operators differ further — always verify.
- **Never** edit files in a cozystack checkout used as reference — those are read-only.
- **Never** modify `init.yaml` — the user manages their GitRepository and root HelmRelease manually.
- **Always** use `AskUserQuestion` before creating files in Phase 6, 7, and 8. Show what will be created.
- **Always** read existing files before appending to them (`namespaces.yaml`, `helmrepositories.yaml`, `helmreleases.yaml`, `helmcharts.yaml`, `cozyrds.yaml`).
- If `cozyvalues-gen` is not installed, do not attempt to generate schema/README manually beyond a minimal placeholder. Tell the user to install it and re-run `make generate`.

## References

Read these files on demand when reasoning about structure and conventions:

- `packages/core/platform/templates/cozyrds.yaml` — existing ApplicationDefinition entries, structure reference
- `packages/core/platform/templates/helmreleases.yaml` — existing HelmRelease entries for operators
- `packages/core/platform/templates/helmrepositories.yaml` — existing HelmRepository entries for operator chart sources
- `packages/core/platform/templates/helmcharts.yaml` — existing HelmChart entries that back each app's `release.chartRef`
- `packages/core/platform/templates/namespaces.yaml` — existing namespace entries
- `scripts/package.mk` — make targets: `show`, `apply`, `diff`, `suspend`, `resume`, `delete`. Requires `NAME` and `NAMESPACE` exports.
- `init.yaml` — GitRepository name and root HelmRelease (needed for sourceRef in CRD and HelmRelease)
- `packages/system/<dep>-rd/cozyrds/<dep>.yaml` — authoritative contract per dep. Resolved at runtime by Phase 4 Step 2 from `$COZYSTACK_REPO`, `gh api repos/cozystack/cozystack`, or `kubectl get applicationdefinition <dep>` in that order.
- Cozystack external apps docs: https://cozystack.io/docs/applications/external/
- Flux HelmRelease spec (dependsOn): https://fluxcd.io/flux/components/helm/helmreleases/
- CloudNativePG Cluster CRD: https://cloudnative-pg.io/documentation/current/cloudnative-pg.v1/
- CNPG bootstrap initdb: https://cloudnative-pg.io/documentation/current/bootstrap/#initdb
- `cozystack/packages/apps/postgres/values.yaml` — reference for cozyvalues-gen annotation style (`@param`, `@typedef`, `@field`, `@enum`, `@section`)
- `cozystack/packages/system/harbor/templates/database.yaml` — reference Pattern A: managed CNPG Cluster in chart templates
- `cozystack/packages/system/keycloak/templates/sts.yaml` (lines 142-168) — reference Pattern A: consuming CNPG secret via secretKeyRef with keys `host`, `port`, `username`, `password`, `dbname`
- `cozystack/packages/apps/harbor/templates/harbor.yaml` (lines 132-141) — reference Pattern A: database connection config with `existingSecret` and `host` pointing to CNPG `-rw` service
