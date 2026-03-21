<!-- last-reviewed: e782119a15e41cfb02b537d2b2294ab6b93ff342 -->
# Disinto — Agent Instructions

## What this repo is

Disinto is an autonomous code factory. It manages eight agents (dev, review,
gardener, supervisor, planner, predictor, action, vault) that pick up issues from Codeberg,
implement them, review PRs, plan from the vision, gate dangerous actions, and
keep the system healthy — all via cron and `claude -p`.

See `README.md` for the full architecture and `BOOTSTRAP.md` for setup.

## Directory layout

```
disinto/
├── dev/           dev-poll.sh, dev-agent.sh, phase-handler.sh — issue implementation
├── review/        review-poll.sh, review-pr.sh — PR review
├── gardener/      gardener-run.sh — files action issue for run-gardener formula
│                  gardener-poll.sh, gardener-agent.sh — recipe engine + grooming
├── predictor/     predictor-run.sh — daily cron executor for run-predictor formula
├── planner/       planner-run.sh — direct cron executor for run-planner formula
│                  planner/journal/ — daily raw logs from each planner run
│                  prediction-poll.sh, prediction-agent.sh — legacy predictor (superseded by predictor/)
├── supervisor/    supervisor-run.sh — formula-driven health monitoring (cron wrapper)
│                  preflight.sh — pre-flight data collection for supervisor formula
│                  supervisor/journal/ — daily health logs from each run
│                  supervisor-poll.sh — legacy bash orchestrator (superseded)
├── vault/         vault-poll.sh, vault-agent.sh, vault-fire.sh — action gating
├── action/        action-poll.sh, action-agent.sh — operational task execution
├── lib/           env.sh, agent-session.sh, ci-helpers.sh, ci-debug.sh, load-project.sh, parse-deps.sh, matrix_listener.sh
├── projects/      *.toml — per-project config
├── formulas/      Issue templates (TOML specs for multi-step agent tasks)
└── docs/          Protocol docs (PHASE-PROTOCOL.md, EVIDENCE-ARCHITECTURE.md)
```

> **Terminology note:** "Formulas" in this repo are TOML issue templates in `formulas/` that
> orchestrate multi-step agent tasks (e.g., `run-gardener.toml`, `run-planner.toml`). This is
> distinct from "processes" described in `docs/EVIDENCE-ARCHITECTURE.md`, which are measurement
> and mutation pipelines that read external platforms and write structured evidence to git.

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

**Trigger**: `gardener-run.sh` runs 2x/day via cron. It files an `action`
issue referencing `formulas/run-gardener.toml`; the [action-agent](#action-action)
picks it up and executes the gardener steps in an interactive Claude tmux session.
Accepts an optional project TOML argument (configures which project the action
issue is filed against).

**Key files**:
- `gardener/gardener-run.sh` — Cron wrapper: lock, memory guard, dedup check, files action issue
- `gardener/gardener-poll.sh` — Escalation-reply injection for dev sessions, invokes gardener-agent.sh for grooming
- `gardener/gardener-agent.sh` — Orchestrator: bash pre-analysis, creates tmux session (`gardener-{project}`) with interactive `claude`, monitors phase file, parses result file (ACTION:/DUST:/ESCALATE), handles dust bundling
- `formulas/run-gardener.toml` — Execution spec: preflight, grooming, blocked-review, agents-update, commit-and-pr

**Environment variables consumed**:
- `CODEBERG_TOKEN`, `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `CLAUDE_TIMEOUT`
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER`

### Supervisor (`supervisor/`)

**Role**: Health monitoring and auto-remediation, executed as a formula-driven
Claude agent. Collects system and project metrics via a bash pre-flight script,
then runs an interactive Claude session (sonnet) that assesses health, auto-fixes
issues, escalates via Matrix, and writes a daily journal.

**Trigger**: `supervisor-run.sh` runs every 20 min via cron. It creates a tmux
session with `claude --model sonnet`, injects `formulas/run-supervisor.toml`
with pre-collected metrics as context, monitors the phase file, and cleans up
on completion or timeout (20 min max session). No action issues — the supervisor
runs directly from cron like the planner and predictor.

**Key files**:
- `supervisor/supervisor-run.sh` — Cron wrapper + orchestrator: lock, memory guard,
  runs preflight.sh, sources disinto project config, creates tmux session, injects
  formula prompt with metrics, monitors phase file, handles crash recovery via
  `run_formula_and_monitor`
- `supervisor/preflight.sh` — Data collection: system resources (RAM, disk, swap,
  load), Docker status, active tmux sessions + phase files, lock files, agent log
  tails, CI pipeline status, open PRs, issue counts, stale worktrees, blocked
  issues, Matrix escalation replies
- `formulas/run-supervisor.toml` — Execution spec: five steps (preflight review,
  health-assessment, decide-actions, report, journal) with `needs` dependencies.
  Claude evaluates all metrics and takes actions in a single interactive session
- `supervisor/journal/*.md` — Daily health logs from each supervisor run (local,
  committed periodically)
- `supervisor/PROMPT.md` — Best-practices reference for remediation actions
- `supervisor/best-practices/*.md` — Domain-specific remediation guides (memory,
  disk, CI, git, dev-agent, review-agent, codeberg)
- `supervisor/supervisor-poll.sh` — Legacy bash orchestrator (superseded by
  supervisor-run.sh + formula)

**Alert priorities**: P0 (memory crisis), P1 (disk), P2 (factory stopped/stalled),
P3 (degraded PRs, circular deps, stale deps), P4 (housekeeping).

**Matrix integration**: The supervisor has its own Matrix thread. Posts health
summaries when there are changes, escalates P0-P2 issues, and processes replies
from humans ("ignore disk warning", "kill that agent", "what's stuck?"). The
Matrix listener routes thread replies to `/tmp/supervisor-escalation-reply`,
which `supervisor-run.sh` consumes atomically on each run.

**Environment variables consumed**:
- `CODEBERG_TOKEN`, `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by supervisor-run.sh)
- `WOODPECKER_TOKEN`, `WOODPECKER_SERVER`, `WOODPECKER_DB_PASSWORD`, `WOODPECKER_DB_USER`, `WOODPECKER_DB_HOST`, `WOODPECKER_DB_NAME` — CI database queries
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER` — Matrix notifications + human input

**Lifecycle**: supervisor-run.sh (cron */20) → lock + memory guard → run
preflight.sh (collect metrics) → consume escalation replies → load formula +
context → create tmux session → Claude assesses health, auto-fixes, posts
Matrix summary, writes journal → `PHASE:done`.

### Planner (`planner/`)

**Role**: Strategic planning, executed directly from cron via tmux + Claude.
Phase 0 (preflight): pull latest code, load persistent memory from
`planner/MEMORY.md`. Phase 1 (prediction-triage): triage
`prediction/unreviewed` issues filed by the [Predictor](#predictor-planner) —
for each prediction: promote to action, promote to backlog, watch (relabel to
prediction/backlog), or dismiss with reasoning. Promoted predictions compete
with vision gaps for the per-cycle issue limit. Phase 2 (strategic-planning):
resource+leverage gap analysis — reasons about VISION.md, RESOURCES.md,
formula catalog, and project state to create up to 5 total issues (including
promotions) prioritized by leverage. Phase 3 (journal-and-memory): write
daily journal entry (committed to git) and update `planner/MEMORY.md`
(committed to git). Phase 4 (commit-and-pr): one commit with all file
changes, push, create PR. AGENTS.md maintenance is handled by the
[Gardener](#gardener-gardener).

**Trigger**: `planner-run.sh` runs weekly via cron. It creates a tmux session
with `claude --model opus`, injects `formulas/run-planner.toml` as context,
monitors the phase file, and cleans up on completion or timeout. No action
issues — the planner is a nervous system component, not work.

**Key files**:
- `planner/planner-run.sh` — Cron wrapper + orchestrator: lock, memory guard,
  sources disinto project config, creates tmux session, injects formula prompt,
  monitors phase file, handles crash recovery, cleans up
- `formulas/run-planner.toml` — Execution spec: five steps (preflight,
  prediction-triage, strategic-planning, journal-and-memory, commit-and-pr)
  with `needs` dependencies. Claude executes all steps in a single interactive
  session with tool access
- `planner/MEMORY.md` — Persistent memory across runs (committed to git)
- `planner/journal/*.md` — Daily raw logs from each planner run (committed to git)

**Future direction**: The [Predictor](#predictor-predictor) files prediction issues daily for the planner to triage. The next step is evidence-gated deployment (see `docs/EVIDENCE-ARCHITECTURE.md`): replacing human "ship it" decisions with automated gates across dimensions (holdout, red-team, user-test, evolution fitness, protocol metrics, funnel). Not yet implemented.

**Environment variables consumed**:
- `CODEBERG_TOKEN`, `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to opus by planner-run.sh)
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER`

### Predictor (`predictor/`)

**Role**: Infrastructure pattern detection (the "goblin"). Runs a 3-step
formula (preflight → collect-signals → analyze-and-predict) via interactive
tmux Claude session (sonnet). Collects disinto-specific signals: CI pipeline
trends (Woodpecker), stale issues, agent health (tmux sessions + logs), and
resource patterns (RAM, disk, load, containers). Files up to 5
`prediction/unreviewed` issues for the [Planner](#planner-planner) to triage.
The predictor MUST NOT emit feature work — only observations about CI health,
issue staleness, agent status, and system conditions.

**Trigger**: `predictor-run.sh` runs daily at 06:00 UTC via cron (1h before
the planner at 07:00). Guarded by PID lock (`/tmp/predictor-run.lock`) and
memory check (skips if available RAM < 2000 MB).

**Key files**:
- `predictor/predictor-run.sh` — Cron wrapper + orchestrator: lock, memory guard,
  sources disinto project config, builds prompt with formula + Codeberg API
  reference, creates tmux session (sonnet), monitors phase file, handles crash
  recovery via `run_formula_and_monitor`
- `formulas/run-predictor.toml` — Execution spec: three steps (preflight,
  collect-signals, analyze-and-predict) with `needs` dependencies. Claude
  collects signals and files prediction issues in a single interactive session

**Supersedes**: The legacy predictor (`planner/prediction-poll.sh` +
`planner/prediction-agent.sh`) used `claude -p` one-shot, read `evidence/`
JSON, and ran hourly. This formula-based predictor replaces it with direct
CI/issues/logs signal collection and interactive Claude sessions, matching the
planner's tmux+formula pattern.

**Environment variables consumed**:
- `CODEBERG_TOKEN`, `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by predictor-run.sh)
- `WOODPECKER_TOKEN`, `WOODPECKER_SERVER` — CI pipeline trend queries (optional; skipped if unset)
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER` — Notifications (optional)

**Lifecycle**: predictor-run.sh (daily 06:00 cron) → lock + memory guard →
load formula + context → create tmux session → Claude collects signals
(CI trends, stale issues, agent health, resources) → dedup against existing
open predictions → file `prediction/unreviewed` issues → `PHASE:done`.
The planner's Phase 1 later triages these predictions.

### Action (`action/`)

**Role**: Execute operational tasks described by action formulas — run scripts,
call APIs, send messages, collect human approval. Shares the same phase handler
as the dev-agent: if an action produces code changes, the orchestrator creates a
PR and drives the CI/review loop; otherwise Claude closes the issue directly.

**Trigger**: `action-poll.sh` runs every 10 min via cron. It scans for open
issues labeled `action` that have no active tmux session, then spawns
`action-agent.sh <issue-number>`.

**Key files**:
- `action/action-poll.sh` — Cron scheduler: finds open action issues with no active tmux session, spawns action-agent.sh
- `action/action-agent.sh` — Orchestrator: fetches issue body + prior comments, creates tmux session (`action-{issue_num}`) with interactive `claude`, injects formula prompt with phase protocol, enters `monitor_phase_loop` (shared via `dev/phase-handler.sh`) for CI/review lifecycle or direct completion

**Session lifecycle**:
1. `action-poll.sh` finds open `action` issues with no active tmux session.
2. Spawns `action-agent.sh <issue_num>`.
3. Agent creates Matrix thread, exports `MATRIX_THREAD_ID` so Claude's output streams to the thread via a Stop hook (`on-stop-matrix.sh`).
4. Agent creates tmux session `action-{issue_num}`, injects prompt (formula + prior comments + phase protocol).
5. Agent enters `monitor_phase_loop` (shared with dev-agent via `dev/phase-handler.sh`).
6. **Path A (git output):** Claude pushes branch → `PHASE:awaiting_ci` → handler creates PR, polls CI → injects failures → Claude fixes → push → re-poll → CI passes → `PHASE:awaiting_review` → handler polls reviews → injects REQUEST_CHANGES → Claude fixes → approved → merge → cleanup.
7. **Path B (no git output):** Claude posts results as comment, closes issue → `PHASE:done` → handler cleans up (kill session, docker compose down, remove temp files).
8. For human input: Claude sends a Matrix message and waits; the reply is injected into the session by `matrix_listener.sh`.

**Environment variables consumed**:
- `CODEBERG_TOKEN`, `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `CODEBERG_WEB`
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER` — Matrix notifications + human input
- `ACTION_IDLE_TIMEOUT` — Max seconds before killing idle session (default 14400 = 4h)
- `ACTION_MAX_LIFETIME` — Max total session wall-clock seconds (default 28800 = 8h); caps session independently of idle timeout

---

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
| `lib/env.sh` | Loads `.env`, sets `FACTORY_ROOT`, exports project config (`CODEBERG_REPO`, `PROJECT_NAME`, etc.), defines `log()`, `codeberg_api()`, `codeberg_api_all()` (accepts optional second TOKEN parameter, defaults to `$CODEBERG_TOKEN`), `woodpecker_api()`, `wpdb()`, `matrix_send()`, `matrix_send_ctx()`. Auto-loads project TOML if `PROJECT_TOML` is set. | Every agent |
| `lib/ci-helpers.sh` | `ci_passed()` — returns 0 if CI state is "success" (or no CI configured). `is_infra_step()` — returns 0 if a single CI step failure matches infra heuristics (clone/git exit 128, any exit 137, log timeout patterns). `classify_pipeline_failure()` — returns "infra \<reason>" if any failed Woodpecker step matches infra heuristics via `is_infra_step()`, else "code". | dev-poll, review-poll, review-pr, supervisor-poll |
| `lib/ci-debug.sh` | CLI tool for Woodpecker CI: `list`, `status`, `logs`, `failures` subcommands. Not sourced — run directly. | Humans / dev-agent (tool access) |
| `lib/load-project.sh` | Parses a `projects/*.toml` file into env vars (`PROJECT_NAME`, `CODEBERG_REPO`, `WOODPECKER_REPO_ID`, monitoring toggles, Matrix config, etc.). | env.sh (when `PROJECT_TOML` is set), supervisor-poll (per-project iteration) |
| `lib/parse-deps.sh` | Extracts dependency issue numbers from an issue body (stdin → stdout, one number per line). Matches `## Dependencies` / `## Depends on` / `## Blocked by` sections and inline `depends on #N` patterns. Not sourced — executed via `bash lib/parse-deps.sh`. | dev-poll, supervisor-poll |
| `lib/matrix_listener.sh` | Long-poll Matrix sync daemon. Dispatches thread replies to the correct agent via well-known files (`/tmp/{agent}-escalation-reply`). Handles supervisor, gardener, dev, review, vault, and action reply routing. Run as systemd service. | Standalone daemon |
| `lib/formula-session.sh` | `acquire_cron_lock()`, `check_memory()`, `load_formula()`, `build_context_block()`, `start_formula_session()`, `formula_phase_callback()`, `build_prompt_footer()`, `run_formula_and_monitor()` — shared helpers for formula-driven cron agents (lock, memory guard, formula loading, prompt assembly, tmux session, monitor loop, crash recovery). | planner-run.sh, predictor-run.sh |
| `lib/file-action-issue.sh` | `file_action_issue()` — dedup check, label lookup, and issue creation for formula-driven cron wrappers. Sets `FILED_ISSUE_NUM` on success. | gardener-run.sh |
| `lib/agent-session.sh` | Shared tmux + Claude session helpers: `create_agent_session()`, `inject_formula()`, `agent_wait_for_claude_ready()`, `agent_inject_into_session()`, `agent_kill_session()`, `monitor_phase_loop()`, `read_phase()`, `write_compact_context()`. `create_agent_session(session, workdir, [phase_file])` optionally installs a PostToolUse hook (matcher `Bash\|Write`) that detects phase file writes in real-time — when Claude writes to the phase file, the hook writes a marker so `monitor_phase_loop` reacts on the next poll instead of waiting for mtime changes. Also installs a StopFailure hook (matcher `rate_limit\|server_error\|authentication_failed\|billing_error`) that writes `PHASE:failed` with an `api_error` reason to the phase file and touches the phase-changed marker, so the orchestrator discovers API errors within one poll cycle instead of waiting for idle timeout. Also installs a SessionStart hook (matcher `compact`) that re-injects phase protocol instructions after context compaction — callers write the context file via `write_compact_context(phase_file, content)`, and the hook (`on-compact-reinject.sh`) outputs the file content to stdout so Claude retains critical instructions. When `MATRIX_THREAD_ID` is exported, also installs a Stop hook (`on-stop-matrix.sh`) that streams each Claude response to the Matrix thread. `monitor_phase_loop` sets `_MONITOR_LOOP_EXIT` to one of: `done`, `idle_timeout`, `idle_prompt` (Claude returned to `❯` for 3 consecutive polls without writing any phase — callback invoked with `PHASE:failed`, session already dead), `crashed`, or a `PHASE:*` string. **Callers must handle `idle_prompt`** in both their callback and their post-loop exit handler — see [`docs/PHASE-PROTOCOL.md` § idle_prompt](docs/PHASE-PROTOCOL.md#idle_prompt-exit-reason) for the full contract. | dev-agent.sh, gardener-agent.sh, action-agent.sh |

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
| `blocked` | Issue is stuck — agent session failed, crashed, timed out, or CI exhausted. Diagnostic comment on the issue has details. Also used for unmet dependencies. | dev-agent.sh, action-agent.sh, dev-poll.sh (on failure) |
| `tech-debt` | Pre-existing issue flagged by AI reviewer, not introduced by a PR. | review-pr.sh (auto-created follow-ups) |
| `underspecified` | Dev-agent refused the issue as too large or vague. | dev-poll.sh (on preflight `too_large`), dev-agent.sh (on mid-run `too_large` refusal) |
| `vision` | Goal anchors — high-level objectives from VISION.md. | Planner, humans |
| `prediction/unreviewed` | Unprocessed prediction filed by predictor. | predictor-run.sh |
| `prediction/backlog` | Prediction triaged as WATCH — not urgent, tracked. | Planner (triage-predictions step) |
| `prediction/actioned` | Prediction promoted or dismissed by planner. | Planner (triage-predictions step) |
| `action` | Operational task for the action-agent to execute via formula. | Planner, humans |

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
