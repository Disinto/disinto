# agents-llama — Local-Qwen Dev Agent

The `agents-llama` service is an optional compose service that runs a dev agent
backed by a local llama-server instance (e.g. Qwen) instead of the Anthropic
API. It uses the same Docker image as the main `agents` service but connects to
a local inference endpoint via `ANTHROPIC_BASE_URL`.

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

## Prerequisites

- **llama-server** (or compatible OpenAI-API endpoint) running on the host,
  reachable from inside Docker at the URL set in `ANTHROPIC_BASE_URL`.
- A Forgejo bot user (e.g. `dev-qwen`) with its own API token and password,
  stored as `FORGE_TOKEN_LLAMA` / `FORGE_PASS_LLAMA`.

## Behaviour

- `AGENT_ROLES=dev` — the llama agent only picks up dev work.
- `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60` — more aggressive compaction for smaller
  context windows.
- `depends_on: forgejo (service_healthy)` — does **not** depend on Woodpecker
  (the llama agent doesn't need CI).
- Serialises on the llama-server's single KV cache (AD-002).

## Disabling

Set `ENABLE_LLAMA_AGENT=0` (or leave it unset) and regenerate. The service
block is omitted entirely from `docker-compose.yml`; the stack starts cleanly
without it.
