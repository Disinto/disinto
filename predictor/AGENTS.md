<!-- last-reviewed: d13f1a6997a3f5a2c9a51fea3fb18ab75f161d7b -->
# Predictor Agent

**Role**: Abstract adversary (the "goblin"). Runs a 2-step formula
(preflight → find-weakness-and-act) via interactive tmux Claude session
(sonnet). Finds the project's biggest weakness, challenges planner claims,
and generates evidence through explore/exploit decisions:

- **Explore** (low confidence) — file a `prediction/unreviewed` issue for
  the planner to triage
- **Exploit** (high confidence) — file a prediction AND dispatch a formula
  via an `action` issue to generate evidence before the planner even runs

The predictor's own prediction history (open + closed issues) serves as its
memory — it reviews what was actioned, dismissed, or deferred to decide where
to focus next. No hardcoded signal categories; Claude decides where to look
based on available data: prerequisite tree, evidence directories, VISION.md,
RESOURCES.md, open issues, agent logs, and external signals (via web search).

Files up to 5 actions per run (predictions + dispatches combined). Each
exploit counts as 2 (prediction + action dispatch). The predictor MUST NOT
emit feature work — only observations challenging claims, exposing gaps,
and surfacing risks.

**Trigger**: `predictor-run.sh` runs daily at 06:00 UTC via cron (1h before
the planner at 07:00). Sources `lib/guard.sh` and calls `check_active predictor`
first — skips if `$FACTORY_ROOT/state/.predictor-active` is absent. Also guarded
by PID lock (`/tmp/predictor-run.lock`) and memory check (skips if available
RAM < 2000 MB).

**Key files**:
- `predictor/predictor-run.sh` — Cron wrapper + orchestrator: active-state guard,
  lock, memory guard, sources disinto project config, builds structural analysis
  graph via `lib/build-graph.py` (full-project scan — results included in prompt
  as `## Structural analysis`; failures non-fatal), builds prompt with formula +
  forge API reference, creates tmux session (sonnet), monitors phase file, handles
  crash recovery via `run_formula_and_monitor`
- `formulas/run-predictor.toml` — Execution spec: two steps (preflight,
  find-weakness-and-act) with `needs` dependencies. Claude reviews prediction
  history, explores/exploits weaknesses, and files issues in a single
  interactive session

**Environment variables consumed**:
- `FORGE_TOKEN`, `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by predictor-run.sh)
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER` — Notifications (optional)

**Lifecycle**: predictor-run.sh (daily 06:00 cron) → lock + memory guard →
load formula + context (AGENTS.md, RESOURCES.md, VISION.md, prerequisite-tree.md)
→ create tmux session → Claude fetches prediction history (open + closed) →
reviews track record (actioned/dismissed/watching) → finds weaknesses
(prerequisite tree gaps, thin evidence, stale watches, external risks) →
dedup against existing open predictions → explore (file prediction) or exploit
(file prediction + dispatch formula via action issue) → `PHASE:done`.
The planner's Phase 1 later triages these predictions.
