<!-- last-reviewed: 251d160e213b19a4fcc0cd8f8e3be9ea3283887f -->
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
  `run_formula_and_monitor`, executes pending-actions manifest after PR merge
- `formulas/run-gardener.toml` — Execution spec: preflight, grooming, dust-bundling, blocked-review, agents-update, commit-and-pr
- `gardener/pending-actions.json` — Manifest of deferred repo actions (label changes,
  closures, comments, issue creation). Written during grooming steps, committed to the
  PR, reviewed alongside AGENTS.md changes, executed by gardener-run.sh after merge.

**Environment variables consumed**:
- `CODEBERG_TOKEN`, `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by gardener-run.sh)
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER`

**Lifecycle**: gardener-run.sh (cron 0,6,12,18) → lock + memory guard →
consume escalation replies → load formula + context → create tmux session →
Claude grooms backlog (writes proposed actions to manifest), bundles dust,
reviews blocked issues, updates AGENTS.md, commits manifest + docs to PR →
review-agent reviews all proposed actions → after merge, gardener-run.sh
executes manifest actions via API → `PHASE:done`.
