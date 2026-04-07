<!-- last-reviewed: fcd892dce054eeb5dfdd01d578e4b0eec4a78c9b -->
# Supervisor Agent

**Role**: Health monitoring and auto-remediation, executed as a formula-driven
Claude agent. Collects system and project metrics via a bash pre-flight script,
then runs an interactive Claude session (sonnet) that assesses health, auto-fixes
issues, and writes a daily journal. When blocked on external
resources or human decisions, files vault items instead of escalating directly.

**Trigger**: `supervisor-run.sh` runs every 20 min via cron. Sources `lib/guard.sh`
and calls `check_active supervisor` first — skips if
`$FACTORY_ROOT/state/.supervisor-active` is absent. Then creates a tmux session
with `claude --model sonnet`, injects `formulas/run-supervisor.toml` with
pre-collected metrics as context, monitors the phase file, and cleans up on
completion or timeout (20 min max session). No action issues — the supervisor
runs directly from cron like the planner and predictor.

**Key files**:
- `supervisor/supervisor-run.sh` — Cron wrapper + orchestrator: lock, memory guard,
  runs preflight.sh, sources disinto project config, creates tmux session, injects
  formula prompt with metrics, monitors phase file, handles crash recovery via
  `run_formula_and_monitor`
- `supervisor/preflight.sh` — Data collection: system resources (RAM, disk, swap,
  load), Docker status, active tmux sessions + phase files, lock files, agent log
  tails, CI pipeline status, open PRs, issue counts, stale worktrees, blocked
  issues. Also performs **stale phase cleanup**: scans `/tmp/*-session-*.phase`
  files for `PHASE:escalate` entries and auto-removes any whose linked issue
  is confirmed closed (24h grace period after closure to avoid races). Reports
  **stale crashed worktrees** (worktrees preserved after crash) — supervisor
  housekeeping removes them after 24h
- `formulas/run-supervisor.toml` — Execution spec: five steps (preflight review,
  health-assessment, decide-actions, report, journal) with `needs` dependencies.
  Claude evaluates all metrics and takes actions in a single interactive session
- `$OPS_REPO_ROOT/knowledge/*.md` — Domain-specific remediation guides (memory,
  disk, CI, git, dev-agent, review-agent, forge)
- `supervisor/supervisor-poll.sh` — Legacy bash orchestrator (superseded by
  supervisor-run.sh + formula)

**Alert priorities**: P0 (memory crisis), P1 (disk), P2 (factory stopped/stalled),
P3 (degraded PRs, circular deps, stale deps), P4 (housekeeping).

**Environment variables consumed**:
- `FORGE_TOKEN`, `FORGE_SUPERVISOR_TOKEN` (falls back to FORGE_TOKEN), `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`, `OPS_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by supervisor-run.sh)
- `WOODPECKER_TOKEN`, `WOODPECKER_SERVER`, `WOODPECKER_DB_PASSWORD`, `WOODPECKER_DB_USER`, `WOODPECKER_DB_HOST`, `WOODPECKER_DB_NAME` — CI database queries

**Lifecycle**: supervisor-run.sh (cron */20) → lock + memory guard → run
preflight.sh (collect metrics) → load formula + context → create tmux
session → Claude assesses health, auto-fixes, writes journal → `PHASE:done`.
