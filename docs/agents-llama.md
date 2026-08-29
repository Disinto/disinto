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
4. **Writes `[agents.dev-qwen]` to the project TOML** with:
   - `base_url`, `model`, `api_key`
   - `roles = ["dev"]`
   - `forge_user = "dev-qwen"`
   - `compact_pct = 60`
   - `poll_interval = 60`
5. **Brings the agent up per backend**:
   - **Compose boxes** (no `nomad` CLI, or no live projects dir): the TOML is
     written to `${FACTORY_ROOT}/projects/` and `docker-compose.yml` is
     regenerated to include the `agents-dev-qwen` service.
   - **Nomad boxes** (`nomad` CLI present **and**
     `/srv/disinto/projects/` exists — the live per-env projects dir #794):
     the TOML is written to `/srv/disinto/projects/` (the directory the jobs
     mount, overridable via `FACTORY_PROJECTS_DIR`) and **no**
     `docker-compose.yml` is written or regenerated. Instead the command
     seeds the bot's Vault KV entry, ensures the `bot-<name>` policy/role,
     renders a `bot-<name>` jobspec, and deploys it with
     `nomad job run -detach`, which returns once the job is registered.
     Confirm the allocation started with `nomad job status bot-<name>`.
     See [Hiring on a Nomad box](#hiring-on-a-nomad-box).

### Anthropic backend agents

For agents that use Anthropic API instead of a local model, omit `--local-model`:

```bash
# Anthropic backend agent (requires ANTHROPIC_API_KEY in environment)
export ANTHROPIC_API_KEY="sk-..."
disinto hire-an-agent dev-claude dev
```

This writes `ANTHROPIC_API_KEY` to `.env` instead of `ANTHROPIC_BASE_URL`.

### Hiring on a Nomad box

On a box running the Nomad backend (detected by the presence of the `nomad`
CLI and the live projects directory `/srv/disinto/projects/`), step 5 above
replaces compose regeneration with a Nomad deploy:

1. **TOML lands in the live directory.** `[agents.<name>]` is written to
   `${FACTORY_PROJECTS_DIR:-/srv/disinto/projects}/<project>.toml` — the
   directory the Nomad jobs mount RO as `factory-projects` (#794). Writing to
   the baked `${FACTORY_ROOT}/projects/` there has no effect, so it is
   deliberately not touched.
2. **Vault KV is seeded.** The bot's token and password are merged into
   `kv/data/disinto/bots/<name>` (`token` + `pass`), which the job's
   `template` stanza renders into `secrets/bots.env` as unprefixed
   `FORGE_TOKEN`/`FORGE_PASS` (the per-user `FORGE_TOKEN_<USER_UPPER>`
   variables in `.env` are still written on both backends).
3. **Policy and role are ensured.** The ACL policy `bot-<name>` (read on
   `kv/data/disinto/bots/<name>`, list+read on its metadata path, read on
   `kv/data/disinto/shared/forge`) and the JWT role `bot-<name>` (bound to
   `nomad_job_id = bot-<name>`, namespace `default`) are upserted, matching
   the jobspec's `vault { role = "bot-<name>" }` stanza.
4. **A per-agent job is deployed.** A jobspec named `bot-<name>` — modeled on
   `nomad/jobs/agents.hcl` (same host volumes, docker driver on
   `disinto/agents:local`, `FORGE_URL` template off the `forgejo` Nomad
   service) — is validated with `nomad job validate` and deployed with
   `nomad job run -detach`, which returns once the job is *registered*, not
   once it is healthy — confirm with `nomad job status bot-<name>`.

If Vault is unreachable at hire time, the command warns and degrades
gracefully: it skips the KV seed and policy/role setup but still deploys the
job. The job then starts with `seed-me` placeholder credentials
(`error_on_missing_key = false`) and its tokens are picked up once you re-run
`disinto hire-an-agent` with Vault up.

Manage the deployed job with the usual Nomad tools:

```bash
nomad status bot-dev-qwen
nomad job stop bot-dev-qwen
```

## Activation and running

On compose boxes, the hired agent service is added to `docker-compose.yml`.
Start the service with `docker compose up -d` (on Nomad boxes the job is
already deployed — see [Hiring on a Nomad box](#hiring-on-a-nomad-box)):

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
- Agents share the llama-server's KV pool. With `--kv-unified` the budget is
  the **sum of all concurrent sessions** against one pool sized by `--ctx-size`
  (not a per-slot cap); size each agent's autocompact lane so the sum leaves
  headroom (AD-002, #1069).

## Autocompact window (#1069)

`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` is a percentage of the context window
Claude Code *believes* the model has — resolved from the **model name**
(200,000 tokens for `unsloth/Qwen3.8-27B`), **not** the llama-server's real
`n_ctx`.

That believed window comes from the model name and **cannot be raised** by
`CLAUDE_CODE_AUTO_COMPACT_WINDOW`: the variable can only clamp the belief
*downward* (`K = Math.min(K, z)` in Claude Code's window-resolution code), so
any value above the believed window is a no-op. Pin it to the believed window
(200000) to make that explicit.

The percentage is applied to the *usable* window, not the raw believed window:
Claude Code reserves a 20k output budget out of the believed window
(`usable = min(believed, AUTO_COMPACT_WINDOW) − 20k` in the CLI's window code),
so the percentage acts on `believed − 20k`. Thus `50` gives a ~90k compaction
threshold on the 200k believed window (50% of (200k − 20k) = 90k). To get a
wider compaction lane, lower the percentage.

When the server runs with `--kv-unified`, the context budget is the **sum of
all concurrent sessions** against one shared KV pool, not a per-slot cap:
`--parallel` slots do not each get their own context window. Size each
agent's lane (percentage × usable window) so the combined concurrent
usage leaves headroom in the pool for other consumers on the host.

## Per-env config on Nomad boxes (#794)

Under the Nomad backend, per-env factory project TOMLs live at
`/srv/disinto/projects/` on the host, mounted RO into agent containers
as the `factory-projects` host_volume. Edit the TOML on the host and
restart the agent job — no image rebuild needed:

```bash
sudo $EDITOR /srv/disinto/projects/disinto.toml
nomad job restart agents
nomad job restart agents-supervisor-opus
nomad job restart agents-dev-qwen
nomad job restart agents-review-qwen
```

If you are coming from a pre-#794 box that kept TOMLs at
`/opt/disinto/projects/`, see `docs/nomad-migration.md` for the
one-time `cp` migration.

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
