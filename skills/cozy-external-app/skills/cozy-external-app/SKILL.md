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

## Phase 4 — Gather dependency specification

If `--depends-on` was not passed, use `AskUserQuestion`: "Does this app need any backing services (e.g., postgres, redis, mongodb)? List them or say 'none'."

For each dependency, determine the **integration pattern** via `AskUserQuestion`. Three patterns exist — the recommended default for external apps is **Pattern C**.

### Pattern C — Sibling Cozystack ApplicationDefinition (recommended for external apps)

The app chart creates a **cozystack-level CR** (e.g., `Redis`, `Postgres`, `MariaDB`, `Kafka`) in its own templates. The cozystack controller then reconciles that CR into a HelmRelease which deploys the corresponding `packages/apps/<dep>/` chart — the same chart dashboard users invoke when they deploy Redis/Postgres manually.

Why this is the default for external apps:

- Every sibling instance appears in the dashboard as a first-class entity. A tenant can list, inspect, back up, and restore it independently of the app.
- WorkloadMonitor, PodMonitor, backup schedules, and migration logic shipped by cozystack's own `apps/<dep>/` chart apply automatically — none of that needs to be re-implemented per app.
- Upgrading cozystack itself upgrades the dependency wiring for every consumer at once.

Before collecting spec values, research the sibling ApplicationDefinition (see **Dependency catalog Pattern C** appendix). Each entry records the three facts the app chart needs to wire an instance correctly:

1. **Prefix** — cozystack controller prepends this to the CR name when rendering the downstream HelmRelease. E.g., `Redis/foo` → HelmRelease `redis-foo`.
2. **Credentials Secret name template** — where the downstream chart exposes passwords. E.g., `postgres-{{ .name }}-credentials`, `redis-{{ .name }}-auth`.
3. **Services** — which Service names the downstream chart creates. E.g., `postgres-<name>-rw`, `rfs-redis-<name>`.

These contracts are declared in `packages/system/<dep>-rd/cozyrds/<dep>.yaml` under `spec.secrets.include.resourceNames` and `spec.services.include.resourceNames` — authoritative per cozystack version.

In Phase 7 the app chart emits one Pattern C CR per dependency (template `<dep>.yaml`), mapping chart values onto the CR's spec. The main workload HelmRelease (see Phase 7 Main workload) then references the downstream-emitted Secret via `valuesFrom` and targets the downstream Service via `values`.

Spec parameters to collect depend on the sibling CR's own `openAPISchema`. Common fields:

- `Postgres`: `size`, `replicas`, `users` (map of `<username>: password: <pw>`), `databases` (map of `<dbname>: roles: { admin: [users] }`).
- `Redis`: `size`, `replicas`, `authEnabled` (default `true`), `storageClass`.
- `MariaDB`, `MongoDB`, `Kafka`, `ClickHouse`: consult their ApplicationDefinition under `packages/system/<dep>-rd/cozyrds/<dep>.yaml`.

### Pattern A — In-chart operator CR (system-style)

The app chart creates the operator CR itself (e.g., a CNPG `Cluster` or Spotahome `RedisFailover`) instead of a cozystack-level sibling CR. The app chart owns both the CR and its output Secret. No separate dashboard entity for the dependency.

Use Pattern A only when a Pattern C sibling does not exist for the dependency, or when the app is explicitly system-scoped (like cozystack's own `harbor` or `keycloak`, which predate the sibling-CR pattern). For tenant-facing external apps, prefer Pattern C.

#### Step 1 — Research the dependency (mandatory)

Before asking the user for spec values, consult the **Dependency catalog** (appendix at the bottom of this skill). For each Pattern A dependency, record four facts:

1. **CR identity**: `apiVersion` and `kind` of the resource the chart will create (e.g., `postgresql.cnpg.io/v1 Cluster`, `databases.spotahome.com/v1 RedisFailover`).
2. **Output Secret** — who creates it (operator or chart), its name template, and its keys.
3. **CR ↔ Secret wiring** — whether the CR auto-produces the Secret (CNPG), or the chart must create the Secret and point the CR at it (RedisFailover `auth.secretPath`).
4. **App-side consumption** — env via `secretKeyRef`, volume mount, or config file.

If the dependency is in the catalog, copy its facts into the conversation so later phases can refer to them. If it is not, run the research procedure described in the catalog appendix before proceeding. **Never invent CR shapes, secret names, or secret keys.** When research is inconclusive, stop and ask the user.

#### Step 2 — Collect spec values

The values to collect depend on the CR, not on a generic list. Use the fields exposed by the CR spec as recorded in Step 1. Common groupings:

- postgres (CNPG `Cluster`): database name, database user, replicas (default `2`), storage size (default `5Gi`).
- redis (Spotahome `RedisFailover`): replicas (default `3`), storage size (default `2Gi`), password source (random generated or user-supplied via `values.yaml`).
- mongodb (Percona `PerconaServerMongoDB`): replica-set size, storage size, users to seed.
- Other deps: consult the CR schema captured in Step 1.

#### Step 3 — Collect env mapping

Use the Secret name and keys recorded in Step 1 — not a hardcoded list. For every environment variable the app expects, record which Secret key it maps to. Ask the user to confirm the app's expected env names.

Example for postgres via CNPG (Secret `{{ .Release.Name }}-db-app`, keys `host`, `port`, `username`, `password`, `dbname`):

```yaml
DB_HOST:     secretKeyRef → {{ .Release.Name }}-db-app → host
DB_PORT:     secretKeyRef → {{ .Release.Name }}-db-app → port
DB_USERNAME: secretKeyRef → {{ .Release.Name }}-db-app → username
DB_PASSWORD: secretKeyRef → {{ .Release.Name }}-db-app → password
DB_NAME:     secretKeyRef → {{ .Release.Name }}-db-app → dbname
```

Example for redis via Spotahome (chart-created Secret `{{ .Release.Name }}-redis-auth`, key `password`):

```yaml
REDIS_HOST:     value → rfs-{{ .Release.Name }}-redis     # sentinel service from RedisFailover
REDIS_PORT:     value → "26379"
REDIS_PASSWORD: secretKeyRef → {{ .Release.Name }}-redis-auth → password
```

If the app expects a compound value (`DATABASE_URL`, `REDIS_URL`, etc.), note the assembly pattern — it usually needs a Helm template expression, not a direct `secretKeyRef`.

### Pattern B — External reference

The app expects a pre-existing service. The user provisions it separately (e.g., via the Cozystack dashboard postgres app) and passes connection details as values.

Collect:
- Which values.yaml fields to expose (e.g., `postgres.host`, `postgres.port`, `postgres.secretName`)
- How the app consumes them (env vars, config file mount, etc.)

Present a summary of all dependencies with chosen patterns. Proceed only after user confirms.

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

### Dependency creation templates (Pattern A only)

For each Pattern A dependency recorded in Phase 4, emit one template file under `packages/apps/$APP_NAME/templates/`, named after the dependency (`database.yaml`, `redis.yaml`, `mongodb.yaml`, etc.). Each template must reflect the CR identity and wiring captured during Phase 4 research — do not reuse the postgres pattern for other dependencies.

The `database.yaml` and `redis.yaml` examples below correspond to the catalog entries at the end of this skill. For anything else (mongodb, kafka, clickhouse, opensearch, …), open the reference template recorded in Phase 4 and mirror its structure; do not invent spec fields.

#### database.yaml — postgres via CloudNativePG

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

#### redis.yaml — redis via Spotahome RedisFailover

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

If an operator was gathered in Phase 5, append the operator namespace:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    cozystack.io/system: "true"
  name: external-$APP_NAME-operator
```

### helmrepositories.yaml

If an operator was gathered in Phase 5, append a `HelmRepository` entry in the operator namespace. The HelmRelease below references it by name without a namespace field, so both must live in the same namespace:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: $OPERATOR_REPO_NAME
  namespace: external-$APP_NAME-operator
spec:
  interval: 5m
  url: $OPERATOR_REPO_URL
  # Uncomment for OCI registries (e.g., ghcr.io):
  # type: oci
```

If `$OPERATOR_REPO_TYPE` is `oci`, set `spec.type: oci` explicitly — standard HTTPS Helm repos omit the field.

### helmreleases.yaml

If an operator was gathered in Phase 5, append a HelmRelease that pulls it from the `HelmRepository` registered above (same namespace, same name alias):

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: $OPERATOR_REPO_NAME
  namespace: external-$APP_NAME-operator
spec:
  interval: 5m
  releaseName: $OPERATOR_REPO_NAME
  targetNamespace: external-$APP_NAME-operator
  chart:
    spec:
      chart: $OPERATOR_CHART_NAME
      sourceRef:
        kind: HelmRepository
        name: $OPERATOR_REPO_NAME
      version: '$OPERATOR_CHART_VERSION'
```

If the operator must wait on another operator (e.g., CNPG) before reconciling, add `spec.dependsOn` here — dependency ordering belongs on user-authored HelmReleases. The application's own HelmRelease is generated by the Cozystack controller from the `ApplicationDefinition` and is not user-writable.

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
- **Dependencies**: for each dependency, state the chosen pattern (A: managed / B: external) and which secrets the app consumes
- **Operator**: created or not, chart source
- **Dashboard**: category, tags, icon status (present / missing)
- **Next steps for the user**:
  1. Review all generated files
  2. Place icon SVG if not yet provided: `packages/apps/$APP_NAME/logos/$APP_NAME.svg`
  3. Run `cd packages/apps/$APP_NAME && make generate` to regenerate CRD after any values.yaml changes
  4. Commit and push — Flux picks up changes via the GitRepository defined in `init.yaml` (default interval: 1m)
  5. Verify in cluster: `kubectl get $APP_PLURAL.$APP_NAME.apps.cozystack.io --all-namespaces`

## Dependency catalog

The skill supports three integration patterns (see Phase 4):

- **Pattern C** — app chart creates a cozystack-level sibling CR (`Postgres`, `Redis`, …). Default for external apps.
- **Pattern A** — app chart creates the operator CR directly (CNPG `Cluster`, Spotahome `RedisFailover`). System-style; rarely appropriate for external apps.
- **Pattern B** — user provides a pre-existing service via values. Unchanged from plain Helm.

Pattern C entries below capture the naming contract that cozystack controllers commit to: the downstream HelmRelease name, the Secret the downstream chart creates, and the Services it exposes. These values are pulled directly from `packages/system/<dep>-rd/cozyrds/<dep>.yaml` — authoritative per cozystack version. If a cozystack upgrade changes a prefix or resourceName pattern, the catalog here must be re-verified.

Pattern A entries record the operator-CR shape for cases where Pattern C is not available or not desired.

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

### Pattern C — other dependencies

For `MariaDB`, `MongoDB`, `Kafka`, `ClickHouse`, `RabbitMQ`, `FoundationDB`, `Qdrant`, `OpenSearch`, `NATS`, `Openbao` — read the corresponding `packages/system/<dep>-rd/cozyrds/<dep>.yaml` and extract:

- `spec.application.kind` — sibling CR kind.
- `spec.release.prefix` — HelmRelease name prefix.
- `spec.secrets.include.resourceNames` — exact Secret naming template (often `<prefix>{{ .name }}-credentials` or similar).
- `spec.services.include.resourceNames` — Service naming templates.

Do not extrapolate from the postgres/redis entries above. Each ApplicationDefinition declares its own naming contract.

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
- **Never** guess a dependency's CR shape, Secret name, or Secret keys. For every Pattern A dependency the research step in Phase 4 is mandatory — use the Dependency catalog appendix first; for anything not in the catalog, open a reference implementation in the cozystack monorepo before writing templates. If research does not yield a verified answer, stop and ask.
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
- Cozystack external apps docs: https://cozystack.io/docs/applications/external/
- Flux HelmRelease spec (dependsOn): https://fluxcd.io/flux/components/helm/helmreleases/
- CloudNativePG Cluster CRD: https://cloudnative-pg.io/documentation/current/cloudnative-pg.v1/
- CNPG bootstrap initdb: https://cloudnative-pg.io/documentation/current/bootstrap/#initdb
- `cozystack/packages/apps/postgres/values.yaml` — reference for cozyvalues-gen annotation style (`@param`, `@typedef`, `@field`, `@enum`, `@section`)
- `cozystack/packages/system/harbor/templates/database.yaml` — reference Pattern A: managed CNPG Cluster in chart templates
- `cozystack/packages/system/keycloak/templates/sts.yaml` (lines 142-168) — reference Pattern A: consuming CNPG secret via secretKeyRef with keys `host`, `port`, `username`, `password`, `dbname`
- `cozystack/packages/apps/harbor/templates/harbor.yaml` (lines 132-141) — reference Pattern A: database connection config with `existingSecret` and `host` pointing to CNPG `-rw` service
