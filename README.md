# Cozystack Claude Plugins (CCP)

External marketplace repository for Claude Code plugins
for the [Cozystack](https://cozystack.io) ecosystem.

## Installation

Add the marketplace:

```text
/plugin marketplace add cozystack/ccp
```

Install a plugin:

```text
/plugin install <plugin-name>@cozystack-claude-plugins
```

## Plugins

### Skills

| Plugin | Description |
| --- | --- |
| **cozy-deploy** | Deploy a Cozystack package to a dev cluster via make + cozyhr |
| **cozy-external-app** | Scaffold a new Cozystack external app package with dependency integration |
| **drbd-recovery** | Diagnose and recover DRBD/LINSTOR storage issues in Kubernetes clusters |
| **cozystack-upgrade** | Guided upgrade of a running Cozystack v1.x cluster to a newer v1.x patch or minor version |
| **cozy-bump** | Bump a cozystack monorepo package — reads upstream changelog, adapts to breaking changes, regenerates schema, optionally deploys to a dev cluster |

## License

[Apache-2.0](LICENSE)
