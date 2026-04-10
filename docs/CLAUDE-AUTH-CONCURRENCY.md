# Claude Code OAuth Concurrency Model

## Problem statement

The factory runs multiple concurrent Claude Code processes across
containers. OAuth access tokens are short-lived; refresh tokens rotate
on each use. If two processes POST the same refresh token to Anthropic's
token endpoint simultaneously, only one wins — the other gets
`invalid_grant` and the operator is forced to re-login.

Claude Code already serializes OAuth refreshes internally using
`proper-lockfile` (`src/utils/auth.ts:1485-1491`):

```typescript
release = await lockfile.lock(claudeDir)
```

`proper-lockfile` creates a lockfile via an atomic `mkdir(${path}.lock)`
call — a cross-process primitive that works across any number of
processes on the same filesystem. The problem was never the lock
implementation; it was that our old per-container bind-mount layout
(`~/.claude` mounted but `/home/agent/` container-local) caused each
container to compute a different lockfile path, so the locks never
coordinated.

## The fix: shared `CLAUDE_CONFIG_DIR`

`CLAUDE_CONFIG_DIR` is an officially supported env var in Claude Code
(`src/utils/envUtils.ts`). It controls where Claude resolves its config
directory instead of the default `~/.claude`.

By setting `CLAUDE_CONFIG_DIR` to a path on a shared bind mount, every
container computes the **same** lockfile location. `proper-lockfile`'s
atomic `mkdir(${CLAUDE_CONFIG_DIR}.lock)` then gives free cross-container
serialization — no external wrapper needed.

## Current layout

```
Host filesystem:
  /var/lib/disinto/claude-shared/          ← CLAUDE_SHARED_DIR
  └── config/                              ← CLAUDE_CONFIG_DIR
      ├── credentials.json
      ├── settings.json
      └── ...

Inside every container:
  Same absolute path: /var/lib/disinto/claude-shared/config
  Env: CLAUDE_CONFIG_DIR=/var/lib/disinto/claude-shared/config
```

The shared directory is mounted at the **same absolute path** inside
every container, so `proper-lockfile` resolves an identical lock path
everywhere.

### Where these values are defined

| What | Where |
|------|-------|
| Defaults for `CLAUDE_SHARED_DIR`, `CLAUDE_CONFIG_DIR` | `lib/env.sh:138-140` |
| `.env` documentation | `.env.example:92-99` |
| Container mounts + env passthrough (edge dispatcher) | `docker/edge/dispatcher.sh:446-448` (and analogous blocks for reproduce, triage, verify) |
| Auth detection using `CLAUDE_CONFIG_DIR` | `docker/agents/entrypoint.sh:101-102` |
| Bootstrap / migration during `disinto init` | `lib/claude-config.sh:setup_claude_config_dir()`, `bin/disinto:952-962` |

## Migration for existing dev boxes

For operators upgrading from the old `~/.claude` bind-mount layout,
`disinto init` handles the migration interactively (or with `--yes`).
The manual equivalent is:

```bash
# 1. Stop the factory
disinto down

# 2. Create the shared directory
mkdir -p /var/lib/disinto/claude-shared

# 3. Move existing config
mv "$HOME/.claude" /var/lib/disinto/claude-shared/config

# 4. Create a back-compat symlink so host-side claude still works
ln -sfn /var/lib/disinto/claude-shared/config "$HOME/.claude"

# 5. Export the env var (add to shell rc for persistence)
export CLAUDE_CONFIG_DIR=/var/lib/disinto/claude-shared/config

# 6. Start the factory
disinto up
```

## Verification

Watch for these analytics events during concurrent agent runs:

| Event | Meaning |
|-------|---------|
| `tengu_oauth_token_refresh_lock_acquiring` | A process is attempting to acquire the refresh lock |
| `tengu_oauth_token_refresh_lock_acquired` | Lock acquired; refresh proceeding |
| `tengu_oauth_token_refresh_lock_retry` | Lock is held by another process; retrying |
| `tengu_oauth_token_refresh_lock_race_resolved` | Contention detected and resolved normally |
| `tengu_oauth_token_refresh_lock_retry_limit_reached` | Lock acquisition failed after all retries |

**Healthy:** `_race_resolved` appearing during contention windows — this
means multiple processes tried to refresh simultaneously and the lock
correctly serialized them.

**Bad:** `_lock_retry_limit_reached` — indicates the lock is stuck or
the shared mount is not working. Verify that `CLAUDE_CONFIG_DIR` resolves
to the same path in all containers and that the filesystem supports
`mkdir` atomicity (any POSIX filesystem does).

## The deferred external `flock` wrapper

`lib/agent-sdk.sh:139,144` still wraps every `claude` invocation in an
external `flock` on `${HOME}/.claude/session.lock`:

```bash
local lock_file="${HOME}/.claude/session.lock"
...
output=$(cd "$run_dir" && ( flock -w 600 9 || exit 1;
  claude_run_with_watchdog claude "${args[@]}" ) 9>"$lock_file" ...)
```

With the `CLAUDE_CONFIG_DIR` fix in place, this external lock is
**redundant but harmless** — `proper-lockfile` serializes the refresh
internally, and `flock` serializes the entire invocation externally.
The external flock remains as a defense-in-depth measure; removal is
tracked as a separate vision-tier issue.

## See also

- `lib/env.sh:138-140` — `CLAUDE_SHARED_DIR` / `CLAUDE_CONFIG_DIR` defaults
- `lib/claude-config.sh` — migration helper used by `disinto init`
- `lib/agent-sdk.sh:139,144` — the external `flock` wrapper (deferred removal)
- `docker/agents/entrypoint.sh:101-102` — `CLAUDE_CONFIG_DIR` auth detection
- `.env.example:92-99` — operator-facing documentation of the env vars
- Issue #623 — chat container auth strategy
