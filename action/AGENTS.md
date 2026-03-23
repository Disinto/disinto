<!-- last-reviewed: eb7e24cb1df028c6061f47ddfdf9b4ebec33e1cf -->
# Action Agent

**Role**: Execute operational tasks described by action formulas — run scripts,
call APIs, send messages, collect human approval. Shares the same phase handler
as the dev-agent: if an action produces code changes, the orchestrator creates a
PR and drives the CI/review loop; otherwise Claude closes the issue directly.

**Trigger**: `action-poll.sh` runs every 10 min via cron. It scans for open
issues labeled `action` that have no active tmux session, then spawns
`action-agent.sh <issue-number>`.

**Key files**:
- `action/action-poll.sh` — Cron scheduler: finds open action issues with no active tmux session, spawns action-agent.sh
- `action/action-agent.sh` — Orchestrator: fetches issue body + prior comments, creates tmux session (`action-{project}-{issue_num}`) with interactive `claude`, injects formula prompt with phase protocol, enters `monitor_phase_loop` (shared via `dev/phase-handler.sh`) for CI/review lifecycle or direct completion

**Session lifecycle**:
1. `action-poll.sh` finds open `action` issues with no active tmux session.
2. Spawns `action-agent.sh <issue_num>`.
3. Agent creates Matrix thread, exports `MATRIX_THREAD_ID` so Claude's output streams to the thread via a Stop hook (`on-stop-matrix.sh`).
4. Agent creates tmux session `action-{project}-{issue_num}`, injects prompt (formula + prior comments + phase protocol).
5. Agent enters `monitor_phase_loop` (shared with dev-agent via `dev/phase-handler.sh`).
6. **Path A (git output):** Claude pushes branch → `PHASE:awaiting_ci` → handler creates PR, polls CI → injects failures → Claude fixes → push → re-poll → CI passes → `PHASE:awaiting_review` → handler polls reviews → injects REQUEST_CHANGES → Claude fixes → approved → merge → cleanup.
7. **Path B (no git output):** Claude posts results as comment, closes issue → `PHASE:done` → handler cleans up (kill session, docker compose down, remove temp files).
8. For human input: Claude sends a Matrix message and waits; the reply is injected into the session by `matrix_listener.sh`.

**Environment variables consumed**:
- `CODEBERG_TOKEN`, `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `CODEBERG_WEB`
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER` — Matrix notifications + human input
- `ACTION_IDLE_TIMEOUT` — Max seconds before killing idle session (default 14400 = 4h)
- `ACTION_MAX_LIFETIME` — Max total session wall-clock seconds (default 28800 = 8h); caps session independently of idle timeout
