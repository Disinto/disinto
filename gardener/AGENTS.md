<!-- last-reviewed: 8d321681213a455ed01eefc13ccbd9af7daae453 -->
# Gardener Agent

**Role**: Backlog grooming — detect duplicate issues, missing acceptance
criteria, oversized issues, stale issues, and circular dependencies. Enforces
the quality gate: strips the `backlog` label from issues that lack acceptance
criteria checkboxes (`- [ ]`) or an `## Affected files` section. Invokes
Claude to fix what it can; files vault items for what it cannot.

**Trigger**: `gardener-run.sh` runs 4x/day via cron. Sources `lib/guard.sh` and
calls `check_active gardener` first — skips if `$FACTORY_ROOT/state/.gardener-active`
is absent. Then creates a tmux session with `claude --model sonnet`, injects
`formulas/run-gardener.toml` as context, monitors the phase file, and cleans up
on completion or timeout (2h max session). No action issues — the gardener runs
directly from cron like the planner, predictor, and supervisor.

**Key files**:
- `gardener/gardener-run.sh` — Cron wrapper + orchestrator: lock, memory guard,
  sources disinto project config, creates tmux session, injects formula prompt,
  monitors phase file via custom `_gardener_on_phase_change` callback (passed to
  `run_formula_and_monitor`). Stays alive through CI/review/merge cycle after
  `PHASE:awaiting_ci` — injects CI results and review feedback, re-signals
  `PHASE:awaiting_ci` after fixes, signals `PHASE:awaiting_review` on CI pass.
  Executes pending-actions manifest after PR merge.
- `formulas/run-gardener.toml` — Execution spec: preflight, grooming, dust-bundling,
  agents-update, commit-and-pr
- `gardener/pending-actions.json` — Manifest of deferred repo actions (label changes,
  closures, comments, issue creation). Written during grooming steps, committed to the
  PR, reviewed alongside AGENTS.md changes, executed by gardener-run.sh after merge.

**Environment variables consumed**:
- `FORGE_TOKEN`, `FORGE_GARDENER_TOKEN` (falls back to FORGE_TOKEN), `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by gardener-run.sh)

**Lifecycle**: gardener-run.sh (cron 0,6,12,18) → `check_active gardener` → lock + memory guard →
load formula + context → create tmux session →
Claude grooms backlog (writes proposed actions to manifest), bundles dust,
updates AGENTS.md, commits manifest + docs to PR →
`PHASE:awaiting_ci` (stays alive) → CI pass → `PHASE:awaiting_review` →
review feedback → address + re-signal → merge → gardener-run.sh executes
manifest actions via API → `PHASE:done`. When blocked on external resources
or human decisions, files a vault item instead of escalating.
