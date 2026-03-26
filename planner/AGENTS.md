<!-- last-reviewed: cebcb8c13ab7948fc794f49c379ed34570e45652 -->
# Planner Agent

**Role**: Strategic planning using a Prerequisite Tree (Theory of Constraints),
executed directly from cron via tmux + Claude.
Phase 0 (preflight): pull latest code, load persistent memory and prerequisite
tree from `planner/MEMORY.md` and `planner/prerequisite-tree.md`. Also reads
all available formulas: factory formulas (`$FACTORY_ROOT/formulas/*.toml`) and
project-specific formulas (`$PROJECT_REPO_ROOT/formulas/*.toml`). Phase 1
(prediction-triage): triage `prediction/unreviewed` issues filed by the
Predictor — for each prediction, the planner **must** act or dismiss with a
stated reason (no fence-sitting, no `prediction/backlog` label). Actions:
promote to a real issue (relabel to `prediction/actioned`, close) or
dismiss (comment reason, relabel to `prediction/dismissed`, close).
The planner has a per-run action budget — it cannot defer indefinitely.
Dismissed predictions get re-filed by the predictor with stronger evidence
if still valid. Phase 2
(update-prerequisite-tree): scan repo state + open/closed issues, mark resolved
prerequisites, discover new ones, update the tree. **Also scans comments on
referenced issues for bounce/stuck signals** (BOUNCED, ESCALATED, LABEL_CHURN)
to detect issues ping-ponging between backlog and underspecified. Phase 3
(file-at-constraints): identify the top 3 unresolved prerequisites that block
the most downstream objectives — file issues as either `backlog` (code changes,
dev-agent) or `action` (run existing formula, action-agent). **Stuck issues
(detected BOUNCED/LABEL_CHURN) are dispatched to the `groom-backlog` formula
in breakdown mode instead of being re-promoted** — this breaks the ping-pong
loop by splitting them into dev-agent-sized sub-issues.
Phase 4 (journal-and-memory): write updated prerequisite tree + daily journal
entry (committed to git) and update `planner/MEMORY.md` (committed to git).
Phase 5 (commit-and-pr): one commit with all file changes, push, create PR.
AGENTS.md maintenance is handled by the Gardener.

**Artifacts use `$PROJECT_REPO_ROOT`**: All planner artifacts (journal,
prerequisite tree, memory, vault state) live under `$PROJECT_REPO_ROOT/planner/`
and `$PROJECT_REPO_ROOT/vault/`, not `$FACTORY_ROOT`. Each project manages its
own planner state independently.

**Trigger**: `planner-run.sh` runs daily via cron (accepts an optional project
TOML argument, defaults to `projects/disinto.toml`). Sources `lib/guard.sh` and
calls `check_active planner` first — skips if `$FACTORY_ROOT/state/.planner-active`
is absent. Then creates a tmux session with `claude --model opus`, injects
`formulas/run-planner.toml` as context, monitors the phase file, and cleans up
on completion or timeout. No action issues — the planner is a nervous system
component, not work.

**Key files**:
- `planner/planner-run.sh` — Cron wrapper + orchestrator: lock, memory guard,
  sources disinto project config, builds structural analysis via `lib/formula-session.sh:build_graph_section()`,
  creates tmux session, injects formula prompt, monitors phase file, handles crash recovery, cleans up
- `formulas/run-planner.toml` — Execution spec: six steps (preflight,
  prediction-triage, update-prerequisite-tree, file-at-constraints,
  journal-and-memory, commit-and-pr) with `needs` dependencies. Claude
  executes all steps in a single interactive session with tool access
- `formulas/groom-backlog.toml` — Dual-mode formula: grooming (default) or
  breakdown (dispatched by planner for bounced/stuck issues — splits the issue
  into dev-agent-sized sub-issues, removes `underspecified` label)
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
- `FORGE_TOKEN`, `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to opus by planner-run.sh)
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER`
