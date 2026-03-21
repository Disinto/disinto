<!-- last-reviewed: 038581e555403586f4595f8a5f77d7dbb311779b -->
# Planner Agent

**Role**: Strategic planning, executed directly from cron via tmux + Claude.
Phase 0 (preflight): pull latest code, load persistent memory from
`planner/MEMORY.md`. Phase 1 (prediction-triage): triage
`prediction/unreviewed` issues filed by the Predictor — for each prediction:
promote to action, promote to backlog, watch (relabel to prediction/backlog),
or dismiss with reasoning. Promoted predictions compete with vision gaps for
the per-cycle issue limit. Phase 2 (strategic-planning): resource+leverage gap
analysis — reasons about VISION.md, RESOURCES.md, formula catalog, and project
state to create up to 5 total issues (including promotions) prioritized by
leverage. Phase 3 (journal-and-memory): write daily journal entry (committed to
git) and update `planner/MEMORY.md` (committed to git). Phase 4 (commit-and-pr):
one commit with all file changes, push, create PR. AGENTS.md maintenance is
handled by the Gardener.

**Trigger**: `planner-run.sh` runs daily via cron (accepts an optional project
TOML argument, defaults to `projects/disinto.toml`). It creates a tmux session
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

**Future direction**: The Predictor files prediction issues daily for the planner
to triage. The next step is evidence-gated deployment (see
`docs/EVIDENCE-ARCHITECTURE.md`): replacing human "ship it" decisions with
automated gates across dimensions (holdout, red-team, user-test, evolution
fitness, protocol metrics, funnel). Not yet implemented.

**Environment variables consumed**:
- `CODEBERG_TOKEN`, `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to opus by planner-run.sh)
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER`
