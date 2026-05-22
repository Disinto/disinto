<!-- last-reviewed: 3e2be03bf716de6146022927ad428183c9f95f9f -->
# Gardener Agent

**Role**: Backlog grooming — detect duplicate issues, missing acceptance
criteria, oversized issues, stale issues, and circular dependencies. Enforces
the quality gate: strips the `backlog` label from issues that lack acceptance
criteria checkboxes (`- [ ]`) or an `## Affected files` section. Invokes
Claude to fix what it can; files vault items for what it cannot.

**Trigger**: `gardener/gardener-step.sh` is invoked on every polling iteration by
`docker/agents/entrypoint.sh` (default every 300s = 5 min, `POLL_INTERVAL` at line 516).
The entrypoint spawns it in the background; the script acquires a flock at `/tmp/gardener-step.lock`
to prevent concurrent steps. Sources `lib/guard.sh` and calls `check_active gardener` —
skips if `$FACTORY_ROOT/state/.gardener-active` is absent. Runs `gardener/classify.sh` to
select one highest-priority task (or exits CLEAN with no model call), loads the matching
`formulas/<task>.toml`, sets up a scratch worktree, and runs a single claude session via
`agent_run --worktree` (no tmux). No action issues — the gardener runs as part of the
polling loop alongside the planner, predictor, and supervisor.

**Key files**:
- `gardener/gardener-run.sh` — **Legacy** monolithic batch script (replaced by
  `gardener-step.sh`). Lock, memory guard, sources disinto project config,
  loads `formulas/run-gardener.toml`, runs `agent_run(worktree, prompt)` for the
  full gardener session, then walks the PR to merge and executes the pending-actions
  manifest after merge. Not invoked by the entrypoint anymore.
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
- `gardener/classify.sh` — Bash-only priority-ordered task classifier (9 buckets):
  scans open issues, emits one `{"task":...,"issue":...,"ctx":{...}}` JSON line
  to stdout. Pure bash + curl + jq — no model calls.
- `gardener/gardener-step.sh` — Per-step formula runner: reads the JSON payload
  from gardener/classify.sh, sources the matching `formulas/<task>.toml`, and executes
  the selected formula via a single `agent_run --worktree` claude session (no tmux).

**Environment variables consumed**:
- `FORGE_TOKEN`, `FORGE_GARDENER_TOKEN` (falls back to FORGE_TOKEN), `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`. `FORGE_TOKEN_OVERRIDE` is exported to `$FORGE_GARDENER_TOKEN` before sourcing env.sh so the gardener-bot identity survives re-sourcing (#762).
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by gardener-step.sh)

**Per-task formula dispatch (#871, #902, #916, #977)**: `gardener/gardener-step.sh` runs each
polling iteration; `gardener/classify.sh` emits one `{"task":..., ...}` JSON line that
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

**Lifecycle**: entrypoint polls every `POLL_INTERVAL` (default 300s) → invokes
`gardener-step.sh` → flock + `check_active gardener` → `classify.sh` selects
one task → load formula + context → `agent_run --worktree` runs single claude
session → Claude executes the task (e.g., grooms backlog, files issues, updates
AGENTS.md) → if a PR is created, `pr_walk_to_merge` walks it through CI/review
to merge → post-merge: execute pending-actions manifest via API → mirror push.
When blocked on external resources or human decisions, files a vault item
instead of escalating.
