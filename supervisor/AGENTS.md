<!-- last-reviewed: 343b928a264e667ae7614be2a72e00555c87c63e -->
# Supervisor Agent

**Role**: Health monitoring and auto-remediation, executed as a formula-driven
Claude agent. Collects system and project metrics via a bash pre-flight script,
then runs an interactive Claude session (sonnet) that assesses health, auto-fixes
issues, and writes a daily journal. When blocked on external
resources or human decisions, files vault items instead of escalating directly.

**Trigger**: `supervisor-run.sh` is invoked by two polling loops:
- **Agents container** (`docker/agents/entrypoint.sh`): every `SUPERVISOR_INTERVAL` seconds (default 1200 = 20 min). Controlled by the `supervisor` role in `AGENT_ROLES` (included in the default seven-role set since P1/#801). Logs to `supervisor.log` in the agents container.
- **Edge container** (`docker/edge/entrypoint-edge.sh`): separate loop in the edge container (line 169-172). Runs independently of the agents container's polling schedule.

Both invoke the same `supervisor-run.sh`. Sources `lib/guard.sh` and calls `check_active supervisor` first — skips if `$FACTORY_ROOT/state/.supervisor-active` is absent. Then runs `claude -p` via `agent-sdk.sh`, injects `formulas/run-supervisor.toml` with pre-collected metrics as context, and cleans up on completion or timeout.

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
  housekeeping removes them after 24h. Collects **Woodpecker agent health**
  (added #933): container `disinto-woodpecker-agent` health/running status,
  gRPC error count in last 20 min, fast-failure pipeline count (<60s, last 15 min),
  and overall health verdict (healthy/unhealthy). Unhealthy verdict triggers
  automatic container restart + `blocked:ci_exhausted` issue recovery in
  `supervisor-run.sh` before the Claude session starts.
- `formulas/run-supervisor.toml` — Execution spec: five steps (preflight review,
  health-assessment, decide-actions, report, journal) with `needs` dependencies.
  Claude evaluates all metrics and takes actions in a single interactive session.
  Health-assessment now includes P2 **Woodpecker agent unhealthy** classification
  (container not running, ≥3 gRPC errors/20m, or ≥3 fast-failure pipelines/15m);
  decide-actions documents the pre-session auto-recovery path
- `$OPS_REPO_ROOT/knowledge/*.md` — Domain-specific remediation guides (memory,
  disk, CI, git, dev-agent, review-agent, forge)

**Alert priorities**: P0 (memory crisis), P1 (disk), P2 (factory stopped/stalled),
P3 (degraded PRs, circular deps, stale deps), P4 (housekeeping).

**Environment variables consumed**:
- `FORGE_TOKEN`, `FORGE_SUPERVISOR_TOKEN` (falls back to FORGE_TOKEN), `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`, `OPS_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by supervisor-run.sh)
- `SUPERVISOR_INTERVAL` — polling interval in seconds for agents container (default 1200 = 20 min)
- `WOODPECKER_TOKEN`, `WOODPECKER_SERVER`, `WOODPECKER_DB_PASSWORD`, `WOODPECKER_DB_USER`, `WOODPECKER_DB_HOST`, `WOODPECKER_DB_NAME` — CI database queries

**Degraded mode (Issue #544)**: When `OPS_REPO_ROOT` is not set or the directory doesn't exist, the supervisor runs in degraded mode:
- Uses bundled knowledge files from `$FACTORY_ROOT/knowledge/` instead of ops repo playbooks
- Writes journal locally to `$FACTORY_ROOT/state/supervisor-journal/` (not committed to git)
- Files vault items locally to `$PROJECT_REPO_ROOT/vault/pending/`
- Logs a WARNING message at startup indicating degraded mode

**Lifecycle**: supervisor-run.sh (invoked by polling loop every 20min, `check_active supervisor`)
→ lock + memory guard → run preflight.sh (collect metrics) → **WP agent health recovery**
(if unhealthy: restart container + recover ci_exhausted issues) → load formula + context → run
claude -p via agent-sdk.sh → Claude assesses health, auto-fixes, writes journal → `PHASE:done`.
