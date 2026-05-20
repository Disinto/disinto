<!-- last-reviewed: 17a89f4545dc95e3d42dd672f764f72dc171c831 -->
# Gardener Agent

**Role**: Backlog grooming — detect duplicate issues, missing acceptance
criteria, oversized issues, stale issues, and circular dependencies. Enforces
the quality gate: strips the `backlog` label from issues that lack acceptance
criteria checkboxes (`- [ ]`) or an `## Affected files` section. Invokes
Claude to fix what it can; files vault items for what it cannot.

**Trigger**: `gardener/gardener-step.sh` is invoked by the polling loop in
`docker/agents/entrypoint.sh` on every iteration (same cadence as dev-poll/review-poll).
The step driver acquires a `flock -n` lock on `/tmp/gardener-step.lock`; if another step
is already in flight, it exits silently. Sources `lib/guard.sh` and calls
`check_active gardener` first — skips if `$FACTORY_ROOT/state/.gardener-active` is absent.
**Early-exit optimization**: `classify.sh` emits `CLEAN` (empty output) when there is no
actionable work; the step driver exits immediately (~1s, no model invoked, no tokens
consumed). Otherwise, dispatches exactly one task via a single `claude` session
(`agent_run`) with the selected formula's prompt. The gardener runs alongside the planner,
predictor, and supervisor on every polling iteration.

**Key files**:
- `gardener/gardener-step.sh` — Per-iteration step driver: acquires `flock`, runs
  `classify.sh` → emits one JSON task (or empty for CLEAN), dispatches to
  `formulas/<task>.toml` via `lib/formula-session.sh`, runs a single `claude` session,
  detects PR opened by the formula, walks PR to merge via `pr_walk_to_merge`.
- `gardener/classify.sh` — Classifies backlog state and emits one `{"task":..., ...}` JSON
  line (or empty for CLEAN). Evaluates task types: blocker-starving, promote-tech-debt,
  revisit-blocked, file-subissues.
- `gardener/gardener-run.sh` — Legacy monolithic batch driver (replaced by step driver in
  #872). Still present for manual use but NOT invoked by the polling loop.
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

**Notable changes since last review**:
- Entrypoint switched from calling `gardener/gardener-run.sh` to `gardener/gardener-step.sh`
  as the per-iteration driver (#872). The old batch model is preserved for manual use.
- `gardener/gardener-run.sh` now sources `lib/gardener-pr.sh` and uses
  `detect_pr_number("chore/gardener-")` instead of manual PR detection logic.
- `gardener/gardener-run.sh` added engagement evidence loading from ops repo
  (`evidence/engagement/*.json`) for website addressable decisions (#975).

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
closed; for operator-mediated blocks older than `BLOCKED_NUDGE_AGE_HOURS`
(default 4h) it posts a single nudge comment per 4-hour window using the
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

**Lifecycle**: `gardener/gardener-step.sh` (invoked by polling loop each iteration,
`check_active gardener`) → `flock` + memory guard → `classify.sh` emits task or CLEAN
→ CLEAN exits (~1s, no model) → otherwise load formula + context → single `claude`
session (`agent_run`) executes one task (e.g., promote tech-debt, revisit blocked,
file subissues) → detect PR opened by formula → `pr_walk_to_merge` walks PR through
CI + review → merge → mirror push. When blocked on external resources or human
decisions, the formula files a vault item instead of escalating.
