# Disinto — Agent Instructions

## What this repo is

Disinto is an autonomous code factory. It manages six agents (dev, review,
gardener, supervisor, planner, vault) that pick up issues from Codeberg,
implement them, review PRs, plan from the vision, gate dangerous actions, and
keep the system healthy — all via cron and `claude -p`.

See `README.md` for the full architecture and `BOOTSTRAP.md` for setup.

## Directory layout

```
disinto/
├── dev/           dev-poll.sh, dev-agent.sh — issue implementation
├── review/        review-poll.sh, review-pr.sh — PR review
├── gardener/      gardener-poll.sh, gardener-agent.sh — backlog grooming
├── planner/       planner-poll.sh, planner-agent.sh — vision gap analysis
├── supervisor/    supervisor-poll.sh — health monitoring
├── vault/         vault-poll.sh, vault-agent.sh, vault-fire.sh — action gating
├── lib/           env.sh, agent-session.sh, ci-helpers.sh, ci-debug.sh, load-project.sh, parse-deps.sh, matrix_listener.sh
├── projects/      *.toml — per-project config
├── formulas/      Issue templates
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
git ls-files '*.sh' | xargs shellcheck

# Run phase protocol test
bash dev/phase-test.sh
```

---

## Agents

### Dev (`dev/`)

**Role**: Implement issues autonomously — write code, push branches, address
CI failures and review feedback.

**Trigger**: `dev-poll.sh` runs every 10 min via cron. It scans for ready
backlog issues (all deps closed) or orphaned in-progress issues and spawns
`dev-agent.sh <issue-number>`.

**Key files**:
- `dev/dev-poll.sh` — Cron scheduler: finds next ready issue, handles merge/rebase of approved PRs, tracks CI fix attempts
- `dev/dev-agent.sh` — Orchestrator: claims issue, creates worktree + tmux session with interactive `claude`, monitors phase file, injects CI results and review feedback, merges on approval
- `dev/phase-test.sh` — Integration test for the phase protocol

**Environment variables consumed** (via `lib/env.sh` + project TOML):
- `CODEBERG_TOKEN` — Dev-agent token (push, PR creation, merge) — use the dedicated bot account
- `CODEBERG_REPO`, `CODEBERG_API` — Target repository
- `PROJECT_NAME`, `PROJECT_REPO_ROOT` — Local checkout path
- `PRIMARY_BRANCH` — Branch to merge into (e.g. `main`, `master`)
- `WOODPECKER_REPO_ID` — CI pipeline lookups
- `CLAUDE_TIMEOUT` — Max seconds for a Claude session (default 7200)
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER` — Notifications (optional)

**Lifecycle**: dev-poll.sh → dev-agent.sh → tmux `dev-{project}-{issue}` →
phase file drives CI/review loop → merge → close issue.

### Review (`review/`)

**Role**: AI-powered PR review — post structured findings and formal
approve/request-changes verdicts to Codeberg.

**Trigger**: `review-poll.sh` runs every 10 min via cron. It scans open PRs
whose CI has passed and that lack a review for the current HEAD SHA, then
spawns `review-pr.sh <pr-number>`.

**Key files**:
- `review/review-poll.sh` — Cron scheduler: finds unreviewed PRs with passing CI
- `review/review-pr.sh` — Creates/reuses a tmux session (`review-{project}-{pr}`), injects PR diff, waits for Claude to write structured JSON output, posts markdown review + formal Codeberg review, auto-creates follow-up issues for pre-existing tech debt

**Environment variables consumed**:
- `CODEBERG_TOKEN` — Dev-agent token (must not be the same account as REVIEW_BOT_TOKEN)
- `REVIEW_BOT_TOKEN` — Review-agent token for approvals (use human/admin account; branch protection: in approvals whitelist)
- `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `WOODPECKER_REPO_ID`
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER`

### Gardener (`gardener/`)

**Role**: Backlog grooming — detect duplicate issues, missing acceptance
criteria, oversized issues, stale issues, and circular dependencies. Invoke
Claude to fix or escalate to a human via Matrix.

**Trigger**: `gardener-poll.sh` runs daily (or 2x/day) via cron. Accepts an
optional project TOML argument.

**Key files**:
- `gardener/gardener-poll.sh` — Cron wrapper: lock, escalation-reply injection for dev sessions, calls `gardener-agent.sh`, then processes dev-agent CI escalations via recipe engine
- `gardener/gardener-agent.sh` — Orchestrator: bash pre-analysis, creates tmux session (`gardener-{project}`) with interactive `claude`, monitors phase file, parses result file (ACTION:/DUST:/ESCALATE), handles dust bundling

**Environment variables consumed**:
- `CODEBERG_TOKEN`, `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `CLAUDE_TIMEOUT`
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER`

### Supervisor (`supervisor/`)

**Role**: Health monitoring and auto-remediation. Two-layer architecture:
(1) factory infrastructure checks (RAM, disk, swap, docker, stale processes)
that run once, and (2) per-project checks (CI, PRs, dev-agent health,
circular deps, stale deps) that iterate over `projects/*.toml`.

**Trigger**: `supervisor-poll.sh` runs every 10 min via cron.

**Key files**:
- `supervisor/supervisor-poll.sh` — All checks + auto-fixes (kill stale processes, rotate logs, drop caches, docker prune, abort stale rebases) then invokes `claude -p` for unresolved alerts
- `supervisor/update-prompt.sh` — Updates the supervisor prompt file
- `supervisor/PROMPT.md` — System prompt for the supervisor's Claude invocation

**Alert priorities**: P0 (memory crisis), P1 (disk), P2 (factory stopped/stalled),
P3 (degraded PRs, circular deps, stale deps), P4 (housekeeping).

**Environment variables consumed**:
- All from `lib/env.sh` + per-project TOML overrides
- `WOODPECKER_TOKEN`, `WOODPECKER_SERVER`, `WOODPECKER_DB_PASSWORD`, `WOODPECKER_DB_USER`, `WOODPECKER_DB_HOST`, `WOODPECKER_DB_NAME` — CI database queries
- `CHECK_PRS`, `CHECK_DEV_AGENT`, `CHECK_PIPELINE_STALL` — Per-project monitoring toggles (from TOML `[monitoring]` section)
- `CHECK_INFRA_RETRY` — Infra failure retry toggle (env var only, defaults to `true`; not configurable via project TOML)

### Planner (`planner/`)

**Role**: Two-phase planning. Phase 1: update the AGENTS.md documentation
tree to reflect recent code changes. Phase 2: gap-analyse VISION.md vs
current project state, create up to 5 backlog issues for the highest-leverage
gaps.

**Trigger**: `planner-poll.sh` runs weekly via cron.

**Key files**:
- `planner/planner-poll.sh` — Cron wrapper: lock, memory guard, runs planner-agent.sh
- `planner/planner-agent.sh` — Phase 1: uses `claude -p --model sonnet --max-turns 30` (one-shot with tool access) to read/update AGENTS.md files. Phase 2: uses `claude -p --model sonnet` to compare AGENTS.md tree vs VISION.md and create gap issues. Both phases are one-shot (`claude -p`), not interactive sessions

**Environment variables consumed**:
- `CODEBERG_TOKEN`, `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`
- `CLAUDE_TIMEOUT`
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER`

### Vault (`vault/`)

**Role**: Safety gate for dangerous or irreversible actions. Actions enter a
pending queue and are classified by Claude via `vault-agent.sh`, which can
auto-approve (call `vault-fire.sh` directly), auto-reject (call
`vault-reject.sh`), or escalate to a human via Matrix for APPROVE/REJECT.

**Trigger**: `vault-poll.sh` runs every 30 min via cron.

**Key files**:
- `vault/vault-poll.sh` — Processes pending actions: retry approved, auto-reject after 48h timeout, invoke vault-agent for new items
- `vault/vault-agent.sh` — Classifies and routes pending actions via `claude -p`: auto-approve, auto-reject, or escalate to human
- `vault/PROMPT.md` — System prompt for the vault agent's Claude invocation
- `vault/vault-fire.sh` — Executes an approved action
- `vault/vault-reject.sh` — Marks an action as rejected

**Environment variables consumed**:
- All from `lib/env.sh`
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER` — Escalation channel

---

## Shared helpers (`lib/`)

All agents source `lib/env.sh` as their first action. Additional helpers are
sourced as needed.

| File | What it provides | Sourced by |
|---|---|---|
| `lib/env.sh` | Loads `.env`, sets `FACTORY_ROOT`, exports project config (`CODEBERG_REPO`, `PROJECT_NAME`, etc.), defines `log()`, `codeberg_api()`, `woodpecker_api()`, `wpdb()`, `matrix_send()`, `matrix_send_ctx()`. Auto-loads project TOML if `PROJECT_TOML` is set. | Every agent |
| `lib/ci-helpers.sh` | `ci_passed()` — returns 0 if CI state is "success" (or no CI configured). | dev-poll, review-poll, review-pr, supervisor-poll |
| `lib/ci-debug.sh` | CLI tool for Woodpecker CI: `list`, `status`, `logs`, `failures` subcommands. Not sourced — run directly. | Humans / dev-agent (tool access) |
| `lib/load-project.sh` | Parses a `projects/*.toml` file into env vars (`PROJECT_NAME`, `CODEBERG_REPO`, `WOODPECKER_REPO_ID`, monitoring toggles, Matrix config, etc.). | env.sh (when `PROJECT_TOML` is set), supervisor-poll (per-project iteration) |
| `lib/parse-deps.sh` | Extracts dependency issue numbers from an issue body (stdin → stdout, one number per line). Matches `## Dependencies` / `## Depends on` / `## Blocked by` sections and inline `depends on #N` patterns. Not sourced — executed via `bash lib/parse-deps.sh`. | dev-poll, supervisor-poll |
| `lib/matrix_listener.sh` | Long-poll Matrix sync daemon. Dispatches thread replies to the correct agent via well-known files (`/tmp/{agent}-escalation-reply`). Handles supervisor, gardener, dev, review, and vault reply routing. Run as systemd service. | Standalone daemon |
| `lib/agent-session.sh` | Shared tmux + Claude session helpers: `create_agent_session()`, `inject_formula()`, `agent_wait_for_claude_ready()`, `agent_inject_into_session()`, `agent_kill_session()`, `monitor_phase_loop()`, `read_phase()`. | dev-agent.sh, phase-handler.sh, gardener-agent.sh |

---

## Issue lifecycle and label conventions

Issues flow through these states:

```
 [created]
    │
    ▼
 backlog        ← Ready for the dev-agent to pick up
    │
    ▼
 in-progress    ← Dev-agent has claimed the issue (backlog label removed)
    │
    ├── PR created → CI runs → review → merge
    │
    ▼
 closed         ← PR merged, issue closed automatically by dev-poll
```

### Labels

| Label | Meaning | Set by |
|---|---|---|
| `backlog` | Issue is queued for implementation. Dev-poll picks the first ready one. | Planner, gardener, humans |
| `in-progress` | Dev-agent is actively working on this issue. Only one issue per project is in-progress at a time. | dev-agent.sh (claims issue) |
| `blocked` | Issue has unmet dependencies (other open issues). | gardener, supervisor (detected) |
| `tech-debt` | Pre-existing issue flagged by AI reviewer, not introduced by a PR. | review-pr.sh (auto-created follow-ups) |
| `underspecified` | Dev-agent refused the issue as too large or vague. | dev-poll.sh (on preflight `too_large`), dev-agent.sh (on mid-run `too_large` refusal) |
| `vision` | Goal anchors — high-level objectives from VISION.md. | Planner, humans |

### Dependency conventions

Issues declare dependencies in their body using a `## Dependencies` or
`## Depends on` section listing `#N` references:

```markdown
## Dependencies
- #42
- #55
```

The dev-poll scheduler uses `lib/parse-deps.sh` to extract these and only
picks issues whose dependencies are all closed. The supervisor detects
circular dependency chains and stale dependencies (open > 30 days).

### Single-threaded pipeline

Each project processes one issue at a time. Dev-poll will not start new work
while an open PR is waiting for CI or review. This keeps context clear and
prevents merge conflicts between concurrent changes.

---

## Phase-Signaling Protocol (for persistent tmux sessions)

When running as a **persistent tmux session** (issue #80+), Claude must signal
the orchestrator at each phase boundary by writing to a well-known file.

### Phase file path

```
/tmp/dev-session-{project}-{issue}.phase
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
