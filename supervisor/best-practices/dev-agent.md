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
  forge_api DELETE "/issues/<N>/labels/in-progress"
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
- forge shares issue/PR numbering — no guaranteed relationship
- PRs don't always mention the issue number in title/body
- Searching last N closed PRs misses older merges
- The dev-agent closes issues after merging, so closed = merged

The only check needed: `issue.state == "closed"`.

### False Positive: Status Unchanged Alert
The supervisor-poll alert 'status unchanged for Nmin' is a false positive for complex implementation tasks. The status is set to 'claude assessing + implementing' at the START of the `timeout 7200 claude -p ...` call and only updates after Claude finishes. Normal complex tasks (multi-file Solidity changes + forge test) take 45-90 minutes. To distinguish a false positive from a real stuck agent: check that the claude PID is alive (`ps -p <PID>`), consuming CPU (>0%), and has active threads (`pstree -p <PID>`). If the process is alive and using CPU, do NOT restart it — this wastes completed work.

### False Positive: 'Waiting for CI + Review' Alert
The 'status unchanged for Nmin' alert is also a false positive when status is 'waiting for CI + review on PR #N (round R)'. This is an intentional sleep/poll loop — the agent is waiting for CI to pass and then for review-poll to post a review. CI can take 20–40 minutes; review follows. Do NOT restart the agent. Confirm by checking: (1) agent PID is alive, (2) CI commit status via `forge_api GET /commits/<sha>/status`, (3) review-poll log shows it will pick up the PR on next cycle.

### False Positive: Shared Status File Causes Giant Age (29M+ min)
When the status file `/tmp/dev-agent-status` doesn't exist, `stat -c %Y` fails and the supervisor falls back to epoch 0. The computed age is then `NOW_EPOCH/60 ≈ 29,567,290 min`, which is unmistakably a false positive.
Root cause: the status file is not per-project (tracked as disinto issue #423). It can be missing if: (1) the agent has not written to it yet, (2) cleanup ran early, or (3) another project's cleanup deleted it.
Fix: confirm the agent PID is alive and the tmux session shows active work, then touch the file: `printf '[%s] dev-agent #NNN: <phase> (<project>)\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" > /tmp/dev-agent-status`. This clears the alert without restarting anything.

### PR CI vs Push CI mismatch causes silent stall in awaiting_review
When push CI passes but PR CI fails (e.g., a duplicate-detection step only runs on pull_request events), the phase-handler transitions to PHASE:awaiting_review without detecting the PR CI failure. The agent then sleeps in the review-poll loop indefinitely.

Symptom: PR CI=failure but dev-agent phase=awaiting_review, status shows 'waiting for CI + review'.

Fix: inject the CI failure info into the Claude session with agent_inject_into_session, pointing to the duplicate blocks and telling Claude to fix + push + write PHASE:awaiting_ci. The phase-handler's awaiting_review loop checks for phase file mtime changes every 5 min and will re-enter the main loop automatically.

### Push CI vs PR CI mismatch — agent picks wrong pipeline number
When the phase-handler injects 'CI failed' with a push pipeline number (e.g. #622), the agent checks that push pipeline, finds it passed, and concludes 'CI OK' — setting PHASE:awaiting_review despite the PR pipeline (#623) being the one that actually failed.
Root cause: the injected event does not always carry the correct pipeline number.
Symptom: agent in awaiting_review with PR CI=failure and push CI=success.
Fix: inject with explicit pipeline #623 (the pull_request event pipeline), point to the failing step and the specific duplicate blocks to fix. Use: woodpecker_api /repos/4/pipelines?event=pull_request (or look for event=pull_request in recent pipelines list) to find the correct pipeline number before injecting.

### Race Condition: Review Posted Before PHASE:awaiting_review Transitions
**Symptom:** Dev-agent status unchanged at 'waiting for review on PR #N', no `review-injected-disinto-N` sentinel, but a formal review already exists on forge and `/tmp/disinto-review-output-N.json` was written before the phase file updated.

**Root cause:** review-pr.sh runs while the dev-agent is still in PHASE:awaiting_ci. inject_review_into_dev_session returns early (phase check fails). On subsequent review-poll cycles, the PR is skipped (formal review already exists for SHA), so inject is never called again.

**Fix:** Manually inject the review:
```bash
source /home/debian/dark-factory/lib/env.sh
PROJECT_TOML=/home/debian/dark-factory/projects/disinto.toml
source /home/debian/dark-factory/lib/load-project.sh "$PROJECT_TOML"
PHASE_FILE="/tmp/dev-session-${PROJECT_NAME}-<ISSUE>.phase"
PR_NUM=<N>; PR_BRANCH="fix/issue-<ISSUE>"; PR_SHA=$(cat /tmp/dev-session-${PROJECT_NAME}-<ISSUE>.phase | grep SHA | cut -d: -f2 || git -C $PROJECT_REPO_ROOT rev-parse origin/$PR_BRANCH)
REVIEW_TEXT=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" "${FORGE_API}/issues/${PR_NUM}/comments?limit=50" | jq -r --arg sha "$PR_SHA" '[.[] | select(.body | contains("<!-- reviewed: " + $sha))] | last // empty | .body')
INJECT_MSG="Review: REQUEST_CHANGES on PR #${PR_NUM}:\n\n${REVIEW_TEXT}\n\nInstructions:\n1. Address each piece of feedback carefully.\n2. Run lint and tests when done.\n3. Commit your changes and push: git push origin ${PR_BRANCH}\n4. Write: echo PHASE:awaiting_ci > "${PHASE_FILE}"\n5. Stop and wait for the next CI result."
INJECT_TMP=$(mktemp); printf '%s' "$INJECT_MSG" > "$INJECT_TMP"
tmux load-buffer -b inject "$INJECT_TMP" && tmux paste-buffer -t "dev-${PROJECT_NAME}-<ISSUE>" -b inject && sleep 0.5 && tmux send-keys -t "dev-${PROJECT_NAME}-<ISSUE>" '' Enter
touch "/tmp/review-injected-${PROJECT_NAME}-${PR_NUM}"
```
Then update /tmp/dev-agent-status to reflect current work.
