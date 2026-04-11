<!-- last-reviewed: 31f2cb7bfa38df3db8fbed28ec0899c412f06c49 -->
# Gardener Agent

**Role**: Backlog grooming — detect duplicate issues, missing acceptance
criteria, oversized issues, stale issues, and circular dependencies. Enforces
the quality gate: strips the `backlog` label from issues that lack acceptance
criteria checkboxes (`- [ ]`) or an `## Affected files` section. Invokes
Claude to fix what it can; files vault items for what it cannot.

**Trigger**: `gardener-run.sh` is invoked by the polling loop in `docker/agents/entrypoint.sh`
every 6 hours (iteration math at line 182-194). Sources `lib/guard.sh` and calls
`check_active gardener` first — skips if `$FACTORY_ROOT/state/.gardener-active` is absent.
**Early-exit optimization**: if no issues, PRs, or repo files have changed since the last
run (checked via Forgejo API and `git diff`), the model is not invoked — the run exits
immediately (no tmux session, no tokens consumed). Otherwise, creates a tmux session with
`claude --model sonnet`, injects `formulas/run-gardener.toml` as context, monitors the
phase file, and cleans up on completion or timeout (2h max session). No action issues —
the gardener runs as part of the polling loop alongside the planner, predictor, and supervisor.

**Key files**:
- `gardener/gardener-run.sh` — Polling loop participant + orchestrator: lock, memory guard,
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

**Lifecycle**: gardener-run.sh (invoked by polling loop every 6h, `check_active gardener`) →
lock + memory guard → load formula + context → create tmux session →
Claude grooms backlog (writes proposed actions to manifest), bundles dust,
updates AGENTS.md, commits manifest + docs to PR →
`PHASE:awaiting_ci` (stays alive) → CI pass → `PHASE:awaiting_review` →
review feedback → address + re-signal → merge → gardener-run.sh executes
manifest actions via API → `PHASE:done`. When blocked on external resources
or human decisions, files a vault item instead of escalating.
