<!-- last-reviewed: 8d321681213a455ed01eefc13ccbd9af7daae453 -->
# Planner Agent

**Role**: Strategic planning using a Prerequisite Tree (Theory of Constraints),
executed directly from cron via tmux + Claude.
Phase 0 (preflight): pull latest code, load persistent memory and prerequisite
tree from `$OPS_REPO_ROOT/knowledge/planner-memory.md` and `$OPS_REPO_ROOT/prerequisites.md`. Also reads
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
referenced issues for bounce/stuck signals** (BOUNCED, LABEL_CHURN)
to detect issues ping-ponging between backlog and underspecified. Issues that
need human decisions or external resources are filed as vault procurement items
(`$OPS_REPO_ROOT/vault/pending/*.md`) instead of being escalated. Phase 3
(file-at-constraints): identify the top 3 unresolved prerequisites that block
the most downstream objectives — file issues using a **template-or-vision gate**:
read issue templates from `.codeberg/ISSUE_TEMPLATE/*.yaml`, attempt to fill
template fields (affected_files ≤3, acceptance_criteria ≤5, single clear approach),
then apply complexity test: if work touches one subsystem with no design forks,
file as `backlog` using matching template (bug/feature/refactor); otherwise
label `vision` with problem statement and why it's vision-sized. **Human-blocked
issues are routed through the vault** — the planner files an actionable procurement
item (`$OPS_REPO_ROOT/vault/pending/<project>-<slug>.md` with What/Why/Human action/Factory
will then sections) and marks the prerequisite as blocked-on-vault in the tree.
Deduplication: checks pending/ + approved/ + fired/ before creating.
Phase 4 (journal-and-memory): write updated prerequisite tree + daily journal
entry (committed to ops repo) and update `$OPS_REPO_ROOT/knowledge/planner-memory.md`.
Phase 5 (commit-ops): commit all ops repo changes, push directly.
AGENTS.md maintenance is handled by the Gardener.

**Artifacts use `$OPS_REPO_ROOT`**: All planner artifacts (journal,
prerequisite tree, memory, vault state) live under `$OPS_REPO_ROOT/`.
Each project manages its own planner state in a separate ops repo.

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
- `formulas/groom-backlog.toml` — Grooming formula for backlog triage and
  grooming. (Note: the planner no longer dispatches breakdown mode — complex
  issues are labeled `vision` instead.)
- `$OPS_REPO_ROOT/prerequisites.md` — Prerequisite tree: versioned constraint
  map linking VISION.md objectives to their prerequisites. Planner owns the
  tree, humans steer by editing VISION.md. Tree grows organically as the
  planner discovers new prerequisites during runs
- `$OPS_REPO_ROOT/knowledge/planner-memory.md` — Persistent memory across runs (in ops repo)


**Constraint focus**: The planner uses Theory of Constraints to avoid premature
issue filing. Only the top 3 unresolved prerequisites that block the most
downstream objectives get filed as issues. Everything else exists in the
prerequisite tree but NOT as issues. This prevents the "spray issues across
all milestones" pattern that produced premature work in planner v1/v2.

**Environment variables consumed**:
- `FORGE_TOKEN`, `FORGE_PLANNER_TOKEN` (falls back to FORGE_TOKEN), `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`, `OPS_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to opus by planner-run.sh)
