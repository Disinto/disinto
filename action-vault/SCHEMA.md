# Vault Action TOML Schema

This document defines the schema for vault action TOML files used in the PR-based approval workflow (issue #74).

## File Location

Vault actions are stored in `vault/actions/<action-id>.toml` on the ops repo.

## Schema Definition

```toml
# Required
id = "publish-skill-20260331"
formula = "clawhub-publish"
context = "SKILL.md bumped to 0.3.0"

# Required secrets to inject (env vars)
secrets = ["CLAWHUB_TOKEN"]

# Optional file-based credential mounts
mounts = ["ssh"]

# Optional
model = "sonnet"
tools = ["clawhub"]
timeout_minutes = 30
blast_radius = "low"       # optional: overrides policy.toml tier ("low"|"medium"|"high")
```

## Field Specifications

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier for the vault action. Format: `<action-type>-<date>` (e.g., `publish-skill-20260331`) |
| `formula` | string | Formula name from `formulas/` directory that defines the operational task to execute |
| `context` | string | Human-readable explanation of why this action is needed. Used in PR description |
| `secrets` | array of strings | List of secret names to inject into the execution environment. Only these secrets are passed to the container |

### Optional Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `mounts` | array of strings | `[]` | Well-known mount aliases for file-based credentials. The dispatcher maps each alias to a read-only volume flag |
| `model` | string | `sonnet` | Override the default Claude model for this action |
| `tools` | array of strings | `[]` | MCP tools to enable during execution |
| `timeout_minutes` | integer | `60` | Maximum execution time in minutes |
| `blast_radius` | string | _(from policy.toml)_ | Override blast-radius tier for this invocation. Valid values: `"low"`, `"medium"`, `"high"`. See [docs/BLAST-RADIUS.md](../docs/BLAST-RADIUS.md) |

## Secret Names

Secret names must be defined in `.env.vault.enc` on the ops repo. The vault validates that requested secrets exist in the allowlist before execution.

Common secret names:
- `CLAWHUB_TOKEN` - Token for ClawHub skill publishing
- `GITHUB_TOKEN` - GitHub API token for repository operations
- `DEPLOY_KEY` - Infrastructure deployment key

## Mount Aliases

Mount aliases map to read-only volume flags passed to the runner container:

| Alias | Maps to |
|-------|---------|
| `ssh` | `-v ${HOME}/.ssh:/home/agent/.ssh:ro` |
| `gpg` | `-v ${HOME}/.gnupg:/home/agent/.gnupg:ro` |
| `sops` | `-v ${HOME}/.config/sops/age:/home/agent/.config/sops/age:ro` |

## Validation Rules

1. **Required fields**: `id`, `formula`, `context`, and `secrets` must be present
2. **Formula validation**: The formula must exist in the `formulas/` directory
3. **Secret validation**: All secrets in the `secrets` array must be in the allowlist
4. **No unknown fields**: The TOML must not contain fields outside the schema
5. **ID uniqueness**: The `id` must be unique across all vault actions

## Example Files

See `vault/examples/` for complete examples:
- `webhook-call.toml` - Example of calling an external webhook
- `promote.toml` - Example of promoting a build/artifact
- `publish.toml` - Example of publishing a skill to ClawHub

## Usage

Validate a vault action file:

```bash
./vault/validate.sh vault/actions/<action-id>.toml
```

The validator will check:
- All required fields are present
- Secret names are in the allowlist
- No unknown fields are present
- Formula exists in the formulas directory
