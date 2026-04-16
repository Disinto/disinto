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
