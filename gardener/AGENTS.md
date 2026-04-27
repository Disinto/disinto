<!-- last-reviewed: 12b15762f6adcd833f4c39345b66778112eca39c -->
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
- `gardener/gardener-step.sh` — **Pull-one-task driver (#871)**: per-iteration
  script that does exactly one task per invocation. Same loop shape as
  `dev/dev-poll.sh`. Acquires `/tmp/gardener-step.lock` via `flock -n` (silent
  exit if a step is in flight), runs `gardener/classify.sh` to pick one task,
  exits 0 immediately on CLEAN, otherwise dispatches to `formulas/<task>.toml`
  via `lib/formula-session.sh` (`load_formula_or_profile`) and runs a single
  focused claude session. Sources `lib/gardener-edit.sh` and exports its
  helpers (`gardener_edit_body`, `gardener_add_label`, `gardener_remove_label`,
  `gardener_post_comment`) into the claude bash environment so direct API
  edits are journaled. Logs to `${DISINTO_LOG_DIR}/gardener/step.log`.
  Cleanup trap drops the lock, scratch dir, and worktree on exit.
- `gardener/gardener-run.sh` — **Legacy monolithic batch (sibling cleanup will
  retire once gardener-step.sh proves working)**. Polling loop participant +
  orchestrator: lock, memory guard, sources disinto project config, creates
  tmux session, injects formula prompt, monitors phase file via custom
  `_gardener_on_phase_change` callback (passed to `run_formula_and_monitor`).
  Stays alive through CI/review/merge cycle after `PHASE:awaiting_ci` —
  injects CI results and review feedback, re-signals `PHASE:awaiting_ci`
  after fixes, signals `PHASE:awaiting_review` on CI pass. Executes
  pending-actions manifest after PR merge.
- `formulas/run-gardener.toml` — Execution spec: preflight, grooming, dust-bundling,
  agents-update, commit-and-pr
- **Per-task formula registry** (consumed by `gardener-step.sh` based on
  `classify.sh` task field — one formula per priority bucket):
  - `formulas/enrich-underspecified.toml` (#873) — single-issue body
    enrichment: rewrite an `underspecified`-labeled issue with `## Affected
    files` + `## Acceptance criteria` and flip the label to `backlog`. On
    too-thin bodies, posts a comment asking the operator for the missing
    pieces and keeps `underspecified`. Replaces the buggy quality-gate
    branch in monolithic `run-gardener.toml` that stripped `backlog` from
    9 issues in PR #811 without enriching them (manually re-enriched
    2026-04-26).
  - `formulas/enrich-bug-report.toml` (#874) — single-issue investigation
    brief: appends four sections (`What was reported`, `Known context`,
    `Reproduction plan`, `What needs verification`) to a raw bug report
    body, then labels it `bug-report`. Runs git log preflight on affected
    paths extracted from the body. Replaces the inline enrichment logic
    in monolithic `run-gardener.toml` (lines 89–135).
- `gardener/dust.jsonl` — Persistent dust accumulator (JSONL). Each line is a DUST
  item: `{"issue":NNN,"group":"...","title":"...","reason":"...","ts":"..."}`.
  30-day TTL; groups of 3+ distinct issues auto-bundled into single backlog issues.
- `gardener/pending-actions.jsonl` — Intermediate manifest of proposed repo actions
  (label changes, closures, comments, issue creation, body edits). Written during
  grooming steps as one JSON object per line.
- `gardener/pending-actions.json` — Final manifest (JSON array) committed to the PR,
  reviewed alongside AGENTS.md changes, executed by gardener-run.sh after merge.
  Converted from JSONL at commit time.

**Direct-edit primitives (per-task gardener, #869)**: `lib/gardener-edit.sh`
provides sourceable helpers for the new pull-one-task gardener that bypass the
deferred-PR pattern above for label/body edits. Each call applies via the
Forgejo API immediately and is appended as one row to
`${DISINTO_LOG_DIR}/gardener/journal.jsonl` (audit trail since direct edits
leave no git history). Functions:
- `gardener_edit_body <issue_num> <body_file>` — PATCH issue body from file
- `gardener_add_label <issue_num> <label_name>` — idempotent, label id cached
- `gardener_remove_label <issue_num> <label_name>` — idempotent
- `gardener_post_comment <issue_num> <body_file>` — comment body from file
All authenticate via `FORGE_GARDENER_TOKEN` and exit non-zero on non-2xx
responses (full response body logged to `${DISINTO_LOG_DIR}/gardener/edit.log`).

**Environment variables consumed**:
- `FORGE_TOKEN`, `FORGE_GARDENER_TOKEN` (falls back to FORGE_TOKEN), `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`. `FORGE_TOKEN_OVERRIDE` is exported to `$FORGE_GARDENER_TOKEN` before sourcing env.sh so the gardener-bot identity survives re-sourcing (#762).
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by gardener-run.sh)

**Lifecycle**: gardener-run.sh (invoked by polling loop every 6h, `check_active gardener`) →
lock + memory guard → load formula + context → create tmux session →
Claude grooms backlog (writes proposed actions to manifest), bundles dust,
updates AGENTS.md, commits manifest + docs to PR →
`PHASE:awaiting_ci` (stays alive) → CI pass → `PHASE:awaiting_review` →
review feedback → address + re-signal → merge → gardener-run.sh executes
manifest actions via API → `PHASE:done`. When blocked on external resources
or human decisions, files a vault item instead of escalating.
