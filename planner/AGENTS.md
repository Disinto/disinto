<!-- last-reviewed: 5bcdcc174a7ae95c1bbcf019e644c36264f37973 -->
# Planner Agent

**Role**: Pitches one sprint toward the vision, or writes nothing. Invoked
by the polling loop in `docker/agents/entrypoint.sh` every 12 hours
(`PLANNER_INTERVAL`, default 43200s; #1388). The run calls `planner_pitch_or_idle`. A missing rung is a pitch opened in bash, with no session. Otherwise the session is one `agent_run` (`lib/agent-sdk.sh`); the model is the job's, not a hardcoded opus. No tmux, no phase file.
The formula (`formulas/run-planner.toml`) has one step, **propose**: write at most one pitch file, or nothing. It does not triage predictions, does not write prerequisites.md, does not file issues, and does not pitch an access request.
AGENTS.md maintenance is handled by the Gardener.

**Artifacts use `$OPS_REPO_ROOT`**: Planner journal entries live under
`$OPS_REPO_ROOT/`. The prerequisite tree is retired; the planner does not
read or write it, and it does not write vault state.
Each project manages its own planner state in a separate ops repo.

**Trigger**: `planner-run.sh` is invoked by the polling loop in
`docker/agents/entrypoint.sh` every 12 hours (iteration math at lines
794-804, #1388), which passes its project TOML through. Accepts an
optional project TOML argument, defaults to `projects/disinto.toml`.
Sources `lib/guard.sh` and calls `check_active planner` first — skips if
`$FACTORY_ROOT/state/.planner-active` is absent. Then calls
`planner_pitch_or_idle` (`planner/pitch-or-idle.sh`). A missing rung is a
pitch opened in bash, with no session. Otherwise the session is one
`agent_run` (`lib/agent-sdk.sh`); the model is the job's, not a hardcoded
opus. No tmux, no phase file; the bash script IS the state machine. No
action issues — the planner is a nervous system component, not work.

**Formula (#1334)**: `planner-run.sh` always loads `formulas/run-planner.toml`
before the session lifecycle begins — the research formula from #1314 was
deleted, and the kind key itself is gone (#1338); oak instances differ by
`ops/pack.toml`, not by a project kind, so research boxes run the same
planner formula.

**Key files**:
- `planner/planner-run.sh` — Wrapper + orchestrator: run lock + `check_active planner`
  guard, sources the project config, builds the structural analysis graph via
  `lib/formula-session.sh:build_graph_section()` (injected into the prompt),
  calls `planner_pitch_or_idle` (`planner/pitch-or-idle.sh`). A rung pitch is opened there even when its probe is not in the ops repo yet, and the session does not run. Otherwise it runs `agent_run`, then `planner_publish_session_pitch`, which opens a pitch whose effect is already in the ops repo or is added by that same pitch. It does not create `planner/run-YYYY-MM-DD` and does not call `pr_walk_to_merge`. Writes the journal via `profile_write_journal`, and cleans up.
  **Dev-loop tape (#1409, #1476)**: the dev-loop *proposal* for a filed backlog
  issue is owned by the pick (dev-poll claims the issue and appends the
  `approved` proposal) — the pick is the sample. #1409 had added a planner-side
  `emit_planner_proposal` (via `planner_tape_tick`) that wrote a *second*
  `approved` row, pre-approving work the factory had not run; #1476 removes that
  emission. `planner_tape_tick` is now an intentional no-op stub kept as the
  guarded call site after the session closes (verified by
  `tests/acceptance/issue-1476.sh`), and `emit_planner_proposal` / the pre-session
  open-issue snapshot are deleted (they had no remaining caller). The run-lifecycle
  tape records (`formula_session_start` / `formula_session_end`) are unchanged.
- `formulas/run-planner.toml` — One step, propose: write at most one pitch file to `$PLANNER_PITCH_FILE`, or nothing. When the effect probe is not already in the ops repo, also write it to `$PLANNER_PROBE_FILE`. No prediction triage, no prerequisite tree, no issue filing, no access request.
  Claude executes all steps in a single one-shot session with tool access
- `formulas/groom-backlog.toml` — Grooming formula for backlog triage and
  grooming. (Note: the planner no longer dispatches breakdown mode — complex
  issues are labeled `vision` instead.)
- `planner/ladder.sh` — `ladder_lowest_gap` prints the lowest missing or
  challenged capability rung (`sense`, `provision`, `reach`, `deploy`,
  `replicate`), or nothing. No network. Called by `planner/pitch-or-idle.sh`.
- `planner/pitch-open.sh` — `planner_pitch_open` opens one ops PR titled
  `architect: <title>` that adds `sprints/<slug>.md`. When given a probe file
  and a `probes/<name>.sh` path, it adds that file on the same branch before
  the pull is posted. Returns 0 when `planner-bot` already has an open
  `architect:` PR. Called by `planner/pitch-or-idle.sh`.
- `planner/pitch-or-idle.sh` — `planner_pitch_or_idle` opens the lowest
  missing rung as a pitch, prints `held` when one is already open, or prints
  `session`. `planner_publish_session_pitch` opens the session pitch. Does
  not source `lib/env.sh`. Does not call `agent_run`.
- `$OPS_REPO_ROOT/prerequisites.md` — Retired. The planner does not read or write it.
- `$OPS_REPO_ROOT/knowledge/planner-memory.md` — Retired (#1477). The planner does not read or write it.


**Constraint focus**: The planner pitches one sprint or writes nothing. It does not file issues and does not pitch an access request.

**Environment variables consumed**:
- `FORGE_TOKEN`, `FORGE_PLANNER_TOKEN` (falls back to FORGE_TOKEN), `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`, `OPS_REPO_ROOT`
- `PRIMARY_BRANCH`. `planner-run.sh` does not set `CLAUDE_MODEL`.
