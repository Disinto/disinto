<!-- last-reviewed: eb7e24cb1df028c6061f47ddfdf9b4ebec33e1cf -->
# Predictor Agent

**Role**: Risk oracle and opportunity spotter (the "goblin"). Runs a 4-step
formula (preflight → collect-signals → re-evaluate-backlog → analyze-and-predict)
via interactive tmux Claude session (sonnet). Collects three categories of signals:

1. **Health signals** — CI pipeline trends (Woodpecker), stale issues, agent
   health (tmux sessions + logs), resource patterns (RAM, disk, load, containers)
2. **Outcome signals** — output freshness (formula journals/artifacts), capacity
   utilization (idle agents vs dispatchable backlog), throughput (closed issues,
   merged PRs, churn detection)
3. **External signals** — dependency security advisories, upstream breaking
   changes, deprecation notices, ecosystem shifts (via targeted web search)

Files up to 5 `prediction/unreviewed` issues for the Planner to triage.
Predictions cover both "things going wrong" and "opportunities being missed".
The predictor MUST NOT emit feature work — only observations about health,
outcomes, and external risks/opportunities.

**Trigger**: `predictor-run.sh` runs daily at 06:00 UTC via cron (1h before
the planner at 07:00). Guarded by PID lock (`/tmp/predictor-run.lock`) and
memory check (skips if available RAM < 2000 MB).

**Key files**:
- `predictor/predictor-run.sh` — Cron wrapper + orchestrator: lock, memory guard,
  sources disinto project config, builds prompt with formula + Codeberg API
  reference, creates tmux session (sonnet), monitors phase file, handles crash
  recovery via `run_formula_and_monitor`
- `formulas/run-predictor.toml` — Execution spec: four steps (preflight,
  collect-signals, re-evaluate-backlog, analyze-and-predict) with `needs`
  dependencies. Claude collects signals, re-evaluates watched predictions,
  and files prediction issues in a single interactive session

**Environment variables consumed**:
- `CODEBERG_TOKEN`, `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by predictor-run.sh)
- `WOODPECKER_TOKEN`, `WOODPECKER_SERVER` — CI pipeline trend queries (optional; skipped if unset)
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER` — Notifications (optional)

**Lifecycle**: predictor-run.sh (daily 06:00 cron) → lock + memory guard →
load formula + context → create tmux session → Claude collects signals
(health: CI trends, stale issues, agent health, resources; outcomes: output
freshness, capacity utilization, throughput; external: dependency advisories,
ecosystem changes via web search) → dedup against existing open predictions →
re-evaluate prediction/backlog watches (close stale, supersede changed) →
file `prediction/unreviewed` issues → `PHASE:done`.
The planner's Phase 1 later triages these predictions.
