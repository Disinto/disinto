<!-- last-reviewed: 80a64cd3e4d2836bfab3c46230a780e3e233125d -->
# Dev Agent

**Role**: Implement issues autonomously — write code, push branches, address
CI failures and review feedback.

**Trigger**: `dev-poll.sh` runs every 10 min via cron. It scans for ready
backlog issues (all deps closed) or orphaned in-progress issues and spawns
`dev-agent.sh <issue-number>`.

**Key files**:
- `dev/dev-poll.sh` — Cron scheduler: finds next ready issue, handles merge/rebase of approved PRs, tracks CI fix attempts
- `dev/dev-agent.sh` — Orchestrator: claims issue, creates worktree + tmux session with interactive `claude`, monitors phase file, injects CI results and review feedback, merges on approval
- `dev/phase-handler.sh` — Phase callback functions: `post_refusal_comment()`, `_on_phase_change()`, `build_phase_protocol_prompt()`
- `dev/phase-test.sh` — Integration test for the phase protocol

**Environment variables consumed** (via `lib/env.sh` + project TOML):
- `CODEBERG_TOKEN` — Dev-agent token (push, PR creation, merge) — use the dedicated bot account
- `CODEBERG_REPO`, `CODEBERG_API` — Target repository
- `PROJECT_NAME`, `PROJECT_REPO_ROOT` — Local checkout path
- `PRIMARY_BRANCH` — Branch to merge into (e.g. `main`, `master`)
- `WOODPECKER_REPO_ID` — CI pipeline lookups
- `CLAUDE_TIMEOUT` — Max seconds for a Claude session (default 7200)
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER` — Notifications (optional)

**Lifecycle**: dev-poll.sh → dev-agent.sh → create Matrix thread + export
`MATRIX_THREAD_ID` (streams Claude output to thread via Stop hook) → tmux
`dev-{project}-{issue}` → phase file drives CI/review loop → merge → close issue.
