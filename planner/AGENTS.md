<!-- last-reviewed: 510d3225cb46fd116ff9aa7709f4509ac348afa4 -->
# Planner Agent

**Role**: Strategic planning using a Prerequisite Tree (Theory of Constraints),
invoked by the polling loop in `docker/agents/entrypoint.sh` every 12 hours
(`PLANNER_INTERVAL`, default 43200s; #1388). The planning session is a one-shot
`claude -p` run via `agent_run` (`lib/agent-sdk.sh`) with model opus — no
tmux, no phase file.
The v4 formula (`formulas/run-planner.toml`, graph-driven) has three steps —
**preflight**, **triage-and-plan**, **commit-ops-changes** — executed in one
one-shot session:

- **preflight**: pull latest code, load persistent memory and prerequisite
  tree from `$OPS_REPO_ROOT/knowledge/planner-memory.md` and `$OPS_REPO_ROOT/prerequisites.md`,
  and read the graph report (orphans, cycles, thin objectives, bottlenecks)
  that the wrapper injects into the prompt.
- **triage-and-plan** (unifies the former prediction-triage,
  update-prerequisite-tree, and file-at-constraints steps): triage
  `prediction/unreviewed` issues filed by the Predictor — for each prediction,
  the planner **must** act or dismiss with a stated reason (no fence-sitting,
  no `prediction/backlog` label). Actions: promote to a real issue (relabel to
  `prediction/actioned`, close) or dismiss (comment reason, relabel to
  `prediction/dismissed`, close). The planner has a per-run action budget — it
  cannot defer indefinitely. Dismissed predictions get re-filed by the
  predictor with stronger evidence if still valid. Reads the available
  formulas (`$FACTORY_ROOT/formulas/*.toml`, `$PROJECT_REPO_ROOT/formulas/*.toml`)
  for promotion decisions, and uses the tea helpers in `lib/tea-helpers.sh`
  (e.g. `tea_file_issue`, `tea_relabel`). Then updates the prerequisite tree
  from the graph report + open/closed issues. **Also scans comments on
  referenced issues for bounce/stuck signals** (BOUNCED, LABEL_CHURN)
  to detect issues ping-ponging between backlog and underspecified. Issues that
  need human decisions or external resources are filed as vault procurement items
  (`$OPS_REPO_ROOT/vault/pending/*.md`) instead of being escalated. Then files
  at constraints: identify the top 5 unresolved prerequisites that block the
  most downstream objectives — file issues using a **template-or-vision gate**:
  read issue templates from `.forgejo/ISSUE_TEMPLATE/*.yaml`, attempt to fill
  template fields (affected_files ≤3, acceptance_criteria ≤5, single clear
  approach), then apply complexity test: if work touches one subsystem with no
  design forks, file as `backlog` using matching template (bug/feature/refactor);
  otherwise label `vision` with problem statement and why it's vision-sized.
  **Human-blocked issues are routed through the vault** — the planner files an
  actionable procurement item (`$OPS_REPO_ROOT/vault/pending/<project>-<slug>.md`
  with What/Why/Human action/Factory will then sections) and marks the
  prerequisite as blocked-on-vault in the tree. Deduplication: checks
  pending/ + approved/ + fired/ before creating.
- **commit-ops-changes**: write the updated prerequisite tree + memory
  (`planner-memory.md` refreshed every 5th run) and commit all ops repo
  changes to the `planner/run-YYYY-MM-DD` branch — no direct push to main.
  The wrapper then creates a PR and walks it to merge via review-bot
  (`pr_create` → `pr_walk_to_merge`), mirroring the architect's ops flow, and
  writes the journal entry via `profile_write_journal` after the session
  (journal writing is not a formula step).
AGENTS.md maintenance is handled by the Gardener.

**Artifacts use `$OPS_REPO_ROOT`**: All planner artifacts (journal,
prerequisite tree, memory, vault state) live under `$OPS_REPO_ROOT/`.
Each project manages its own planner state in a separate ops repo.

**Trigger**: `planner-run.sh` is invoked by the polling loop in
`docker/agents/entrypoint.sh` every 12 hours (iteration math at lines
794-804, #1388), which passes its project TOML through. Accepts an
optional project TOML argument, defaults to `projects/disinto.toml`.
Sources `lib/guard.sh` and calls `check_active planner` first — skips if
`$FACTORY_ROOT/state/.planner-active` is absent. Then creates the
`planner/run-YYYY-MM-DD` ops branch and runs the planning session one-shot via
`agent_run` (`lib/agent-sdk.sh`) — one-shot `claude -p` with model opus, no
tmux and no phase file; the bash script IS the state machine. A
resource-limit exit from `agent_run` (rc 124 = wall-clock timeout) is logged,
not fatal — the PR walk decides the outcome (#1164). No action issues — the
planner is a nervous system component, not work.

**Formula (#1334)**: `planner-run.sh` always loads `formulas/run-planner.toml`
before the session lifecycle begins — the research formula from #1314 was
deleted, and the kind key itself is gone (#1338); oak instances differ by
`ops/pack.toml`, not by a project kind, so research boxes run the same
planner formula.

**Key files**:
- `planner/planner-run.sh` — Wrapper + orchestrator: run lock + `check_active planner`
  guard, sources the project config, builds the structural analysis graph via
  `lib/formula-session.sh:build_graph_section()` (injected into the prompt),
  creates the `planner/run-YYYY-MM-DD` ops branch, runs the agent one-shot via
  `agent_run` (`lib/agent-sdk.sh`), guards a resource-limit exit (rc 124,
  #1164) so the PR walk still runs, then creates the ops PR and walks it to
  merge, writes the journal via `profile_write_journal`, and cleans up.
  **Dev-loop tape (#1409)**: after the session closes, `planner_tape_tick`
  diffs the current open-issue set against a pre-session snapshot and, for each
  newly filed `backlog` issue, appends one dev-loop proposal record via
  `emit_planner_proposal` (flat-prior `forecast` `{"p_success":0.5,"est_cost":0,
  "est_dvision":0}`; `id` = `formula_tape_ulid`). Total — a tape or forge-API
  failure logs a WARNING and returns 0, so it can never abort the planner run.
- `formulas/run-planner.toml` — The execution spec (the only planner formula,
  #1334; v4, graph-driven, tea helpers): three steps with `needs` dependencies
  — preflight, triage-and-plan (unifies the former prediction-triage /
  update-prerequisite-tree / file-at-constraints steps), commit-ops-changes.
  Claude executes all steps in a single one-shot session with tool access
- `formulas/groom-backlog.toml` — Grooming formula for backlog triage and
  grooming. (Note: the planner no longer dispatches breakdown mode — complex
  issues are labeled `vision` instead.)
- `$OPS_REPO_ROOT/prerequisites.md` — Prerequisite tree: versioned constraint
  map linking VISION.md objectives to their prerequisites. Planner owns the
  tree, humans steer by editing VISION.md. Tree grows organically as the
  planner discovers new prerequisites during runs
- `$OPS_REPO_ROOT/knowledge/planner-memory.md` — Persistent memory across runs (in ops repo)


**Constraint focus**: The planner uses Theory of Constraints to avoid premature
issue filing. Only the top 5 unresolved prerequisites that block the most
downstream objectives get filed as issues. Everything else exists in the
prerequisite tree but NOT as issues. This prevents the "spray issues across
all milestones" pattern that produced premature work in planner v1/v2.

**Environment variables consumed**:
- `FORGE_TOKEN`, `FORGE_PLANNER_TOKEN` (falls back to FORGE_TOKEN), `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`, `OPS_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to opus by planner-run.sh)
