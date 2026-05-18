#!/usr/bin/env bash
# Cross-reference validator for the CCP plugin tree.
#
# Catches the class of bug that landed six blockers in one branch-review:
# a string in one file no longer matching reality in another file
# (renamed skill, deleted reference doc, marketplace description out of sync).
#
# Checks performed:
#   1. Every `references/<file>.md` mentioned in a SKILL.md exists on disk.
#   2. Every `/<plugin>:<skill>` or `cozystack:<skill>` / `linstor:<skill>`
#      mention in any SKILL.md or reference doc resolves to a real directory
#      under `plugins/<plugin>/skills/<skill>/`.
#   3. Every plugin's `description` (in both `.claude-plugin/plugin.json` and
#      the matching `plugins[]` entry in `.claude-plugin/marketplace.json`)
#      mentions every skill name that exists under `plugins/<plugin>/skills/`.
#
# Exit code: 0 on success, 1 on any violation.
#
# Run locally before commit, and as a CI gate (.github/workflows/validate.yml).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v jq >/dev/null 2>&1; then
    echo "FATAL: jq is required" >&2
    exit 2
fi

errors=0

err() {
    echo "ERROR: $*" >&2
    errors=$((errors + 1))
}

# ---------------------------------------------------------------- Check 1: references/<file>.md exist
echo "==> Check 1: references/<file>.md mentions resolve"
while IFS= read -r skill_md; do
    skill_dir="$(dirname "$skill_md")"
    # grep references/...md mentions; tolerate backticks and bare; strip trailing .md
    # mentions look like `references/<name>.md` or references/<name>.md
    while IFS= read -r ref; do
        # ref like "references/foo.md"
        target="$skill_dir/$ref"
        if [ ! -f "$target" ]; then
            err "$skill_md references missing file: $ref (looked at $target)"
        fi
    done < <(
        # Match `references/<name>.md` ONLY when preceded by start-of-line,
        # whitespace, backtick, or open-paren — never as a tail of a longer
        # path like `cluster-install/references/foo.md` (that's a cross-skill
        # reference, not a sibling-references claim).
        grep -hoE '(^|[[:space:]`(])references/[a-zA-Z0-9_-]+\.md' "$skill_md" 2>/dev/null \
        | sed -E 's#^[[:space:]`(]##' \
        | sort -u
    )
done < <(find plugins -name SKILL.md -type f)

# ---------------------------------------------------------------- Check 2: plugin:skill mentions resolve
echo "==> Check 2: /<plugin>:<skill> mentions resolve to real directories"

# Build a set of known plugin:skill identifiers from the filesystem.
known_skills=$(mktemp)
trap 'rm -f "$known_skills"' EXIT
for plugin_dir in plugins/*/; do
    plugin=$(basename "$plugin_dir")
    if [ -d "$plugin_dir/skills" ]; then
        for skill_dir in "$plugin_dir"skills/*/; do
            [ -d "$skill_dir" ] || continue
            skill=$(basename "$skill_dir")
            echo "$plugin:$skill" >> "$known_skills"
        done
    fi
done

# Find every plugin:skill mention in any text file under plugins/ and check.
while IFS= read -r mention; do
    if ! grep -Fxq "$mention" "$known_skills"; then
        # Find which file mentioned it (best-effort: first hit).
        offending=$(grep -rlF "$mention" plugins/ README.md CLAUDE.md 2>/dev/null | head -1)
        err "Unknown skill identifier '$mention' (mentioned in ${offending:-?})"
    fi
done < <(
    # Look for /cozystack:..., /linstor:..., bare cozystack:..., linstor:... mentions.
    # Also catch markdown-bold like **cozystack:foo** by stripping ** before grep.
    {
        grep -rhEo '/?(cozystack|linstor):[a-zA-Z0-9_-]+' plugins/ README.md CLAUDE.md 2>/dev/null \
            | sed -E 's#^/##; s#\*+##g' \
            | grep -E '^(cozystack|linstor):' \
            || true
    } | sort -u
)

# ---------------------------------------------------------------- Check 3: descriptions mention every skill
echo "==> Check 3: plugin descriptions list every skill"
for plugin_dir in plugins/*/; do
    plugin=$(basename "$plugin_dir")
    plugin_json="$plugin_dir.claude-plugin/plugin.json"
    [ -f "$plugin_json" ] || continue

    # collect skill names from filesystem
    skills_on_disk=()
    if [ -d "$plugin_dir/skills" ]; then
        while IFS= read -r skill_dir; do
            skills_on_disk+=("$(basename "$skill_dir")")
        done < <(find "$plugin_dir/skills" -mindepth 1 -maxdepth 1 -type d | sort)
    fi
    [ "${#skills_on_disk[@]}" -gt 0 ] || continue

    plugin_desc=$(jq -r '.description' "$plugin_json")
    marketplace_desc=$(jq -r --arg name "$plugin" \
        '.plugins[] | select(.name == $name) | .description' \
        .claude-plugin/marketplace.json)

    for skill in "${skills_on_disk[@]}"; do
        if ! printf '%s' "$plugin_desc" | grep -Fq "$skill"; then
            err "plugin.json for '$plugin' description omits skill '$skill'"
        fi
        if ! printf '%s' "$marketplace_desc" | grep -Fq "$skill"; then
            err "marketplace.json description for plugin '$plugin' omits skill '$skill'"
        fi
    done
done

# ---------------------------------------------------------------- Check 4: kubectl / helm --context discipline
# Every `kubectl ` or `helm ` invocation in any plugins/**/*.md must pass
# --context $CTX (kubectl) or --kube-context $CTX (helm), unless it's
# explicitly context-less (current-context probe, client-version probe,
# auth can-i which is by definition cluster-bound but operator-driven), OR
# the line is tagged `# noverify-context` for genuinely prose mentions.
echo "==> Check 4: kubectl / helm calls pass --context / --kube-context"

# Allow-list: substrings that, when present on the same line, exempt it.
# Most cover non-cluster-bound subcommands (helm repo / pull / show / template /
# lint do not need a kube-context; kubectl config does not target a cluster).
# `--kubeconfig <path>` is an equivalent of `--context` and is allowed too.
declare -a allow_substr=(
    # kubectl non-cluster
    'kubectl config'                  # current-context, get-contexts, use-context
    'kubectl version --client'
    'kubectl auth can-i'              # operator's own auth check, no cluster mutation
    'kubectl krew'                    # plugin install
    'kubectl kc '                     # kubecm plugin
    # kubectl with --kubeconfig (equivalent to --context, allow)
    '--kubeconfig '
    # helm non-cluster subcommands — registry / repo / template-level
    'helm repo '
    'helm search '
    'helm pull '
    'helm push '
    'helm show '
    'helm template '
    'helm lint '
    'helm dep'
    'helm package '
    'helm registry '
    'helm verify '
    'helm version'
    'helm env'
    # explicit per-line override
    'noverify-context'
)

# Helm subcommands that ARE cluster-bound — only flag bare helm for these.
helm_cluster_re='helm (install|upgrade|uninstall|rollback|status|get|list|history|test)( |$)'

while IFS= read -r line_with_path; do
    # path:lineno:content
    file="${line_with_path%%:*}"
    rest="${line_with_path#*:}"
    lineno="${rest%%:*}"
    content="${rest#*:}"

    skip=0
    for allow in "${allow_substr[@]}"; do
        if printf '%s' "$content" | grep -Fq -- "$allow"; then skip=1; break; fi
    done
    [ "$skip" -eq 1 ] && continue

    # kubectl path: any `kubectl` invocation that survived allowlist needs --context
    if printf '%s' "$content" | grep -qE '^[[:space:]]*kubectl '; then
        if ! printf '%s' "$content" | grep -qE -- '--context([^A-Za-z0-9_-]|$)'; then
            err "$file:$lineno bare kubectl without --context: $(printf '%s' "$content" | sed -E 's/^ +//' | cut -c1-100)"
        fi
    fi
    # helm path: only flag cluster-bound subcommands
    if printf '%s' "$content" | grep -qE "$helm_cluster_re"; then
        if ! printf '%s' "$content" | grep -qE -- '--kube-context([^A-Za-z0-9_-]|$)'; then
            err "$file:$lineno bare helm without --kube-context: $(printf '%s' "$content" | sed -E 's/^ +//' | cut -c1-100)"
        fi
    fi
done < <(
    # Only catch actual command invocations — line starts (optionally after
    # whitespace) with `kubectl ` or `helm `. This intentionally ignores:
    #   - inline prose: "`kubectl apply` fails with ..."
    #   - markdown table cells: "| kubectl get nodes | ..."
    #   - comments: "# kubectl get pods"
    #   - shell pipelines on continuation lines (rare; can be tagged with
    #     noverify-context if needed)
    find plugins -name '*.md' -type f -print0 \
        | xargs -0 grep -nE '^[[:space:]]*(kubectl|helm) ' \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
)

# ---------------------------------------------------------------- Check 5: private cluster names denylist
echo "==> Check 5: no private cluster names in plugin / public content"

# Built-in denylist; extensible via CCP_PRIVATE_NAMES (comma-separated).
default_private="dev6,dev9,dev17,instories,homelab"
private_names="${CCP_PRIVATE_NAMES:-$default_private}"

IFS=',' read -ra denylist <<< "$private_names"
for name in "${denylist[@]}"; do
    name="$(echo "$name" | tr -d '[:space:]')"
    [ -z "$name" ] && continue
    # Word-boundary search to avoid substring false positives.
    while IFS= read -r hit; do
        # Skip matches inside the validator itself (where the denylist is
        # defined) — checked by path prefix.
        file="${hit%%:*}"
        case "$file" in
            tools/check-refs.sh) continue ;;
        esac
        err "private cluster name '$name' in $hit"
    done < <(
        find plugins README.md CLAUDE.md -type f \( -name '*.md' -o -name '*.json' \) -print0 2>/dev/null \
            | xargs -0 grep -nE "(^|[^A-Za-z0-9_])${name}([^A-Za-z0-9_]|$)" 2>/dev/null \
            || true
    )
done

# ---------------------------------------------------------------- Result
if [ "$errors" -gt 0 ]; then
    echo ""
    echo "FAIL: $errors cross-reference violation(s)." >&2
    exit 1
fi

echo ""
echo "OK: all cross-references valid."
