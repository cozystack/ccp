# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## What This Is

Cozystack Claude Plugins (CCP) — an external marketplace repository for Claude Code
plugins for the Cozystack ecosystem.

## Repository Structure

- **`agents/`** — Agent definitions
- **`skills/`** — Skill definitions (SKILL.md with frontmatter)
- **`mcp/`** — MCP server definitions
- **`hooks/`** — Hook plugins

Registry: `.claude-plugin/marketplace.json`

## Adding a New Plugin

1. Create directory under the appropriate type
2. Add `.claude-plugin/plugin.json` with metadata
3. Add content files (SKILL.md, agent .md, .mcp.json, or hooks.json)
4. Register in `.claude-plugin/marketplace.json`
5. Update README.md
