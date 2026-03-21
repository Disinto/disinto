<!-- last-reviewed: 80a64cd3e4d2836bfab3c46230a780e3e233125d -->
# Gardener Agent

**Role**: Backlog grooming — detect duplicate issues, missing acceptance
criteria, oversized issues, stale issues, and circular dependencies. Enforces
the quality gate: strips the `backlog` label from issues that lack acceptance
criteria checkboxes (`- [ ]`) or an `## Affected files` section. Invokes
Claude to fix or escalate to a human via Matrix.

**Trigger**: `gardener-run.sh` runs 4x/day via cron. It creates a tmux
session with `claude --model sonnet`, injects `formulas/run-gardener.toml`
with escalation replies as context, monitors the phase file, and cleans up
on completion or timeout (2h max session). No action issues — the gardener
runs directly from cron like the planner, predictor, and supervisor.

**Key files**:
- `gardener/gardener-run.sh` — Cron wrapper + orchestrator: lock, memory guard,
  consumes escalation replies, sources disinto project config, creates tmux session,
  injects formula prompt, monitors phase file, handles crash recovery via
  `run_formula_and_monitor`
- `formulas/run-gardener.toml` — Execution spec: preflight, grooming, dust-bundling, blocked-review, agents-update, commit-and-pr

**Environment variables consumed**:
- `CODEBERG_TOKEN`, `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by gardener-run.sh)
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER`

**Lifecycle**: gardener-run.sh (cron 0,6,12,18) → lock + memory guard →
consume escalation replies → load formula + context → create tmux session →
Claude grooms backlog, bundles dust, reviews blocked issues, updates AGENTS.md,
commits and creates PR → `PHASE:done`.
