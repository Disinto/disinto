<!-- last-reviewed: 0560e020ed9db2aae5cd36d3531d018d319fda64 -->
# Gardener Agent

**Role**: Backlog grooming — detect duplicate issues, missing acceptance
criteria, oversized issues, stale issues, and circular dependencies. Enforces
the quality gate: strips the `backlog` label from issues that lack acceptance
criteria checkboxes (`- [ ]`) or an `## Affected files` section. Invokes
Claude to fix what it can; files vault items for what it cannot.

**Trigger**: `gardener/gardener-step.sh` is invoked by the polling loop in `docker/agents/entrypoint.sh`
once per loop tick (the gardener call is at `docker/agents/entrypoint.sh:692-699`). Sources
`lib/guard.sh` and calls
`check_active gardener` first — skips if `$FACTORY_ROOT/state/.gardener-active` is absent.
`gardener/gardener-run.sh` (one-shot full-formula executor) runs instead from host cron
in bare-metal mode (`lib/ci-setup.sh:63`).
**Early-exit optimization**: if no new commits since last run (compared via
`LAST_SHA_FILE`) and no backlog or tech-debt issues exist, the model is not
invoked — the run exits immediately (no tokens consumed). Otherwise, builds a
context block from AGENTS.md and the formula, then invokes `agent_run` from
`lib/agent-sdk.sh` (one-shot `claude -p`, no tmux, no phase files). The bash
script IS the state machine — it walks the PR to merge via `pr_walk_to_merge`
and executes the pending-actions manifest post-merge.

**Key files**:
- `gardener/gardener-run.sh` — One-shot full-formula executor (invoked from host cron in
  bare-metal mode, `lib/ci-setup.sh:63`): lock, memory guard,
  sources disinto project config, loads formula via `load_formula_or_profile`,
  builds context block via `build_context_block`, invokes `agent_run` from
  `lib/agent-sdk.sh`. Walks PR to merge via `pr_walk_to_merge` from
  `lib/pr-lifecycle.sh`. Executes pending-actions manifest via
  `_gardener_execute_manifest` after PR merge. Sources `lib/gardener-pr.sh` for
  PR detection helper (`detect_pr_number`). Loads engagement evidence from ops repo
  (`load_engagement_evidence`) for website addressable decisions.
- `gardener/gardener-step.sh` — Per-iteration step executor: sources `gardener/classify.sh`,
  reads its JSON output, and dispatches to the matching `formulas/<task>.toml`.
  Manages scratch worktree and PR creation for single-file updates.
- `gardener/classify.sh` — Bash-only task classifier: scans open issues and emits
  one highest-priority undone task as JSON. Priority-ordered buckets (blocker-starving,
  enrich-underspecified, promote-tech-debt, bundle-dust, revisit-blocked, agents-md-stale,
  file-subissues, pitch-vision). Pure bash + curl + jq — no model calls.
- `gardener/best-practices.md` — Gardener operational guidelines: issue quality checklist,
  when to close/escalate, escalation format, and lessons learned.
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

**Shared libraries** (sourced by gardener-run.sh):
- `lib/formula-session.sh` — Formula loading (`load_formula_or_profile`), context
  building (`build_context_block`, `build_sdk_prompt_footer`), profile context
  (`formula_prepare_profile_context`), worktree setup (`formula_worktree_setup`),
  lessons block (`formula_lessons_block`)
- `lib/agent-sdk.sh` — `agent_run` (one-shot `claude -p` execution with worktree)
- `lib/pr-lifecycle.sh` — `pr_walk_to_merge` (CI, review, merge automation)
- `lib/mirrors.sh` — `mirror_push`, `resolve_forge_remote`
- `lib/worktree.sh` — Worktree management
- `lib/ci-helpers.sh` — CI status helpers
- `lib/profile.sh` — `.profile` repo lifecycle, `profile_write_journal`

**Environment variables consumed**:
- `FORGE_TOKEN`, `FORGE_GARDENER_TOKEN` (falls back to FORGE_TOKEN), `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`. `FORGE_TOKEN_OVERRIDE` is exported to `$FORGE_GARDENER_TOKEN` before sourcing env.sh so the gardener-bot identity survives re-sourcing (#762).
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by gardener-run.sh)

**Per-task formula dispatch (#871, #902, #906, #912, #916)**: `gardener/gardener-step.sh` runs each
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

**Lifecycle**: gardener-run.sh (invoked from host cron in bare-metal mode, `check_active gardener`) →
lock + memory guard → load formula + context → `agent_run` (one-shot Claude) →
Claude grooms backlog (writes proposed actions to manifest), bundles dust,
updates AGENTS.md, creates PR → `detect_pr_number` + `pr_walk_to_merge` walks
PR to merge → gardener-run.sh executes manifest actions via API → done. When
blocked on external resources or human decisions, files a vault item instead of
escalating.
