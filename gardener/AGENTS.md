<!-- last-reviewed: 17a89f4e000583cac9ea2992cb2678945e3bd62d -->
# Gardener Agent

**Role**: Backlog grooming — detect duplicate issues, missing acceptance
criteria, oversized issues, stale issues, and circular dependencies. Enforces
the quality gate: strips the `backlog` label from issues that lack acceptance
criteria checkboxes (`- [ ]`) or an `## Affected files` section. Invokes
Claude to fix what it can; files vault items for what it cannot.

**Trigger**: `gardener/gardener-step.sh` is invoked by the polling loop in `docker/agents/entrypoint.sh`
on every iteration (line 602-604). Guards against overlap via `flock` (line 79) and a
`pgrep` check in the entrypoint. Sources `lib/guard.sh` and calls `check_active gardener`.
**Classify-then-dispatch**: each invocation runs `gardener/classify.sh` which emits one
`{"task":...}` JSON line (or empty for CLEAN). CLEAN exits immediately (~1s, no slot used).
Otherwise loads the matching `formulas/<task>.toml` and dispatches a single task via
`lib/formula-session.sh` (one `claude --model sonnet` session, no tmux). The step driver
itself has no phase-monitoring — after `agent_run` completes, it walks the PR to merge
via `pr_walk_to_merge` (3 retries, 5s backoff). No action issues — the gardener runs as
part of the polling loop alongside the planner, predictor, and supervisor.

**Key files**:
- `gardener/gardener-step.sh` — Per-iteration step driver (~250 lines): acquires `flock`,
  runs `classify.sh` to emit one task JSON, dispatches via `formula-session.sh` (single
  claude session, no tmux/phase-monitoring), walks PR to merge after completion.
- `gardener/classify.sh` — Task classifier (~760 lines): scans backlog for issues needing
  grooming; emits one `{"task":...}` JSON line or empty for CLEAN.
- `formulas/run-gardener.toml` — Execution spec: preflight, grooming, dust-bundling,
  agents-update, commit-and-pr
- `gardener/dust.jsonl` — Persistent dust accumulator (JSONL). Each line is a DUST
  item: `{"issue":NNN,"group":"...","title":"...","reason":"...","ts":"..."}`.
  30-day TTL; groups of 3+ distinct issues auto-bundled into single backlog issues.
- `gardener/pending-actions.jsonl` — Intermediate manifest of proposed repo actions
  (label changes, closures, comments, issue creation, body edits). Written during
  grooming steps as one JSON object per line.
- `gardener/pending-actions.json` — Final manifest (JSON array) committed to the PR,
  reviewed alongside AGENTS.md changes, executed by gardener-step.sh after merge.
  Converted from JSONL at commit time.

**Environment variables consumed**:
- `FORGE_TOKEN`, `FORGE_GARDENER_TOKEN` (falls back to FORGE_TOKEN), `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`. `FORGE_TOKEN_OVERRIDE` is exported to `$FORGE_GARDENER_TOKEN` before sourcing env.sh so the gardener-bot identity survives re-sourcing (#762).
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by gardener-step.sh)

**Entrypoint switch (#872)**: `docker/agents/entrypoint.sh` now calls
`gardener/gardener-step.sh` (per-iteration step driver) instead of the old
one-shot `gardener-run.sh`. This replaced the 6h batch model with per-iteration
classify-then-dispatch.
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

**Lifecycle**: entrypoint calls `gardener-step.sh` each iteration → `gardener-step.sh`
acquires `flock` → runs `classify.sh` → CLEAN exits (~1s, no slot) or task JSON
dispatches to `formulas/<task>.toml` via `formula-session.sh` → single claude session
executes the formula (edits repo via `gardener-edit.sh` helpers, opens PR) →
`pr_walk_to_merge` walks PR through CI/review/merge cycle → journal entry written.
When blocked on external resources or human decisions, files a vault item instead of escalating.
