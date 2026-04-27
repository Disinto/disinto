<!-- last-reviewed: 3da087919ca6b8b28e56c0c14429dd679574f3cd -->
# Dev Agent

**Role**: Implement issues autonomously — write code, push branches, address
CI failures and review feedback.

**Trigger**: `dev-poll.sh` is invoked by the polling loop in `docker/agents/entrypoint.sh`
every 5 minutes (iteration math at line 171-175). Sources `lib/guard.sh` and calls
`check_active dev` first — skips if `$FACTORY_ROOT/state/.dev-active` is absent. Then
performs a direct-merge scan (approved + CI green PRs — including chore/gardener PRs
without issue numbers), then checks the agent lock and scans for ready issues using a
two-tier priority queue: (1) `priority`+`backlog` issues first (FIFO within tier), then
(2) plain `backlog` issues (FIFO). Orphaned in-progress issues are also picked up. The
direct-merge scan runs before the lock check so approved PRs get merged even while a
dev-agent session is active.

**Key files**:
- `dev/dev-poll.sh` — Polling loop participant: finds next ready issue, handles merge/rebase
of approved PRs, tracks CI fix attempts (via `lib/ci-fix-tracker.sh`, max 3 fix attempts per PR).
Invoked by `docker/agents/entrypoint.sh` every 5
minutes. `BOT_USER` is resolved once at startup via the Forge `/user` API and cached for
all assignee checks. Formula guard skips issues labeled `formula`, `prediction/dismissed`,
or `prediction/unreviewed`. **Race prevention**: checks issue assignee before claiming —
skips if assigned to a different bot user. **Stale branch abandonment**: closes PRs and
deletes branches that are behind `$PRIMARY_BRANCH` (restarts poll cycle for a fresh start).
**Stale in-progress recovery**: on each poll cycle, scans for issues labeled `in-progress`.
If the issue has a `vision` label, sets `BLOCKED_BY_INPROGRESS=true` and skips further
stale checks (vision issues are managed by the architect). If the issue is assigned to
`$BOT_USER` (this agent), checks for pending review feedback first — if an open PR has
`REQUEST_CHANGES`, spawns the dev-agent to address it before setting `BLOCKED_BY_INPROGRESS=true`;
otherwise just sets blocked. If assigned to another agent, logs and falls through (does not
block). If no assignee, no open PR, and no agent lock file — removes `in-progress`, adds
`blocked` with a human-triage comment. **Post-crash self-assigned recovery (#749)**: when the
issue is self-assigned (this bot) but there is no open PR, dev-poll now checks for a lock
file (`/tmp/dev-impl-summary-$PROJECT_NAME-$ISSUE_NUM.txt`) AND a remote branch
(`fix/issue-$ISSUE_NUM`) before declaring "my thread is busy". If neither exists after a cold
boot, it spawns a fresh dev-agent for recovery instead of looping forever. **Per-agent open-PR gate**: before starting new work,
filters open waiting PRs to only those assigned to this agent (`$BOT_USER`). Other agents'
PRs do not block this agent's pipeline (#358, #369). **Pre-lock merge scan own-PRs only**:
the direct-merge scan only merges PRs whose linked issue is assigned to this agent — skips
PRs owned by other bot users (#374).
- `dev/dev-agent.sh` — Orchestrator: claims issue, creates worktree + tmux session with interactive `claude`, monitors phase file, injects CI results and review feedback, merges on approval. **Launched as a subshell** (`("${SCRIPT_DIR}/dev-agent.sh" ...) &`) — not via `nohup` — to avoid deadlocking the polling loop and review-poll when running in the same container (#693).
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

**Polling loop isolation (#753)**: `docker/agents/entrypoint.sh` now tracks fast-poll PIDs
(`FAST_PIDS`) and calls `wait "${FAST_PIDS[@]}"` instead of `wait` (no-args). This means
long-running dev-agent sessions no longer block the loop from launching the next iteration's
fast polls — the loop only waits for review-poll and dev-poll (the fast agents), never for
the dev-agent subprocess itself.

**Lifecycle**: dev-poll.sh (invoked by polling loop, `check_active dev`) → dev-agent.sh →
tmux session → phase file drives CI/review loop → merge + `mirror_push()` → `issue_close_after_verification()` (keeps issue open with `awaiting-live-verification` label for human verification on live box).
On respawn after `PHASE:escalate`, the stale phase file is cleared first so the session
starts clean; the reinject prompt tells Claude not to re-escalate for the same reason.
On respawn for any active PR, the prompt explicitly tells Claude the PR already exists
and not to create a new one via API.
