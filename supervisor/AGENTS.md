<!-- last-reviewed: 31f2cb7bfa38df3db8fbed28ec0899c412f06c49 -->
# Supervisor Agent

**Role**: Health monitoring and auto-remediation, executed as a formula-driven
Claude agent. Collects system and project metrics via a bash pre-flight script,
then runs an interactive Claude session (sonnet) that assesses health, auto-fixes
issues, and writes a daily journal. When blocked on external
resources or human decisions, files vault items instead of escalating directly.

**Trigger**: `supervisor-run.sh` is invoked by the polling loop in `docker/edge/entrypoint-edge.sh`
every 20 minutes (line 50-53). Sources `lib/guard.sh` and calls `check_active supervisor` first
— skips if `$FACTORY_ROOT/state/.supervisor-active` is absent. Then runs `claude -p` via
`agent-sdk.sh`, injects `formulas/run-supervisor.toml` with pre-collected metrics as context,
and cleans up on completion or timeout (20 min max session). Note: the supervisor runs in the
**edge container** (`entrypoint-edge.sh`), not the agent container — this distinction matters
for operators debugging the factory.

**Key files**:
- `supervisor/supervisor-run.sh` — Polling loop participant + orchestrator: lock, memory guard,
  runs preflight.sh, sources disinto project config, runs claude -p via agent-sdk.sh,
  injects formula prompt with metrics, handles crash recovery
- `supervisor/preflight.sh` — Data collection: system resources (RAM, disk, swap,
  load), Docker status, active sessions + phase files, lock files, agent log
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

**Alert priorities**: P0 (memory crisis), P1 (disk), P2 (factory stopped/stalled),
P3 (degraded PRs, circular deps, stale deps), P4 (housekeeping).

**Environment variables consumed**:
- `FORGE_TOKEN`, `FORGE_SUPERVISOR_TOKEN` (falls back to FORGE_TOKEN), `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`, `OPS_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by supervisor-run.sh)
- `WOODPECKER_TOKEN`, `WOODPECKER_SERVER`, `WOODPECKER_DB_PASSWORD`, `WOODPECKER_DB_USER`, `WOODPECKER_DB_HOST`, `WOODPECKER_DB_NAME` — CI database queries

**Degraded mode (Issue #544)**: When `OPS_REPO_ROOT` is not set or the directory doesn't exist, the supervisor runs in degraded mode:
- Uses bundled knowledge files from `$FACTORY_ROOT/knowledge/` instead of ops repo playbooks
- Writes journal locally to `$FACTORY_ROOT/state/supervisor-journal/` (not committed to git)
- Files vault items locally to `$PROJECT_REPO_ROOT/vault/pending/`
- Logs a WARNING message at startup indicating degraded mode

**Lifecycle**: supervisor-run.sh (invoked by polling loop every 20min, `check_active supervisor`)
→ lock + memory guard → run preflight.sh (collect metrics) → load formula + context → run
claude -p via agent-sdk.sh → Claude assesses health, auto-fixes, writes journal → `PHASE:done`.
