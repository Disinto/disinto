<!-- last-reviewed: 9ec0c0221032979bd4440b9fd67f2072f1de01be -->
# Planner Agent

**Role**: Strategic planning using a Prerequisite Tree (Theory of Constraints),
executed directly from cron via tmux + Claude.
Phase 0 (preflight): pull latest code, load persistent memory and prerequisite
tree from `planner/MEMORY.md` and `planner/prerequisite-tree.md`. Also reads
all available formulas: factory formulas (`$FACTORY_ROOT/formulas/*.toml`) and
project-specific formulas (`$PROJECT_REPO_ROOT/formulas/*.toml`). Phase 1
(prediction-triage): triage `prediction/unreviewed` issues filed by the
Predictor — for each prediction: promote to action, promote to backlog, watch
(relabel to prediction/backlog), or dismiss with reasoning. Phase 2
(update-prerequisite-tree): scan repo state + open/closed issues, mark resolved
prerequisites, discover new ones, update the tree. Phase 3
(file-at-constraints): identify the top 3 unresolved prerequisites that block
the most downstream objectives — file issues at these constraints as either
`backlog` (code changes, dev-agent) or `action` (run existing formula,
action-agent). Action issues count toward the 3-issue constraint budget — they
are strategic investments, not maintenance.
Phase 4 (journal-and-memory): write updated prerequisite tree + daily journal
entry (committed to git) and update `planner/MEMORY.md` (committed to git).
Phase 5 (commit-and-pr): one commit with all file changes, push, create PR.
AGENTS.md maintenance is handled by the Gardener.

**Artifacts use `$PROJECT_REPO_ROOT`**: All planner artifacts (journal,
prerequisite tree, memory, vault state) live under `$PROJECT_REPO_ROOT/planner/`
and `$PROJECT_REPO_ROOT/vault/`, not `$FACTORY_ROOT`. Each project manages its
own planner state independently.

**Trigger**: `planner-run.sh` runs daily via cron (accepts an optional project
TOML argument, defaults to `projects/disinto.toml`). It creates a tmux session
with `claude --model opus`, injects `formulas/run-planner.toml` as context,
monitors the phase file, and cleans up on completion or timeout. No action
issues — the planner is a nervous system component, not work.

**Key files**:
- `planner/planner-run.sh` — Cron wrapper + orchestrator: lock, memory guard,
  sources disinto project config, creates tmux session, injects formula prompt,
  monitors phase file, handles crash recovery, cleans up
- `formulas/run-planner.toml` — Execution spec: six steps (preflight,
  prediction-triage, update-prerequisite-tree, file-at-constraints,
  journal-and-memory, commit-and-pr) with `needs` dependencies. Claude
  executes all steps in a single interactive session with tool access
- `planner/prerequisite-tree.md` — Prerequisite tree: versioned constraint
  map linking VISION.md objectives to their prerequisites. Planner owns the
  tree, humans steer by editing VISION.md. Tree grows organically as the
  planner discovers new prerequisites during runs
- `planner/MEMORY.md` — Persistent memory across runs (committed to git)
- `planner/journal/*.md` — Daily raw logs from each planner run (committed to git)

**Constraint focus**: The planner uses Theory of Constraints to avoid premature
issue filing. Only the top 3 unresolved prerequisites that block the most
downstream objectives get filed as issues. Everything else exists in the
prerequisite tree but NOT as issues. This prevents the "spray issues across
all milestones" pattern that produced premature work in planner v1/v2.

**Environment variables consumed**:
- `CODEBERG_TOKEN`, `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to opus by planner-run.sh)
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER`
