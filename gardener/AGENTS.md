<!-- last-reviewed: 17a89f4 -->
# Gardener Agent

**Role**: Backlog grooming — detect duplicate issues, missing acceptance
criteria, oversized issues, stale issues, and circular dependencies. Enforces
the quality gate: strips the `backlog` label from issues that lack acceptance
criteria checkboxes (`- [ ]`) or an `## Affected files` section. Invokes
Claude to fix what it can; files vault items for what it cannot.

**Trigger**: `gardener/gardener-step.sh` is invoked by the polling loop in
`docker/agents/entrypoint.sh` every iteration (POLL_INTERVAL, typically 5 min).
Sources `lib/guard.sh` and calls `check_active gardener` first. Each invocation
does one task: `classify.sh` emits a task JSON (or empty for CLEAN); CLEAN exits
immediately (~1s, no slot used). Otherwise the task formula is dispatched in a
single claude session via `lib/formula-session.sh`. The script acquires
`/tmp/gardener-step.lock` via `flock -n` — if another step is in flight, exits
silently. The gardener runs as part of the polling loop alongside the planner,
predictor, and supervisor.

**Key files**:
- `gardener/gardener-step.sh` — Per-iteration task driver: acquires flock, runs
  `classify.sh` to emit one task JSON (or empty for CLEAN), dispatches task
  formula via `lib/formula-session.sh`, sets up scratch worktree, runs single
  claude session, detects PR opened by formula, walks PR to merge. ~250 lines.
- `gardener/classify.sh` — Task classifier: scans backlog for issues matching
  task heuristics (blocked, starving, tech-debt, subissues), emits one JSON task
  or empty string for CLEAN. ~760 lines.
- `gardener/gardener-run.sh` — Legacy monolithic batch driver (replaced by
  `gardener-step.sh` as per-iteration driver in #872). Still exists for CI cron
  and smoke tests.
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
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by gardener-step.sh)

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

**Lifecycle**: entrypoint → `gardener-step.sh` (every iteration) → acquires
flock → runs `classify.sh` → CLEAN exits immediately (~1s, no slot used) or
task formula dispatched → load formula + context (`.profile` lessons, AGENTS.md)
→ single claude session via `agent_run --worktree` → formula edits repo
(injected helpers: `gardener_edit_body`, `gardener_add_label`, etc.) →
detect PR opened by formula → `pr_walk_to_merge` (up to 3 attempts, 5 min each)
→ on merge: fetch + pull + mirror_push → journal entry. When blocked on external
resources or human decisions, formula files a vault item instead of escalating.

**Notable changes since last review**:
- `docker/agents/entrypoint.sh` switched from calling `gardener-run.sh` (monolithic
  batch every GARDENER_INTERVAL) to `gardener/gardener-step.sh` (per-iteration step
  driver, single task per cycle, #872) — primary behavioral change.
- `gardener/gardener-run.sh` now documented as legacy; `gardener-step.sh` (~250 lines)
  and `gardener/classify.sh` (~760 lines) are the new per-iteration drivers.
- `lib/gardener-pr.sh` sourced by gardener-step.sh; `detect_pr_number("chore/gardener-")`
  extracts PR number from formula's scratch worktree commits (#762, #906).
- Engagement evidence loaded from `evidence/engagement/*.json` to inform formula context.
- `BLOCKED_NUDGE_AGE_DAYS` (7d) renamed to `BLOCKED_NUDGE_AGE_HOURS` (4h); old
  variable removed.
