# agents-llama — Local-Qwen Agents

The `agents-llama` service is an optional compose service that runs agents
backed by a local llama-server instance (e.g. Qwen) instead of the Anthropic
API. It uses the same Docker image as the main `agents` service but connects to
a local inference endpoint via `ANTHROPIC_BASE_URL`.

Two profiles are available:

| Profile | Service | Roles | Use case |
|---------|---------|-------|----------|
| _(default)_ | `agents-llama` | `dev` only | Conservative: single-role soak test |
| `agents-llama-all` | `agents-llama-all` | all 7 (review, dev, gardener, architect, planner, predictor, supervisor) | Pre-migration: validate every role on llama before Nomad cutover |

## Enabling

Set `ENABLE_LLAMA_AGENT=1` in `.env` (or `.env.enc`) and provide the required
credentials:

```env
ENABLE_LLAMA_AGENT=1
FORGE_TOKEN_LLAMA=<dev-qwen API token>
FORGE_PASS_LLAMA=<dev-qwen password>
ANTHROPIC_BASE_URL=http://host.docker.internal:8081   # llama-server endpoint
```

Then regenerate the compose file (`disinto init ...`) and bring the stack up.

## Hiring a new agent

Use `disinto hire-an-agent` to create a Forgejo user, API token, and password,
and write all required credentials to `.env`:

```bash
# Local model agent
disinto hire-an-agent dev-qwen dev \
  --local-model http://10.10.10.1:8081 \
  --model unsloth/Qwen3.5-35B-A3B

# Anthropic backend agent (requires ANTHROPIC_API_KEY in environment)
disinto hire-an-agent dev-qwen dev
```

The command writes the following to `.env`:
- `FORGE_TOKEN_<USER_UPPER>` — derived from the agent's Forgejo username (e.g., `FORGE_TOKEN_DEV_QWEN`)
- `FORGE_PASS_<USER_UPPER>` — the agent's Forgejo password
- `ANTHROPIC_BASE_URL` (local model) or `ANTHROPIC_API_KEY` (Anthropic backend)

## Rotation

Re-running `disinto hire-an-agent <same-name>` rotates credentials idempotently:

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

If you need to manually rotate credentials, you can:
1. Generate a new token in Forgejo admin UI
2. Edit `.env` and replace `FORGE_TOKEN_<USER_UPPER>` and `FORGE_PASS_<USER_UPPER>`
3. Restart the agent service: `docker compose restart disinto-agents-<name>`

### Running all 7 roles (agents-llama-all)

```bash
docker compose --profile agents-llama-all up -d
```

This starts the `agents-llama-all` container with all 7 bot roles against the
local llama endpoint. The per-role forge tokens (`FORGE_REVIEW_TOKEN`,
`FORGE_GARDENER_TOKEN`, etc.) must be set in `.env` — they are the same tokens
used by the Claude-backed `agents` container.

## Prerequisites

- **llama-server** (or compatible OpenAI-API endpoint) running on the host,
  reachable from inside Docker at the URL set in `ANTHROPIC_BASE_URL`.
- A Forgejo bot user (e.g. `dev-qwen`) with its own API token and password,
  stored as `FORGE_TOKEN_LLAMA` / `FORGE_PASS_LLAMA`.

## Behaviour

- `agents-llama`: `AGENT_ROLES=dev` — only picks up dev work.
- `agents-llama-all`: `AGENT_ROLES=review,dev,gardener,architect,planner,predictor,supervisor` — runs all 7 roles.
- `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60` — more aggressive compaction for smaller
  context windows.
- Serialises on the llama-server's single KV cache (AD-002).

## Disabling

Set `ENABLE_LLAMA_AGENT=0` (or leave it unset) and regenerate. The service
block is omitted entirely from `docker-compose.yml`; the stack starts cleanly
without it.
