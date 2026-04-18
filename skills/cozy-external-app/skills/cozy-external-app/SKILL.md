---
name: cozy-external-app
description: Scaffold a new Cozystack external app package inside an external-apps repository. Generates the full chart skeleton (Chart.yaml, Makefile, values.yaml with cozyvalues-gen annotations, templates), registers it in core/platform (namespace, HelmRelease, CozystackResourceDefinition), and wires dependency integration — supports managed CNPG Postgres clusters provisioned in-chart and external secret references for pre-existing services. Use when adding a new application (e.g. Immich, Gitea, Nextcloud) to an external-apps repo that follows the cozystack/external-apps-example layout.
argument-hint: "<app-name> [--depends-on=postgres,redis] [--operator=<chart-repo-url>] [--repo-dir=<path>]"
---

# cozy-external-app

This skill scaffolds a new Cozystack external app package. It creates all files needed for the app to appear in the Cozystack dashboard and be deployable via the GitOps pipeline (GitRepository → Flux HelmRelease → CozystackResourceDefinition).

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

1. **Repository structure**: verify `$REPO_DIR` contains `init.yaml`, `packages/core/platform/Chart.yaml`, and `scripts/package.mk`. If not, tell the user to `cd` into the external-apps repo root or pass `--repo-dir`.
2. **Tools installed**: check that `yq` (v4), `jq`, `base64`, `helm`, and `cozyvalues-gen` are available via `command -v`. If `cozyvalues-gen` is missing, print:
   ```text
   cozyvalues-gen is required. Install it from:
   https://github.com/cozystack/cozyvalues-gen/releases/latest
   ```
   Do not install it automatically. Stop.
3. **No collision**: verify `packages/apps/$APP_NAME/` does not already exist. If it does, stop and ask the user whether to overwrite or pick a different name.

## Phase 3 — Gather app specification

Use `AskUserQuestion` to collect:

1. **Chart source**: upstream Helm chart (provide repo URL + chart name + version) or custom templates from scratch?
2. **Container image**: image reference (e.g., `ghcr.io/immich-app/immich-server:v1.120.0`).
3. **Public port**: does the app expose an HTTP port? If yes, which port number? Should an Ingress template be generated?
4. **Persistent storage**: does the app need a PVC? If yes, default size (e.g., `10Gi`).
5. **Icon**: path to an SVG file for the dashboard. If not available yet, note it — Phase 6 will create a `logos/` placeholder and Phase 9 will fail until the user provides one.
6. **Dashboard metadata**: Display Name (e.g., `Immich`), Description (e.g., `Self-hosted photo and video management solution`), Category (e.g., `Media`), and Tags (comma-separated list, e.g., `photo, video`).
7. **Resource definition**: Kind (e.g., `Immich`) and Plural (e.g., `immichs`) for the `CozystackResourceDefinition` created in Phase 8.

Record all answers. Proceed only after user confirms the summary.

## Phase 4 — Gather dependency specification

If `--depends-on` was not passed, use `AskUserQuestion`: "Does this app need any backing services (e.g., postgres, redis, mongodb)? List them or say 'none'."

For each dependency, determine the **integration pattern** via `AskUserQuestion`:

### Pattern A — Managed provisioning (recommended for postgres)

The app chart creates the backing service itself (e.g., a CNPG `Cluster` CR in its own templates). The app chart owns the lifecycle.

Collect:
- Database name (default: `app`)
- Database user (default: `app`)
- Number of replicas (default: `2`)
- Storage size (default: `5Gi`)

**CNPG secret convention** (verified from cozystack harbor/keycloak):
- Cluster named `{{ .Release.Name }}-db` creates:
  - Service: `{{ .Release.Name }}-db-rw` (read-write), `{{ .Release.Name }}-db-r` (read-only)
  - Secret: `{{ .Release.Name }}-db-app` with keys: `host`, `port`, `username`, `password`, `dbname`
  - Secret: `{{ .Release.Name }}-db-superuser` with superuser credentials

Collect the env variable mapping for the app container. Defaults:
```yaml
DB_HOST:     secretKeyRef → {{ .Release.Name }}-db-app → host
DB_PORT:     secretKeyRef → {{ .Release.Name }}-db-app → port
DB_USERNAME: secretKeyRef → {{ .Release.Name }}-db-app → username
DB_PASSWORD: secretKeyRef → {{ .Release.Name }}-db-app → password
DB_NAME:     secretKeyRef → {{ .Release.Name }}-db-app → dbname
```

Ask the user if these env names are correct for their app, or if the app expects different names (e.g., `DATABASE_URL`, `PGHOST`, `POSTGRES_PASSWORD`).

### Pattern B — External reference

The app expects a pre-existing service. The user provisions it separately (e.g., via the Cozystack dashboard postgres app) and passes connection details as values.

Collect:
- Which values.yaml fields to expose (e.g., `postgres.host`, `postgres.port`, `postgres.secretName`)
- How the app consumes them (env vars, config file mount, etc.)

Present a summary of all dependencies with chosen patterns. Proceed only after user confirms.

## Phase 5 — Create operator chart (conditional)

Skip if `--operator` was not passed and the app does not need a custom operator.

If an operator is needed, create `packages/system/$APP_NAME-operator/`:

```bash
mkdir -p $REPO_DIR/packages/system/$APP_NAME-operator/charts
```

Create `Chart.yaml`:
```yaml
apiVersion: v2
name: external-$APP_NAME-operator
version: 0.0.0
```

Create `Makefile`:
```makefile
export NAME=$APP_NAME-operator
export NAMESPACE=external-$(NAME)

include ../../../scripts/package.mk

update:
	rm -rf charts
	helm repo add $APP_NAME $OPERATOR_REPO_URL
	helm repo update $APP_NAME
	helm pull $APP_NAME/$OPERATOR_CHART_NAME --untar --untardir charts --version "$OPERATOR_CHART_VERSION"
```

Run the update target to pull the operator chart:
```bash
cd $REPO_DIR/packages/system/$APP_NAME-operator && make update
```

Use `AskUserQuestion` to confirm the operator chart was pulled successfully before proceeding.

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

```makefile
include ../../../scripts/package.mk

generate:
	cozyvalues-gen -v values.yaml -s values.schema.json -r README.md
	../../../hack/update-crd.sh
```

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

Generate the primary workload template. If the user chose "upstream Helm chart", wrap it in a Flux HelmRelease (like harbor does). If "custom templates", create a Deployment or StatefulSet directly.

**For a direct Deployment example:**

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

### database.yaml (Pattern A only)

Create a CNPG Cluster resource. Follow the exact pattern from cozystack `system/harbor/templates/database.yaml`:

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

The CNPG operator automatically creates:
- Secret `{{ .Release.Name }}-db-app` with keys: `host`, `port`, `username`, `password`, `dbname`, `uri`, `jdbc-uri`
- Service `{{ .Release.Name }}-db-rw` (read-write primary)
- Service `{{ .Release.Name }}-db-r` (read replicas)
- Service `{{ .Release.Name }}-db-ro` (read-only replicas)

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

Update three files under `packages/core/platform/templates/`. Read each file first, then append.

### namespaces.yaml

If an operator was created (Phase 5), append:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    cozystack.io/system: "true"
  name: external-$APP_NAME-operator
```

### helmreleases.yaml

If an operator was created, append a HelmRelease for it:

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: $APP_NAME-operator
  namespace: external-$APP_NAME-operator
spec:
  interval: 5m
  targetNamespace: external-$APP_NAME-operator
  chart:
    spec:
      chart: ./packages/system/$APP_NAME-operator
      sourceRef:
        kind: GitRepository
        name: external-apps
        namespace: cozy-public
      version: '*'
```

Verify the `sourceRef.name` matches the GitRepository name in `init.yaml`. Read `init.yaml` to extract it:
```bash
yq -r '.metadata.name' $REPO_DIR/init.yaml | head -1
```

If the app chart itself has a **Pattern A postgres dependency** and an operator is also present, add `spec.dependsOn` to the app's HelmRelease to ensure the operator is ready:

```yaml
spec:
  dependsOn:
  - name: $APP_NAME-operator
    namespace: external-$APP_NAME-operator
```

### cozyrds.yaml

Append a `CozystackResourceDefinition` for the app. The `openAPISchema` must match `values.schema.json` content.

```yaml
---
apiVersion: cozystack.io/v1alpha1
kind: CozystackResourceDefinition
metadata:
  name: $APP_NAME
  namespace: cozy-system
spec:
  application:
    kind: $APP_KIND
    openAPISchema: |
      <contents of values.schema.json>
    plural: $APP_PLURAL
    singular: $APP_NAME
  release:
    chart:
      name: ./packages/apps/$APP_NAME
      sourceRef:
        kind: GitRepository
        name: $GIT_REPO_NAME
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
```

To compute `$ICON_B64`:
```bash
base64 < $REPO_DIR/packages/apps/$APP_NAME/logos/$APP_NAME.svg | tr -d '\n'
```

If `hack/update-crd.sh` exists and is functional, prefer running it instead of manually composing the CRD:
```bash
cd $REPO_DIR/packages/apps/$APP_NAME && make generate
```

This runs `cozyvalues-gen` (regenerates schema + README) and `hack/update-crd.sh` (updates the CozystackResourceDefinition with correct openAPISchema, icon, keysOrder). Check the output path — the script writes to `../../system/cozystack-resource-definitions/cozyrds/$APP_NAME.yaml` by default. If that directory does not exist (it won't in external-apps repos), the script may fail. In that case, manually compose the CRD entry and append it to `packages/core/platform/templates/cozyrds.yaml`.

**Important**: read `hack/update-crd.sh` to check the `$OUT` variable default. If it points to a non-existent path, set `OUT` explicitly:
```bash
OUT=$REPO_DIR/packages/core/platform/templates/cozyrds-$APP_NAME.yaml \
  CRD_DIR="" \
  bash $REPO_DIR/hack/update-crd.sh
```

Or simply append the generated YAML block to `cozyrds.yaml` manually.

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
- **Files modified** (list all modified files: `cozyrds.yaml`, `helmreleases.yaml`, `namespaces.yaml`)
- **Dependencies**: for each dependency, state the chosen pattern (A: managed / B: external) and which secrets the app consumes
- **Operator**: created or not, chart source
- **Dashboard**: category, tags, icon status (present / missing)
- **Next steps for the user**:
  1. Review all generated files
  2. Place icon SVG if not yet provided: `packages/apps/$APP_NAME/logos/$APP_NAME.svg`
  3. Run `cd packages/apps/$APP_NAME && make generate` to regenerate CRD after any values.yaml changes
  4. Commit and push — Flux picks up changes via the GitRepository defined in `init.yaml` (default interval: 1m)
  5. Verify in cluster: `kubectl get $APP_PLURAL.$APP_NAME.apps.cozystack.io --all-namespaces`

## Guardrails

- **Never** commit or push on behalf of the user. This is a generate-only skill.
- **Never** apply anything to a cluster — no `kubectl apply`, no `helm install`, no `make apply`. This skill only creates files.
- **Never** overwrite existing `packages/apps/$APP_NAME/` without explicit user confirmation.
- **Never** guess CNPG secret names or key names. The verified convention is: Cluster `<name>-db` → Secret `<name>-db-app` with keys `host`, `port`, `username`, `password`, `dbname`. If the user's scenario differs (e.g., custom bootstrap, non-standard secret names), stop and ask.
- **Never** edit files in a cozystack checkout used as reference — those are read-only.
- **Never** modify `init.yaml` — the user manages their GitRepository and root HelmRelease manually.
- **Always** use `AskUserQuestion` before creating files in Phase 6, 7, and 8. Show what will be created.
- **Always** read existing files before appending to them (cozyrds.yaml, helmreleases.yaml, namespaces.yaml).
- If `cozyvalues-gen` is not installed, do not attempt to generate schema/README manually beyond a minimal placeholder. Tell the user to install it and re-run `make generate`.
- If `hack/update-crd.sh` output path does not exist, handle gracefully — generate the CRD inline rather than failing silently.

## References

Read these files on demand when reasoning about structure and conventions:

- `packages/core/platform/templates/cozyrds.yaml` — existing CozystackResourceDefinition entries, structure reference
- `packages/core/platform/templates/helmreleases.yaml` — existing HelmRelease entries for operators
- `packages/core/platform/templates/namespaces.yaml` — existing namespace entries
- `hack/update-crd.sh` — how icon base64 encoding, openAPISchema injection, and keysOrder generation work
- `scripts/package.mk` — make targets: `show`, `apply`, `diff`, `suspend`, `resume`, `delete`
- `init.yaml` — GitRepository name and root HelmRelease (needed for sourceRef in CRD and HelmRelease)
- Cozystack external apps docs: https://cozystack.io/docs/applications/external/
- Flux HelmRelease spec (dependsOn): https://fluxcd.io/flux/components/helm/helmreleases/
- CloudNativePG Cluster CRD: https://cloudnative-pg.io/documentation/current/cloudnative-pg.v1/
- CNPG bootstrap initdb: https://cloudnative-pg.io/documentation/current/bootstrap/#initdb
- `cozystack/packages/apps/postgres/values.yaml` — reference for cozyvalues-gen annotation style (`@param`, `@typedef`, `@field`, `@enum`, `@section`)
- `cozystack/packages/system/harbor/templates/database.yaml` — reference Pattern A: managed CNPG Cluster in chart templates
- `cozystack/packages/system/keycloak/templates/sts.yaml` (lines 142-168) — reference Pattern A: consuming CNPG secret via secretKeyRef with keys `host`, `port`, `username`, `password`, `dbname`
- `cozystack/packages/apps/harbor/templates/harbor.yaml` (lines 132-141) — reference Pattern A: database connection config with `existingSecret` and `host` pointing to CNPG `-rw` service
