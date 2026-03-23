<!-- last-reviewed: c9bf9fe5281c4037fd3f2219fde093dcbb053e00 -->
# Supervisor Agent

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
