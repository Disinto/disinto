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

# Optional research-run fields (#1296)
image = "disinto/agents"            # container image for the run (default when absent: disinto/agents)
host = "nomad-box-1"                # alias from RESOURCES.md — resolved by run-experiment.sh (#1308)
artifacts = ["results/*.csv"]       # string or array of strings; copied into ops/artifacts/<action-id>/ after the run (#1308)
resource_class = "gpu"              # cpu | gpu | meep | voxel
```

## Field Specifications

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier for the vault action. Format: `<action-type>-<date>` (e.g., `publish-skill-20260331`) |
| `formula` | string | Formula name from `formulas/` directory that defines the operational task to execute |
| `context` | string | Human-readable explanation of why this action is needed. Used in PR description. For the `run-experiment` formula it doubles as the argv line executed inside the container, e.g. `context = "echo ok"` (#1308) |
| `secrets` | array of strings | List of secret names to inject into the execution environment. Only these secrets are passed to the container |

### Optional Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `mounts` | array of strings | `[]` | Well-known mount aliases for file-based credentials. The dispatcher maps each alias to a read-only volume flag |
| `model` | string | `sonnet` | Override the default Claude model for this action |
| `tools` | array of strings | `[]` | MCP tools to enable during execution |
| `timeout_minutes` | integer | `60` | Maximum execution time in minutes |
| `blast_radius` | string | _(from policy.toml)_ | Override blast-radius tier for this invocation. Valid values: `"low"`, `"medium"`, `"high"`. See [docs/BLAST-RADIUS.md](../docs/BLAST-RADIUS.md) |
| `image` | string | `disinto/agents` | Container image for the run. When absent the runner uses `disinto/agents` (#1296) |
| `host` | string | _(unset)_ | Host alias from `RESOURCES.md` (ops repo, then factory). For the `run-experiment` formula, resolved by `formulas/run-experiment.sh` (#1308): `host` when set, else the first `resource_class` fit, else local dispatch. A missing `RESOURCES.md` or an unresolvable alias is a **failed run** (ledger row with non-zero exit) — never a hang |
| `artifacts` | string or array of strings | _(unset)_ | Glob(s) `run-experiment.sh` copies into `ops/artifacts/<action-id>/` after the run (#1308). Accepts `artifacts = "*.csv"` or `artifacts = ["a/*.csv", "b.md"]` (#1296) |
| `resource_class` | string | _(unset)_ | Resource class for the run. Valid values: `"cpu"`, `"gpu"`, `"meep"`, `"voxel"` — any other value fails validation (#1296) |

## Dispatch behaviour (`image` and `artifacts`, #1307)

How the dispatcher consumes the optional research-run fields:

- **`image`** is passed through to the runner as-is. When the action
  omits it, the dispatcher applies the per-backend agents-image default:
  `disinto/agents:local` (Nomad backend — dispatch meta `image`, which
  the `vault-runner` jobspec interpolates into the task `image`) or
  `disinto/agents:latest` (Docker backend). The dispatcher never picks a
  host — for the `run-experiment` formula, host resolution happens inside
  the formula (`formulas/run-experiment.sh`, #1308: `host` alias via
  `RESOURCES.md`, else first `resource_class` fit, else local); for other
  formulas `host`/`resource_class` remain validated-only.
- **`artifacts`** globs are exposed to the runner as
  `ARTIFACTS_GLOB` (comma-joined; empty when the action declares none),
  alongside `ARTIFACTS_DIR=/artifacts`. The runner task gets a
  **writeable** artifacts volume mounted at `/artifacts` — a Nomad host
  volume (`vault-artifacts`, `/srv/disinto/vault-artifacts`) or a
  per-action Docker bind under
  `${VAULT_ARTIFACTS_DIR:-/var/lib/disinto/vault-artifacts}/<action-id>/`.
  Runs write their outputs there.
- **Collection is not the dispatcher's job**: copying the globbed files
  into `ops/artifacts/<action-id>/` is run-experiment.sh's job
  (#1308). The dispatcher only provides the writeable mount and passes
  the globs through.

## Secret Names

Secret names must have a corresponding `secrets/<NAME>.enc` file (age-encrypted). The vault validates that requested secrets exist in the allowlist before execution.

Common secret names:
- `CLAWHUB_TOKEN` - Token for ClawHub skill publishing
- `GITHUB_TOKEN` - GitHub API token for repository operations
- `DEPLOY_KEY` - Infrastructure deployment key (env var; git remotes)
- `SSH_KEY` - SSH private key, injected as a 0400 file (`/secrets/ssh/id_ed25519` → `~/.ssh/id_ed25519`). Never an env var.
- `SSH_KNOWN_HOSTS` - known_hosts bundle paired with `SSH_KEY` (`/secrets/ssh/known_hosts`)

`SSH_KEY` / `SSH_KNOWN_HOSTS` are the vault-held replacement for bind-mounting the host's `~/.ssh`. Prefer `secrets = ["SSH_KEY", "SSH_KNOWN_HOSTS"]` over `mounts = ["ssh"]`. If both are set, the vault files win and the host bind is skipped.

## Mount Aliases

Mount aliases map to read-only volume flags passed to the runner container:

| Alias | Maps to |
|-------|---------|
| `ssh` | Docker-legacy: host `~/.ssh` bind. Ignored when the action also declares `SSH_KEY` (vault file wins). Prefer `secrets = ["SSH_KEY"]`. |
| `gpg` | `-v ${HOME}/.gnupg:/home/agent/.gnupg:ro` |
| `sops` | `-v ${HOME}/.config/sops/age:/home/agent/.config/sops/age:ro` |

## Validation Rules

1. **Required fields**: `id`, `formula`, `context`, and `secrets` must be present
2. **Formula validation**: The formula must exist in the `formulas/` directory
3. **Secret validation**: All secrets in the `secrets` array must be in the allowlist
4. **No unknown fields**: The TOML must not contain fields outside the schema
5. **ID uniqueness**: The `id` must be unique across all vault actions
6. **resource_class validation**: When present, `resource_class` must be one of `cpu`, `gpu`, `meep`, `voxel` (#1296)

## Example Files

See `action-vault/examples/` for complete examples:
- `webhook-call.toml` - Example of calling an external webhook
- `promote.toml` - Example of promoting a build/artifact
- `publish.toml` - Example of publishing a skill to ClawHub
- `run-experiment.toml` - Example of a research-run action using the optional `image`, `host`, `artifacts`, and `resource_class` fields (#1296; mechanical SSH/image dispatch in #1308)

## Usage

Validate a vault action file:

```bash
./action-vault/validate.sh vault/actions/<action-id>.toml
```

The validator will check:
- All required fields are present
- Secret names are in the allowlist
- No unknown fields are present
- Formula exists in the formulas directory
- `resource_class` (when present) is one of `cpu`, `gpu`, `meep`, `voxel`
