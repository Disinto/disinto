# Claude Code OAuth Concurrency Model

## TL;DR

The factory runs N+1 concurrent Claude Code processes across containers
that all share `~/.claude` via bind mount. To avoid OAuth refresh races,
they MUST be serialized by the external `flock` on
`${HOME}/.claude/session.lock` in `lib/agent-sdk.sh`. Claude Code's
internal OAuth refresh lock does **not** work across containers in our
mount layout. Do not remove the external flock without also fixing the
lockfile placement upstream.

## What we run

| Container | Claude Code processes | Mount of `~/.claude` |
|---|---|---|
| `disinto-agents` (persistent) | polling-loop agents via `lib/agent-sdk.sh::agent_run` | `/home/johba/.claude` → `/home/agent/.claude` (rw) |
| `disinto-edge` (persistent) | none directly — spawns transient containers via `docker/edge/dispatcher.sh` | n/a |
| transient containers spawned by `dispatcher.sh` | one-shot `claude` per invocation | same mount, same path |

All N+1 processes can hit the OAuth refresh window concurrently when
the access token nears expiry.

## The race

OAuth access tokens are short-lived; refresh tokens rotate on each
refresh. If two processes both POST the same refresh token to
Anthropic's token endpoint simultaneously, only one wins — the other
gets `invalid_grant` and the operator is forced to re-login.

Historically this manifested as "agents losing auth, frequent re-logins",
which is the original reason `lib/agent-sdk.sh` introduced the external
flock. The current shape (post-#606 watchdog work) is at
`lib/agent-sdk.sh:139,144`:

```bash
local lock_file="${HOME}/.claude/session.lock"
...
output=$(cd "$run_dir" && ( flock -w 600 9 || exit 1;
  claude_run_with_watchdog claude "${args[@]}" ) 9>"$lock_file" ...)
```

This serializes every `claude` invocation across every process that
shares `${HOME}/.claude/`.

## Why Claude Code's internal lock does not save us

`src/utils/auth.ts:1491` (read from a leaked TS source — current as of
April 2026) calls:

```typescript
release = await lockfile.lock(claudeDir)
```

with no `lockfilePath` option. `proper-lockfile` defaults to creating
the lock at `<target>.lock` as a **sibling**, so for
`claudeDir = /home/agent/.claude`, the lockfile is created at
`/home/agent/.claude.lock`.

`/home/agent/.claude` is bind-mounted from the host, but `/home/agent/`
itself is part of each container's local overlay filesystem. So each
container creates its own private `/home/agent/.claude.lock` — they
never see each other's locks. The internal cross-process lock is a
no-op across our containers.

Verified empirically:

```
$ docker exec disinto-agents findmnt /home/agent/.claude
TARGET              SOURCE                                  FSTYPE
/home/agent/.claude /dev/loop15[/...rootfs/home/johba/.claude] btrfs

$ docker exec disinto-agents findmnt /home/agent
(blank — not a mount, container-local overlay)

$ docker exec disinto-agents touch /home/agent/test-marker
$ docker exec disinto-edge ls /home/agent/test-marker
ls: cannot access '/home/agent/test-marker': No such file or directory
```

(Compare with `src/services/mcp/auth.ts:2097`, which does it correctly
by passing `lockfilePath: join(claudeDir, "mcp-refresh-X.lock")` — that
lockfile lives inside the bind-mounted directory and IS shared. The
OAuth refresh path is an upstream oversight worth filing once we have
bandwidth.)

## How the external flock fixes it

The lock file path `${HOME}/.claude/session.lock` is **inside**
`~/.claude/`, which IS shared via the bind mount. All containers see
the same inode and serialize correctly via `flock`. This is a
sledgehammer (it serializes the entire `claude -p` call, not just the
refresh window) but it works.

## Decision matrix for new claude-using containers

When adding a new container that runs Claude Code:

1. **If the container is a batch / agent context** (long-running calls,
   tolerant of serialization): mount the same `~/.claude` and route
   all `claude` calls through `lib/agent-sdk.sh::agent_run` so they
   take the external flock.

2. **If the container is interactive** (chat, REPL, anything where the
   operator is waiting on a response): do NOT join the external flock.
   Interactive starvation under the agent loop would be unusable —
   chat messages would block waiting for the current agent's
   `claude -p` call to finish, which can be minutes, and the 10-min
   `flock -w 600` would frequently expire under a busy loop. Instead,
   pick one of:
   - **Separate OAuth identity**: new `~/.claude-chat/` on the host with
     its own `claude auth login`, mounted to the new container's
     `/home/agent/.claude`. Independent refresh state.
   - **`ANTHROPIC_API_KEY` fallback**: the codebase already supports it
     in `docker/agents/entrypoint.sh:119-125`. Different billing track
     but trivial config and zero coupling to the agents' OAuth.

3. **Never** mount the parent directory `/home/agent/` instead of just
   `.claude/` to "fix" the lockfile placement — exposes too much host
   state to the container.

## Future fix

The right long-term fix is upstream: file an issue against Anthropic's
claude-code repo asking that `src/utils/auth.ts:1491` be changed to
follow the pattern at `src/services/mcp/auth.ts:2097` and pass an
explicit `lockfilePath` inside `claudeDir`. Once that lands and we
upgrade, the external flock can become a fast-path no-op or be removed
entirely.

## See also

- `lib/agent-sdk.sh:139,144` — the external flock
- `docker/agents/entrypoint.sh:119-125` — the `ANTHROPIC_API_KEY` fallback
- Issue #623 — chat container, auth strategy (informed by this doc)
