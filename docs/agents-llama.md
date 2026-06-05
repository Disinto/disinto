# Local-Model Agents

Local-model agents run the same agent code as the Claude-backed agents, but
connect to a local llama-server (or compatible OpenAI-API endpoint) instead of
the Anthropic API. This document describes the canonical activation flow using
`disinto hire-an-agent` and `[agents.X]` TOML configuration.

> **Note:** The legacy `ENABLE_LLAMA_AGENT=1` env flag has been removed (#846).
> Activation is now done exclusively via `[agents.X]` sections in project TOML.

## Overview

Local-model agents are configured via `[agents.<name>]` sections in
`projects/<project>.toml`. Each agent gets:
- Its own Forgejo bot user with dedicated API token and password
- A dedicated compose service `agents-<name>`
- Isolated credentials stored as `FORGE_TOKEN_<USER_UPPER>` and `FORGE_PASS_<USER_UPPER>` in `.env`

## Prerequisites

- **llama-server** (or compatible OpenAI-API endpoint) running on the host,
  reachable from inside Docker at the URL you will configure.
- A disinto factory already initialized (`disinto init` completed).

## Hiring a local-model agent

Use `disinto hire-an-agent` with `--local-model` to create a bot user and
configure the agent:

```bash
# Hire a local-model agent for the dev role
disinto hire-an-agent dev-qwen dev \
  --local-model http://10.10.10.1:8081 \
  --model unsloth/Qwen3.5-35B-A3B
```

The command performs these steps:

1. **Creates a Forgejo user** `dev-qwen` with a random password
2. **Generates an API token** for the user
3. **Writes credentials to `.env`**:
   - `FORGE_TOKEN_DEV_QWEN` — the API token
   - `FORGE_PASS_DEV_QWEN` — the password
   - `ANTHROPIC_BASE_URL` — the llama endpoint (required by the agent)
4. **Writes `[agents.dev-qwen]` to `projects/<project>.toml`** with:
   - `base_url`, `model`, `api_key`
   - `roles = ["dev"]`
   - `forge_user = "dev-qwen"`
   - `compact_pct = 60`
   - `poll_interval = 60`
5. **Regenerates `docker-compose.yml`** to include the `agents-dev-qwen` service

### Anthropic backend agents

For agents that use Anthropic API instead of a local model, omit `--local-model`:

```bash
# Anthropic backend agent (requires ANTHROPIC_API_KEY in environment)
export ANTHROPIC_API_KEY="sk-..."
disinto hire-an-agent dev-claude dev
```

This writes `ANTHROPIC_API_KEY` to `.env` instead of `ANTHROPIC_BASE_URL`.

## Activation and running

Once hired, the agent service is added to `docker-compose.yml`. Start the
service with `docker compose up -d`:

```bash
# Start all agent services
docker compose up -d

# Start a single named agent service
docker compose up -d agents-dev-qwen

# Start multiple named agent services
docker compose up -d agents-dev-qwen agents-planner
```

### Stopping agents

```bash
# Stop a specific agent service
docker compose down agents-dev-qwen

# Stop all agent services
docker compose down
```

## Credential rotation

Re-running `disinto hire-an-agent <same-name>` with the same parameters rotates
credentials idempotently:

```bash
# Re-hire the same agent to rotate token and password
disinto hire-an-agent dev-qwen dev \
  --local-model http://10.10.10.1:8081 \
  --model unsloth/Qwen3.5-35B-A3B

# The command will:
# 1. Detect the user already exists
# 2. Reset the password to a new random value
# 3. Create a new API token
# 4. Update .env with the new credentials
```

This is the recommended way to rotate agent credentials. The `.env` file is
updated in place, so no manual editing is required.

If you need to manually rotate credentials:
1. Generate a new token in Forgejo admin UI
2. Edit `.env` and replace `FORGE_TOKEN_<USER_UPPER>` and `FORGE_PASS_<USER_UPPER>`
3. Restart the agent service: `docker compose restart agents-<name>`

## Configuration reference

### Environment variables (`.env`)

| Variable | Description | Example |
|----------|-------------|---------|
| `FORGE_TOKEN_<USER_UPPER>` | Forgejo API token for the bot user | `FORGE_TOKEN_DEV_QWEN` |
| `FORGE_PASS_<USER_UPPER>` | Forgejo password for the bot user | `FORGE_PASS_DEV_QWEN` |
| `ANTHROPIC_BASE_URL` | Local llama endpoint (local model agents) | `http://host.docker.internal:8081` |
| `ANTHROPIC_API_KEY` | Anthropic API key (Anthropic backend agents) | `sk-...` |

### Project TOML (`[agents.<name>]` section)

```toml
[agents.dev-qwen]
base_url = "http://10.10.10.1:8081"
model = "unsloth/Qwen3.5-35B-A3B"
api_key = "sk-no-key-required"
roles = ["dev"]
forge_user = "dev-qwen"
compact_pct = 60
poll_interval = 60
```

| Field | Description |
|-------|-------------|
| `base_url` | llama-server endpoint |
| `model` | Model name (for logging/identification) |
| `api_key` | Required by API; set to placeholder for llama |
| `roles` | Agent roles this instance handles |
| `forge_user` | Forgejo bot username |
| `compact_pct` | Context compaction threshold (lower = more aggressive) |
| `poll_interval` | Seconds between polling cycles |

## Behaviour

- Each agent runs with `AGENT_ROLES` set to its configured roles
- `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60` — more aggressive compaction for smaller
  context windows
- Agents serialize on the llama-server's single KV cache (AD-002)

## Troubleshooting

### Agent service not starting

Check that the service was created by `disinto hire-an-agent`:

```bash
docker compose config | grep -A5 "agents-dev-qwen"
```

If the service is missing, re-run `disinto hire-an-agent dev-qwen dev` to
regenerate `docker-compose.yml`.

### Model endpoint unreachable

Verify llama-server is accessible from inside Docker:

```bash
docker compose -f docker-compose.yml exec agents curl -sf http://host.docker.internal:8081/health
```

If using a custom host IP, update `ANTHROPIC_BASE_URL` in `.env`:

```bash
# Update the base URL
sed -i 's|^ANTHROPIC_BASE_URL=.*|ANTHROPIC_BASE_URL=http://192.168.1.100:8081|' .env

# Restart the agent
docker compose restart agents-dev-qwen
```

### Invalid agent name

Agent names must match `^[a-z]([a-z0-9]|-[a-z0-9])*$` (lowercase letters, digits,
hyphens; starts with letter, ends with alphanumeric). Invalid names like
`dev-qwen2` (trailing digit is OK) or `dev--qwen` (consecutive hyphens) will
be rejected.
