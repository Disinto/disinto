<!-- last-reviewed: 17a89f4545dc95e3d42dd672f764f72dc171c831 -->
# Gardener Agent

**Role**: Backlog grooming — detect duplicate issues, missing acceptance
criteria, oversized issues, stale issues, and circular dependencies. Enforces
the quality gate: strips the `backlog` label from issues that lack acceptance
criteria checkboxes (`- [ ]`) or an `## Affected files` section. Invokes
Claude to fix what it can; files vault items for what it cannot.

**Trigger**: `gardener/gardener-step.sh` is invoked by the polling loop in
`docker/agents/entrypoint.sh` every iteration, paced by `POLL_INTERVAL` (default 5 min).
Each invocation does exactly one task: runs `gardener/classify.sh` to emit a single task,
dispatches it to a claude session via `lib/formula-session.sh`, and walks the resulting PR
to merge. Concurrency is guarded by `flock -n` on `/tmp/gardener-step.lock`.
**Early-exit optimization**: if `classify.sh` produces no task (all buckets clean), the step
exits immediately (~1s, no tokens consumed). If a step is already in flight (detected by the
lock), the invocation also exits silently.

**Key files**:
- `gardener/gardener-run.sh` — **Deprecated** — replaced by `gardener-step.sh` (#872).
  Was the monolithic one-shot batch script that ran every `GARDENER_INTERVAL`.
- `gardener/gardener-step.sh` — Per-iteration pull-one-task driver that replaces
  the monolithic `gardener/gardener-run.sh` batch model. Acquires a flock, runs
  `gardener/classify.sh`,
  and dispatches the selected task to a single claude session via
  lib/formula-session.sh. ~250 lines.
- `gardener/classify.sh` — Bash-only priority-ordered task classifier that scans
  all open issues and emits one JSON task line per invocation. Covers 9 task
  buckets (blocker-starving-the-factory through pitch-vision). ~760 lines.
- `formulas/run-gardener.toml` — Execution spec: preflight, grooming, dust-bundling,
  agents-update, commit-and-pr
- `formulas/agents-md-stale.toml` — Per-directory AGENTS.md watermark walk;
  refreshes exactly one AGENTS.md per claude session, replacing the monolithic
  agents-update step. ~298 lines.
- `formulas/bundle-dust.toml` — Auto-bundles 3+ dust items into single backlog
  issues.
- `formulas/enrich-bug-report.toml` — Enriches `bug-report` issues with
  acceptance criteria and affected files sections.
- `formulas/enrich-underspecified.toml` — Enriches `underspecified` issues
  via Claude session.
- `formulas/file-subissues.toml` — Files subissues from approved architect PRs.
- `formulas/pitch-vision.toml` — Converts vision items into actionable PRs.
- `formulas/promote-tech-debt.toml` — Promotes `tech-debt` issues to backlog.
- `formulas/revisit-blocked.toml` — Revisits stale `blocked` issues for
  transient recovery or nudge.
- `formulas/review-pr.toml` — PR review formula.
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

**Direct-edit primitives** (exported by `lib/gardener-edit.sh`):
- `gardener_edit_body` — PATCH issue body from file
- `gardener_add_label` — idempotent label addition
- `gardener_remove_label` — idempotent label removal
- `gardener_post_comment` — post comment with file body

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
closed; for operator-mediated blocks older than `BLOCKED_NUDGE_AGE_DAYS`
(default 7d) it posts a single nudge comment using the
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

**Lifecycle**: `gardener-step.sh` (invoked by polling loop every `POLL_INTERVAL`) →
`classify.sh` emits one task → dispatch to single claude session via
`lib/formula-session.sh` → agent executes the formula (e.g., grooms backlog,
bundles dust, updates AGENTS.md, opens PR) → if PR created, `pr_walk_to_merge`
drives it through CI/review/merge with retries (3 attempts, 5 min each) →
`gardener-step.sh` exits. On each new polling tick, the cycle repeats with the
next highest-priority task. When blocked on external resources or human decisions,
files a vault item instead of escalating.
