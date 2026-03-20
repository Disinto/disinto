# Dev-Agent Best Practices

## Architecture
- `dev-poll.sh` (cron */10) → finds ready backlog issues → spawns `dev-agent.sh`
- `dev-agent.sh` uses `claude -p` for implementation, runs in git worktree
- Lock file: `/tmp/dev-agent.lock` (contains PID)
- Status file: `/tmp/dev-agent-status`
- Worktrees: `/tmp/${PROJECT_NAME}-worktree-<issue-number>/`

## Safe Fixes
- Remove stale lock: `rm -f /tmp/dev-agent.lock` (only if PID is dead)
- Kill stuck agent: `kill <pid>` then clean lock
- Restart on derailed PR: `bash ${FACTORY_ROOT}/dev/dev-agent.sh <issue-number> &`
- Clean worktree: `cd $PROJECT_REPO_ROOT && git worktree remove /tmp/${PROJECT_NAME}-worktree-<N> --force`
- Remove `in-progress` label if agent died without cleanup:
  ```bash
  codeberg_api DELETE "/issues/<N>/labels/in-progress"
  ```

## Dangerous (escalate)
- Restarting agent on an issue that has an open PR with review changes — may lose context
- Anything that modifies the PR branch history
- Closing PRs or issues

## Known Issues
- `claude -p -c` (continue) fails if session was compacted — falls back to fresh `-p`
- CI_FIX_COUNT is now reset on CI pass (fixed 2026-03-12), so each review phase gets fresh CI fix budget
- Worktree creation fails if main repo has stale rebase — auto-heals now
- Large text in jq `--arg` can break — write to file first
- `$([ "$VAR" = true ] && echo "...")` crashes under `set -euo pipefail`

## Lessons Learned
- Agents don't have memory between tasks — full context must be in the prompt
- Prior art injection (closed PR diffs) prevents rework
- Feature issues MUST list affected e2e test files
- CI fix loop is essential — first attempt rarely works
- CLAUDE_TIMEOUT=7200 (2h) is needed for complex issues

## Dependency Resolution

**Trust closed state.** If a dependency issue is closed, the code is on the primary branch. Period.

DO NOT try to find the specific PR that closed an issue. This is over-engineering that causes false negatives:
- Codeberg shares issue/PR numbering — no guaranteed relationship
- PRs don't always mention the issue number in title/body
- Searching last N closed PRs misses older merges
- The dev-agent closes issues after merging, so closed = merged

The only check needed: `issue.state == "closed"`.

### False Positive: Status Unchanged Alert
The supervisor-poll alert 'status unchanged for Nmin' is a false positive for complex implementation tasks. The status is set to 'claude assessing + implementing' at the START of the `timeout 7200 claude -p ...` call and only updates after Claude finishes. Normal complex tasks (multi-file Solidity changes + forge test) take 45-90 minutes. To distinguish a false positive from a real stuck agent: check that the claude PID is alive (`ps -p <PID>`), consuming CPU (>0%), and has active threads (`pstree -p <PID>`). If the process is alive and using CPU, do NOT restart it — this wastes completed work.

### False Positive: 'Waiting for CI + Review' Alert
The 'status unchanged for Nmin' alert is also a false positive when status is 'waiting for CI + review on PR #N (round R)'. This is an intentional sleep/poll loop — the agent is waiting for CI to pass and then for review-poll to post a review. CI can take 20–40 minutes; review follows. Do NOT restart the agent. Confirm by checking: (1) agent PID is alive, (2) CI commit status via `codeberg_api GET /commits/<sha>/status`, (3) review-poll log shows it will pick up the PR on next cycle.

### False Positive: Shared Status File Causes Giant Age (29M+ min)
When the status file `/tmp/dev-agent-status` doesn't exist, `stat -c %Y` fails and the supervisor falls back to epoch 0. The computed age is then `NOW_EPOCH/60 ≈ 29,567,290 min`, which is unmistakably a false positive.
Root cause: the status file is not per-project (tracked as disinto issue #423). It can be missing if: (1) the agent has not written to it yet, (2) cleanup ran early, or (3) another project's cleanup deleted it.
Fix: confirm the agent PID is alive and the tmux session shows active work, then touch the file: `printf '[%s] dev-agent #NNN: <phase> (<project>)\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" > /tmp/dev-agent-status`. This clears the alert without restarting anything.
