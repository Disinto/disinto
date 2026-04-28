<!-- last-reviewed: e5360777096d323ba88086ae26726842d7e2e3ae -->
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
- `gardener/dust.jsonl` — Persistent dust accumulator (JSONL). Each line is a DUST
  item: `{"issue":NNN,"group":"...","title":"...","reason":"...","ts":"..."}`.
  30-day TTL; groups of 3+ distinct issues auto-bundled into single backlog issues.
- `gardener/pending-actions.jsonl` — Intermediate manifest of proposed repo actions
  (label changes, closures, comments, issue creation, body edits). Written during
  grooming steps as one JSON object per line.
- `gardener/pending-actions.json` — Final manifest (JSON array) committed to the PR,
  reviewed alongside AGENTS.md changes, executed by gardener-run.sh after merge.
  Converted from JSONL at commit time.

**Environment variables consumed**:
- `FORGE_TOKEN`, `FORGE_GARDENER_TOKEN` (falls back to FORGE_TOKEN), `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`. `FORGE_TOKEN_OVERRIDE` is exported to `$FORGE_GARDENER_TOKEN` before sourcing env.sh so the gardener-bot identity survives re-sourcing (#762).
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by gardener-run.sh)

**Per-task formula dispatch (#871, #902, #906, #912, #916)**: `gardener/gardener-step.sh` runs each
polling iteration; `classify.sh` emits one `{"task":..., ...}` JSON line that
selects a formula in `formulas/<task>.toml`. Current task types include
`blocker-starving-the-factory` (#906) — priority 1, surfaces a non-backlog
issue that a backlog issue depends on; the formula promotes the dep to
`backlog`, asks the operator for enrichment (`underspecified`), or flags the
parent as `blocked` when the dep is an external blocker —
`promote-tech-debt` (#912) — priority 4, surfaces a `tech-debt`-labeled
issue passing the impact/effort heuristic; the formula adds `backlog` if the
body has `## Affected files` + `## Acceptance criteria`, otherwise marks it
`underspecified` so the sibling enrich-underspecified formula fills it in
next tick —
`revisit-blocked` (#916) — priority 6, surfaces a `blocked`-labeled issue
whose `updated_at` is older than `BLOCKED_REVISIT_AGE_SECS` (default 4h);
the formula parses dev-poll's latest `### Blocked — issue #N` comment
(see `lib/issue-lifecycle.sh::issue_block`) and removes `blocked` for
transient agent exits (`no_push`, `exhausted`, `stuck-pr`,
`ci_exhausted_poll`) or for `dep #X` references where `#X` has since been
closed; for operator-mediated blocks older than `BLOCKED_NUDGE_AGE_DAYS`
(default 7d) it posts a single nudge comment per 7-day window using the
`<!-- gardener: blocked-nudge -->` sentinel for idempotency — and
`file-subissues` (#902) — for each open ops-repo `architect:` PR with a
Forgejo APPROVED review state and no `## Filed:` marker, parse the pitch's
`<!-- filer:begin -->` block, POST each entry as a `backlog`-labeled
project-repo issue, and PATCH the PR body with `## Filed: #N1 #N2 ...`.
The task uses filer-bot identity (`FORGE_FILER_TOKEN`) so writes are auditable
separately from gardener-bot. Idempotency: classify skips PRs that already
carry `## Filed:`, and the formula dedups per-issue by exact title match
against existing project-repo issues to guard against POST-then-PATCH-failure
windows.

**Lifecycle**: gardener-run.sh (invoked by polling loop every 6h, `check_active gardener`) →
lock + memory guard → load formula + context → create tmux session →
Claude grooms backlog (writes proposed actions to manifest), bundles dust,
updates AGENTS.md, commits manifest + docs to PR →
`PHASE:awaiting_ci` (stays alive) → CI pass → `PHASE:awaiting_review` →
review feedback → address + re-signal → merge → gardener-run.sh executes
manifest actions via API → `PHASE:done`. When blocked on external resources
or human decisions, files a vault item instead of escalating.
