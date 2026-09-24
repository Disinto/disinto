<!-- last-reviewed: 1ba0df0b171008d2d8850e634e9ad7c30a11c11b -->
# Dev Agent

**Role**: Implement issues autonomously — write code, push branches, address
CI failures and review feedback.

**Trigger**: `dev-poll.sh` is invoked by the polling loop in `docker/agents/entrypoint.sh`
every 5 minutes (`POLL_INTERVAL`, default 300s). Sources `lib/guard.sh` and calls
`check_active dev` first — skips if `$FACTORY_ROOT/state/.dev-active` is absent. Then
performs a direct-merge scan (approved + CI green PRs — including chore/gardener PRs
without issue numbers), then runs the merge-ready sweep (`dev/merge-ready.sh`, below),
then checks the agent lock and scans for ready issues using a
two-tier priority queue: (1) `priority`+`backlog` issues first (FIFO within tier), then
(2) plain `backlog` issues (FIFO). Orphaned in-progress issues are also picked up. The
direct-merge scan runs before the lock check so approved PRs get merged even while a
dev-agent session is active.

**Key files**:
- `dev/dev-poll.sh` — Polling loop participant: finds next ready issue, handles merge/rebase
of approved PRs, tracks CI fix attempts via `lib/ci-fix-tracker.sh` (max 3 per PR).
Invoked by `docker/agents/entrypoint.sh` every 5
minutes. `BOT_USER` is resolved once at startup via the Forge `/user` API and cached for
all assignee checks. Guard skips issues labeled `formula`, `prediction/dismissed`,
`prediction/unreviewed`, `waiting-on-compute` (readiness flag: work waiting on an
external run — see root AGENTS.md label table, #1072), or `experiment` / `run` /
`judgment` (research-template issues, #1295 — skipped even when queued with backlog,
#1306). **Race prevention**: checks issue assignee before claiming —
skips if assigned to a different bot user. **Stale branch abandonment**: closes PRs and
deletes branches that are behind `$PRIMARY_BRANCH` (restarts poll cycle for a fresh
start); the branch tested/deleted is the found PR's actual `head.ref`, so retry
branches (`fix/issue-N-<attempt>`) are handled correctly (#1139).
**Stale in-progress recovery**: on each poll cycle, scans for issues labeled `in-progress`.
If the issue has a `vision` label, sets `BLOCKED_BY_INPROGRESS=true` and skips further
stale checks (vision issues are managed by the architect). If the issue is assigned to
`$BOT_USER` (this agent), checks for pending review feedback first — if an open PR has
`REQUEST_CHANGES` (head-aware live reviews via `pr_live_review_count` in
`lib/pr-lifecycle.sh` — a reopened PR has every review marked stale, so stale-only
checks see no decision, #1089), spawns the dev-agent to address it before setting
`BLOCKED_BY_INPROGRESS=true`;
otherwise just sets blocked. If assigned to another agent, logs and falls through (does not
block). If no assignee, no open PR, and no agent lock file — `handle_stale_in_progress()`
closes the issue instead of relabeling it `blocked` when the linked PR is already
merged (merged PRs are found via a `state=all` lookup that matches retry branches too,
#1130/#1137); otherwise it removes `in-progress` and adds `blocked` with a human-triage
comment. **Post-crash self-assigned recovery (#749)**: when the
issue is self-assigned (this bot) but there is no open PR, dev-poll checks a lock
file (`/tmp/dev-impl-summary-$PROJECT_NAME-$ISSUE_NUM.txt`) and a remote branch
(`fix/issue-$ISSUE_NUM`) before declaring "my thread is busy". A lock file means busy.
A remote branch with no open PR means busy when a dev-agent process is live
(`pgrep`, `_dev_agent_running`) or the branch was pushed within the last 6h; a
branch older than 6h with no agent is an orphaned corpse — it is deleted (so the
relaunch reuses `fix/issue-N` instead of stacking an attempt branch on top, #1251)
and dev-agent is relaunched, which adopts any surviving state via `RECOVERY_MODE`
(#1227). With neither lock nor branch, a fresh dev-agent is spawned — after checking
the process table, since a started session that has written neither lock nor branch
yet is invisible to both of those checks, but not to `pgrep` (#1070).
**Per-agent open-PR gate**: before starting new work,
filters open waiting PRs to only those assigned to this agent (`$BOT_USER`). Other agents'
PRs do not block this agent's pipeline (#358, #369). **Wedged-PR escalation (#1089)**:
an open PR that is CI green but has zero *live* reviews (Forgejo marks every review
stale on close/reopen, including the one pinned to the head) can be neither picked up
(no live REQUEST_CHANGES) nor merged (no live APPROVE) — `escalate_wedged_pr()` posts a
dedup'd comment, labels the issue `blocked`, and drops `in-progress` so the queue is
not held; a re-review unblocks it automatically. **Merge-block escalation (#1090)**:
`try_direct_merge` no longer retries forever when a merge keeps failing for the same
reason on the same head — after `MERGE_BLOCK_RETRY_LIMIT` (default 3) identical
failures, `escalate_merge_blocked_pr()` posts the full untruncated forge response,
labels the issue `blocked`, drops `in-progress`, and callers stop retrying and skip
the dev-agent fallback (return code 2). **Tape proposal emission (#1398)**: when the
pick resolves, `emit_tape_proposal()` appends one `{"type":"proposal","loop":"dev",...}`
record to the tape (`lib/tape.sh`) before launching dev-agent — class = the issue's
primary label (or `dev`), context = `{"open_prs":<n>, "size_class":"S|M|L", "backend":"<model>?"}` (open_prs
from one pull GET, size_class from the issue's size label — case-insensitive, default
M; backend present only when DSH_MODEL/CLAUDE_MODEL/AGENT_HARNESS is set; `forecast_method`
records the method used — `counts` (a measured catalog row) or `prior` (the flat 0.5 fallback) —
so the #1453 calibration reader can tell a flat prior from measured data; omitted on the
API-failure path, where the context degrades to `{}`), forecast = `{"p_success":<actual/100>,
"est_cost":0,"est_dvision":<mean_duration_s-or-0>}` (measured: p_success is the catalog row's `actual` percent / 100 and `est_dvision` is the row's `mean duration_s` when that cell is a number, else 0, when that
row's `n` is an integer >= CATALOG_FORECAST_MIN_N (default 5) AND its `actual` is an integer
percent, or the flat prior `{"p_success":0.5,"est_cost":0,"est_dvision":0}` (= the planner's
prior in planner-run.sh); written on every fresh pick), decision `approved`, ref
the issue number — and stores the record's id in
`/tmp/dev-proposal-id-${PROJECT_NAME:-default}-<issue>` (contents: just the id)
so the #1399 outcome step can reference it, plus the pick's wall-clock epoch
(`date -u +%s`) in the sibling `/tmp/dev-proposal-started-${PROJECT_NAME:-default}-<issue>`
(#1452). A re-pick (no-push -> backlog -> pick again, #1441) finds that same
id file and reuses the stored id — it logs the reuse and returns 0 without
minting a second uuid, appending a second proposal, or rewriting the started
epoch (so the outcome's duration spans the issue's whole life, not just one
attempt), so the tape holds one sample of one decision. Any tape failure logs
a WARNING; the pick proceeds
unchanged. **Tape outcome emission (#1399)**: when a dev PR reaches terminal state —
merged via `try_direct_merge` (the three direct-merge paths, CI green by construction)
or closed by stale-branch abandonment — `emit_tape_outcome()` appends one
`{"type":"outcome","proposal_id":...}` record to the tape keyed off the stored id:
bits `{"merged":0|1,"ci_green":0|1}`, numbers `{"review_rounds":<n>}` (the PR's
REQUEST_CHANGES review count from one forge call, `0` when the call fails)
plus `{"duration_s":<s>}` (#1452: wall-clock pick→terminal seconds, now − start,
integer, clamped ≥ 0; omitted — never 0 — when the started file is missing or
not an integer), children `{}`, payloads `[]`. No id file (issue predates the proposal step) → skip silently;
any tape failure logs a WARNING; the merge/close proceeds unchanged.
- `dev/merge-ready.sh` — Merge sweeper for fully-baked PRs (`merge_ready_sweep()`),
called from `dev-poll.sh` before the lock check each poll tick: auto-merges ANY open
PR that is mergeable, has no `blocked`/`do-not-merge` label, has a review-bot
APPROVED pinned to the current HEAD, no review-bot REQUEST_CHANGES on the HEAD,
CI success on the HEAD, and an approval older than `MERGE_COOLDOWN_MIN` (default
30 min — human veto window), regardless of issue assignee. Runs as dev-bot (the
review identity never merges what it approved). This lands ops/gardener PRs (no
linked issue) and clears orphaned APPROVED PRs that the author's own-PR scan would
skip (#1250/#1259). Post-merge housekeeping (mirror_push, linked-issue close via
branch ref / PR title / body keyword, in-progress cleanup, CI-tracker reset) is
performed automatically.
- `dev/dev-agent.sh` — Orchestrator: claims issue, creates worktree + tmux session with interactive `claude`, monitors phase file, injects CI results and review feedback, merges on approval. **Launched as a subshell** (`("${SCRIPT_DIR}/dev-agent.sh" ...) &`) — not via `nohup` — to avoid deadlocking the polling loop and review-poll when running in the same container (#693). **No-push decision (#1164, #1442)**: `no_push_outcome()` separates resource-limit exits — max turns (the run's `result` subtype), the wall-clock timeout (`agent_run` exit code 124, `lib/agent-sdk.sh`), or a `no_result` terminal row (the harness died before writing a normal result row — server/harness death, not an agent push decision) — from real no-push failures. Resource-limit exits are transient: `issue_requeue` (`lib/issue-lifecycle.sh`) puts the issue back in the claimable backlog for a fresh retry; on the third consecutive resource-limit exit (attempt ≥ 2) a human decision is needed, so the issue is blocked with reason `no_push_after_3_attempts`. Any other no-push reason keeps the historical `issue_block "no_push"` behavior; rc 124 wins when both a timeout and a `no_result`/`error_max_turns` row are present. **Leftover-claude cleanup (#1070)**: `claude_run_with_watchdog` records the claude process-group id in a pgid file, so every exit path (release, crash, signal — HUP/INT/TERM are routed into the EXIT trap) runs `kill_stale_claude()`, which TERM/KILLs a claude group that outlived its watchdog and was holding an agent slot.
- `dev/phase-test.sh` — Integration test for the phase protocol

**Environment variables consumed** (via `lib/env.sh` + project TOML):
- `FORGE_TOKEN` — Dev-agent token (push, PR creation, merge) — use the dedicated bot account
- `FORGE_REPO`, `FORGE_API`, `FORGE_URL` — Target repository (FORGE_URL used to auto-detect git remote)
- `PROJECT_NAME`, `PROJECT_REPO_ROOT` — Local checkout path
- `PRIMARY_BRANCH` — Branch to merge into (e.g. `main`, `master`)
- `WOODPECKER_REPO_ID` — CI pipeline lookups
- `CLAUDE_TIMEOUT` — Max seconds for a Claude session (default 7200)

**FORGE_REMOTE**: `dev-agent.sh` auto-detects which git remote corresponds to `FORGE_URL` by matching the remote's push URL hostname. This is exported as `FORGE_REMOTE` and used for all git push/pull/worktree operations. Defaults to `origin` if no match found. This ensures correct behaviour when the forge is local Forgejo (remote typically named `forgejo`) rather than Codeberg (`origin`).

**Session lock**: fd-based flock — released during idle phases (`awaiting_review`, `awaiting_ci`) so other agents can proceed; re-acquired before injecting the next prompt. This prevents the lock from blocking the whole factory while the dev session waits.

**Crash recovery**: on `PHASE:crashed` or non-zero exit, the worktree is **preserved** (not destroyed) for debugging. Location logged. Supervisor housekeeping removes stale crashed worktrees older than 24h.

**Polling loop isolation (#1388)**: `docker/agents/entrypoint.sh` backgrounds
`dev-poll.sh` every loop (`POLL_INTERVAL`, default 300s) and waits only for the
current iteration's fast polls — long-running dev-agent sessions (spawned by
dev-poll) therefore never block the loop from launching the next iteration's
polls.

**Lifecycle**: dev-poll.sh (invoked by polling loop, `check_active dev`) → dev-agent.sh →
tmux session → phase file drives CI/review loop → merge + `mirror_push()` → `issue_close_after_verification()` (keeps issue open with `awaiting-live-verification` label for human verification on live box); or no push → `no_push_outcome()` requeues resource-limit exits to `backlog` / blocks `no_push` and `no_push_after_3_attempts` (#1164).
On respawn after `PHASE:escalate`, the stale phase file is cleared first so the session
starts clean; the reinject prompt tells Claude not to re-escalate for the same reason.
On respawn for any active PR, the prompt explicitly tells Claude the PR already exists
and not to create a new one via API.
