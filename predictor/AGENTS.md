<!-- last-reviewed: 038581e555403586f4595f8a5f77d7dbb311779b -->
# Predictor Agent

**Role**: Infrastructure pattern detection (the "goblin"). Runs a 3-step
formula (preflight → collect-signals → analyze-and-predict) via interactive
tmux Claude session (sonnet). Collects disinto-specific signals: CI pipeline
trends (Woodpecker), stale issues, agent health (tmux sessions + logs), and
resource patterns (RAM, disk, load, containers). Files up to 5
`prediction/unreviewed` issues for the Planner to triage. The predictor MUST
NOT emit feature work — only observations about CI health, issue staleness,
agent status, and system conditions.

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
