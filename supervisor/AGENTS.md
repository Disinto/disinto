<!-- last-reviewed: 70bc2375dd863442f9acff3bf8ee564a8e49155e -->
# Supervisor Agent

**Role**: Health monitoring and auto-remediation, executed as a formula-driven
Claude agent. Collects system and project metrics via a bash pre-flight script,
then runs an interactive Claude session (sonnet) that assesses health, auto-fixes
issues, and writes a daily journal. When blocked on external
resources or human decisions, files vault items instead of escalating directly.

**Trigger**: `supervisor-run.sh` is invoked by two polling loops:
- **Agents container** (`docker/agents/entrypoint.sh`): started by the polling loop on the SUPERVISOR_INTERVAL cadence (default 20 min, #1388). Controlled by the `supervisor` role in `AGENT_ROLES` (included in the default seven-role set since P1/#801).
- **Edge container** (`docker/edge/entrypoint-edge.sh`): separate loop in the edge container (line 169-172). Runs independently of the agents container's polling schedule.

Both invoke the same `supervisor-run.sh`. Sources `lib/guard.sh` and calls `check_active supervisor` first — skips if `$FACTORY_ROOT/state/.supervisor-active` is absent. Then runs a recipe evaluation preflight (`evaluate-recipes.sh`): if no abnormal signals requiring LLM are detected, the run exits early (fast path). Otherwise, runs `claude -p` via `agent-sdk.sh`, injects `formulas/run-supervisor.toml` with pre-collected metrics as context, and cleans up on completion or timeout.

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
  `supervisor-run.sh` before the Claude session starts. Reports
  **research runs** (added #1322): in-flight count + per-run ages (heartbeat)
  from the run ledger at `${OPS_REPO_ROOT}/runs`, artifacts disk %, and oldest
  open `judgment`-labeled issue age — the "Research Runs" section is omitted
  when the ledger directory is absent (not a failure).
- `formulas/run-supervisor.toml` — Execution spec: six steps (preflight review,
  health-assessment, decide-actions, report, incidents, journal) with `needs`
  dependencies. Claude evaluates all metrics and takes actions in a single
  interactive session. Health-assessment now includes P2 **Woodpecker agent
  unhealthy** classification (container not running, ≥3 gRPC errors/20m, or
  ≥3 fast-failure pipelines/15m) and research-run findings from the preflight
  "Research Runs" section (added #1322): P1 artifacts disk > 80%, P2 in-flight
  run older than 70 min, P3 oldest open judgment issue older than 4 h;
  decide-actions documents the pre-session auto-recovery path
- `supervisor/write-incident.sh` — Writes one markdown incident file per fired
  recipe (P0–P2 only) under `${OPS_REPO_ROOT}/incidents/`. Sources
  `lib/secret-scan.sh` for redaction; graceful exit in degraded mode.
- `supervisor/commit-incidents.sh` — Commits and pushes incident markdown files
  to the ops repo after the Claude session writes them.
- `$OPS_REPO_ROOT/knowledge/*.md` — Domain-specific remediation guides (memory,
  disk, CI, git, dev-agent, review-agent, forge)

**Log sinks**: `supervisor-run.sh`'s internal structured logging goes to
`data/logs/supervisor/supervisor.log`; the polling loop's redirect (#1388)
writes the invocation's stdout/stderr to the same `data/logs/supervisor/supervisor.log`.
#1150 unified the *internal* logging on the `supervisor/` path after the
dual-sink incident — do not introduce a second internal path.

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

**Lifecycle**: supervisor-run.sh (started by the polling loop on the SUPERVISOR_INTERVAL cadence, #1388; `check_active supervisor`)
→ lock + memory guard → **CI circuit breaker** (issue #557): reconcile `.dev-active` against incident PR state — open incident PR removes `.dev-active` (pause dev agents); no incident + green canary restores `.dev-active` (resume) → run preflight.sh (collect metrics) → **WP agent health recovery**
(if unhealthy: restart container + recover ci_exhausted issues) → **recipe evaluation**
(`evaluate-recipes.sh`): if all fired recipes have `action: direct` with valid `action_script`
and none require LLM, skip to journal + exit (fast path); otherwise proceed → load formula + context
→ run claude -p via agent-sdk.sh → Claude assesses health, evaluates recipes, auto-fixes,
writes journal → `incidents` step writes markdown files for fired P0–P2 recipes
→ `commit-incidents.sh` commits and pushes to ops repo → `PHASE:done`.
