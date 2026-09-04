<!-- last-reviewed: 0bb94d6 -->
# Voice interface

The voice interface (parent issue #651) lets an operator talk to the
factory through a browser mic → Gemini Live speech-to-speech model,
with a `think` tool that delegates reasoning to a `claude -r` child.
See `SOUL_VOICE.md` for the voice-layer system prompt and
`SOUL_THINK.md` for the reasoning-layer prompt.

Runtime wiring lands in pieces:

| Child | Scope |
|---|---|
| #662 | Python bridge in the edge container: Gemini Live WebSocket ↔ `think` tool ↔ `claude -r` |
| #663 | Browser UI at `/voice/` — mic + Silero VAD + WebSocket client |
| #664 | Vault KV seeding + `edge.hcl` template stanza for `GEMINI_API_KEY` (this page) |

## Gemini API key

### Where it lives

| Layer | Path |
|---|---|
| Operator source of truth | `.env` → `GEMINI_API_KEY=...` |
| Vault KV v2 | `kv/disinto/voice.gemini_api_key` |
| Inside the edge container | `/secrets/gemini-api-key` (file, perms 0400) |
| Env visible to subprocesses | **voice bridge only** via `GEMINI_API_KEY_FILE=/secrets/gemini-api-key` |

The Vault role `service-edge-chat` is shared by the caddy task's chat
and voice subprocesses (see `vault/policies/service-edge-chat.hcl`).
Nomad binds one role per task, so chat and voice share read access to
both `kv/disinto/chat` and `kv/disinto/voice`. Per-subprocess isolation
is enforced at launch time — the voice launcher reads the file and sets
`GEMINI_API_KEY` only in its own child env; the chat subprocess never
reads the file and never sees the key.

### First-time seeding

After factory init, seed the key manually:

```sh
# On the factory host (where .env and Vault live):
echo 'GEMINI_API_KEY=AIza...your-key...' >> .env
disinto vault reseed-voice
```

The command:

1. Reads `GEMINI_API_KEY` from `./.env`.
2. Writes it to Vault at `kv/disinto/voice.gemini_api_key`.
3. The Nomad template stanza in `nomad/jobs/edge.hcl` detects the
   Vault change and re-renders `/secrets/gemini-api-key`. The template
   is `change_mode = "noop"` (#1091 stabilization), so finish with a
   manual restart for the new key to take effect:

```sh
nomad alloc restart <edge-alloc-id>   # picks up the re-rendered secret
```

The script is idempotent: same-value writes are cheap no-ops, and a
missing `GEMINI_API_KEY` in `.env` leaves Vault untouched rather than
blanking the key.

### Rotation

Rotate the key at the Google AI Studio console, then mirror the new
value into Vault:

```sh
# 1. Update .env with the new key (do not commit — .env is gitignored).
sed -i 's|^GEMINI_API_KEY=.*|GEMINI_API_KEY=AIza...NEW...|' .env

# 2. Re-seed Vault, then restart the edge alloc so the re-rendered
#    /secrets/gemini-api-key is picked up (template is noop — no
#    auto-restart) and the voice bridge relaunches with the new key.
disinto vault reseed-voice
nomad alloc restart <edge-alloc-id>
```

For out-of-band rotation (without touching `.env`), write directly to
Vault:

```sh
vault kv put kv/disinto/voice gemini_api_key='AIza...NEW...'
```

Either path re-renders the secret file; both need the same manual
`nomad alloc restart <edge-alloc-id>` to take effect (no auto-restart
under #1091 stabilization). The chat subprocess is not
affected by a voice-only rotation — the restart is task-scoped, and
chat reads its secrets from `kv/disinto/chat`, which is untouched.

### Verifying

```sh
# Vault has the key:
vault kv get kv/disinto/voice

# Inside the edge container, the file is rendered and the chat
# subprocess does NOT have GEMINI_API_KEY in its env:
docker exec edge sh -c 'ls -l /secrets/gemini-api-key'
docker exec edge sh -c 'env | grep -c "^GEMINI_API_KEY=" || echo "not set in task env (expected)"'
```

The bridge subprocess (#662) will set `GEMINI_API_KEY` only in its own
child env when it launches, so `env` on the caddy task itself must
not show it.
