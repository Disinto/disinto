# Disinto — Agent Instructions

## What this repo is

Disinto is an autonomous code factory. It manages four agents (dev, review,
gardener, supervisor) that pick up issues from Codeberg, implement them,
review PRs, and keep the system healthy — all via cron and `claude -p`.

See `README.md` for the full architecture and `BOOTSTRAP.md` for setup.

## Directory layout

```
disinto/
├── dev/           dev-poll.sh, dev-agent.sh — issue implementation
├── review/        review-poll.sh, review-pr.sh — PR review
├── gardener/      gardener-poll.sh — backlog grooming
├── supervisor/    supervisor-poll.sh — health monitoring
├── lib/           env.sh, ci-debug.sh, matrix_listener.sh
├── projects/      *.toml — per-project config
└── docs/          Protocol docs (PHASE-PROTOCOL.md, etc.)
```

## Tech stack

- **Shell**: bash (all agents are bash scripts)
- **AI**: `claude -p` (one-shot) or `claude` (interactive/tmux sessions)
- **CI**: Woodpecker CI (queried via REST API + Postgres)
- **VCS**: Codeberg (git + Gitea REST API)
- **Notifications**: Matrix (optional)

## Coding conventions

- All scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`
- Source shared environment: `source "$(dirname "$0")/../lib/env.sh"`
- Log to `$LOGFILE` using the `log()` function from env.sh or defined locally
- Never hardcode secrets — all come from `.env` or TOML project files
- ShellCheck must pass (CI runs `shellcheck` on all `.sh` files)
- Avoid duplicate code — shared helpers go in `lib/`

## How to lint and test

```bash
# ShellCheck all scripts
shellcheck dev/dev-poll.sh dev/dev-agent.sh dev/phase-test.sh \
           review/review-poll.sh review/review-pr.sh \
           gardener/gardener-poll.sh \
           supervisor/supervisor-poll.sh supervisor/update-prompt.sh \
           lib/env.sh lib/ci-debug.sh lib/load-project.sh \
           lib/parse-deps.sh lib/matrix_listener.sh

# Run phase protocol test
bash dev/phase-test.sh
```

---

## Phase-Signaling Protocol (for persistent tmux sessions)

When running as a **persistent tmux session** (issue #80+), Claude must signal
the orchestrator at each phase boundary by writing to a well-known file.

### Phase file path

```
/tmp/dev-session-{PROJECT_NAME}-{ISSUE}.phase
```

### Required phase sentinels

Write exactly one of these lines (with `>`, not `>>`) when a phase ends:

```bash
PHASE_FILE="/tmp/dev-session-${PROJECT_NAME:-project}-${ISSUE:-0}.phase"

# After pushing a PR branch — waiting for CI
echo "PHASE:awaiting_ci" > "$PHASE_FILE"

# After CI passes — waiting for review
echo "PHASE:awaiting_review" > "$PHASE_FILE"

# Blocked on human decision (ambiguous spec, architectural question)
echo "PHASE:needs_human" > "$PHASE_FILE"

# PR is merged and issue is done
echo "PHASE:done" > "$PHASE_FILE"

# Unrecoverable failure
printf 'PHASE:failed\nReason: %s\n' "describe what failed" > "$PHASE_FILE"
```

### When to write each phase

1. **After `git push origin $BRANCH`** → write `PHASE:awaiting_ci`
2. **After receiving "CI passed" injection** → write `PHASE:awaiting_review`
3. **After receiving review feedback** → address it, push, write `PHASE:awaiting_review`
4. **After receiving "Approved" injection** → merge (or wait for orchestrator to merge), write `PHASE:done`
5. **When stuck on human-only decision** → write `PHASE:needs_human`, then wait for input
6. **When a step fails unrecoverably** → write `PHASE:failed`

### Crash recovery

If this session was restarted after a crash, the orchestrator will inject:
- The issue body
- `git diff` of work completed before the crash
- The last known phase
- Any CI results or review comments

Read that context, then resume from where you left off. The git worktree is
the checkpoint — your code changes survived the crash.

### Full protocol reference

See `docs/PHASE-PROTOCOL.md` for the complete spec including the orchestrator
reaction matrix and sequence diagram.
