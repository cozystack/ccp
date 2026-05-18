# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## What This Is

Cozystack Claude Plugins (CCP) — an external marketplace repository for Claude Code plugins for the Cozystack ecosystem.

## Repository Structure

```text
plugins/
  <plugin-name>/
    .claude-plugin/plugin.json   # plugin metadata
    skills/
      <skill-name>/
        SKILL.md                  # skill spec (frontmatter + workflow)
        references/               # supporting docs the skill reads
.claude-plugin/
  marketplace.json                # registry; lists every plugin + description
tools/
  check-refs.sh                   # cross-reference validator (CI gate)
.github/workflows/
  validate.yml                    # PR validation: jq + check-refs.sh
README.md                          # operator-facing skill catalogue
CLAUDE.md                          # this file — contributor guidance
```

Two plugins ship today:

- `plugins/cozystack/` — platform bundle (10 skills: wizard, talos-bootstrap, talos-reset, ubuntu-bootstrap, cluster-install, debug, cluster-upgrade, package-deploy, package-bump, external-app-create).
- `plugins/linstor/` — storage-recovery (1 skill: recover).

Multi-skill plugin shape: every plugin has one `.claude-plugin/plugin.json` at its root, and one directory per skill under `skills/`. Skills are addressed by Claude Code as `/<plugin>:<skill>` (e.g. `/cozystack:wizard`).

## Adding a New Skill to an Existing Plugin

1. `mkdir plugins/<plugin>/skills/<new-skill>/{references}` (references optional).
2. Write `plugins/<plugin>/skills/<new-skill>/SKILL.md` with YAML frontmatter (`name:`, `description:`, optional `argument-hint:`).
3. Update `plugins/<plugin>/.claude-plugin/plugin.json` `description` to mention the new skill (the cross-reference checker in `tools/check-refs.sh` enforces this).
4. Update `.claude-plugin/marketplace.json` `plugins[].description` for the parent plugin — list every skill the plugin ships.
5. Update `README.md` skills table.
6. `bash tools/check-refs.sh` locally before commit.

## Adding a New Plugin

1. `mkdir -p plugins/<plugin>/{.claude-plugin,skills}`.
2. Write `plugins/<plugin>/.claude-plugin/plugin.json` with `name`, `version`, `description` (mentioning every skill).
3. Add one or more skills per the section above.
4. Register the plugin in `.claude-plugin/marketplace.json` `plugins[]` with `name`, `description`, `source: ./plugins/<plugin>`, `category`.
5. Update `README.md`.
6. `bash tools/check-refs.sh`.

## Cross-reference discipline

The skills lean heavily on each other (`cozystack:wizard` dispatches `cozystack:talos-bootstrap` etc.), and skill bodies reference sibling skills and `references/<file>.md` documents. Stale paths and renamed skill identifiers cause silent breakage — operators type a skill name that no longer exists, or follow a link to a file that's been moved. `tools/check-refs.sh` walks the plugin tree and validates:

- Every `references/<file>.md` mentioned in a SKILL.md exists on disk.
- Every `cozystack:<skill>` / `linstor:<skill>` mention resolves to an actual directory under `plugins/<plugin>/skills/`.
- Every plugin's `description` in `marketplace.json` and in its own `plugin.json` mentions every skill present under `plugins/<plugin>/skills/`.

Run before any commit that touches skill names, references, or descriptions.

## Versioning

`plugin.json` `version` follows semver. Bump:

- patch — text-only fixes (typos, doc cleanup).
- minor — new skills, new features, schema additions.
- major — breaking changes for installed users (renames, removals, layout shifts).
