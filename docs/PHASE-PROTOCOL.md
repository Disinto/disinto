# Phase-Signaling Protocol for Persistent Claude Sessions

## Overview

When dev-agent runs Claude in a persistent tmux session (rather than a
one-shot `claude -p` invocation), Claude needs a way to signal the
orchestrator (`dev-poll.sh`) that a phase has completed.

Claude writes a sentinel line to a **phase file** — a well-known path based
on project name and issue number. The orchestrator watches that file and
reacts accordingly.

## Phase File Path Convention

```
/tmp/dev-session-{project}-{issue}.phase
```

Where:
- `{project}` = the project name from the TOML (`name` field), e.g. `harb`
- `{issue}` = the issue number, e.g. `42`

Example: `/tmp/dev-session-harb-42.phase`

## Phase Values

Claude writes exactly one of these lines to the phase file when a phase ends:

| Sentinel | Meaning | Orchestrator action |
|----------|---------|---------------------|
| `PHASE:awaiting_ci` | PR pushed, waiting for CI to run | Poll CI; inject result when done |
| `PHASE:awaiting_review` | CI passed, PR open, waiting for review | Wait for `review-poll` to inject feedback |
| `PHASE:escalate` | Needs human input (any reason) | Send vault/forge notification; session stays alive; 24h timeout → blocked |
| `PHASE:done` | Work complete, PR merged | Verify merge, kill tmux session, clean up |
| `PHASE:failed` | Unrecoverable failure | Escalate to gardener/supervisor |

### Writing a phase (from within Claude's session)

```bash
PHASE_FILE="/tmp/dev-session-${PROJECT_NAME:-project}-${ISSUE:-0}.phase"

# Signal awaiting CI
echo "PHASE:awaiting_ci" > "$PHASE_FILE"

# Signal awaiting review
echo "PHASE:awaiting_review" > "$PHASE_FILE"

# Signal needs human
echo "PHASE:escalate" > "$PHASE_FILE"

# Signal done
echo "PHASE:done" > "$PHASE_FILE"

# Signal failure
echo "PHASE:failed" > "$PHASE_FILE"
```

The orchestrator reads with:

```bash
phase=$(head -1 "$PHASE_FILE" 2>/dev/null | tr -d '[:space:]')
```

Using `head -1` is required: `PHASE:failed` may have a reason line on line 2,
and reading all lines would produce `PHASE:failedReason:...` which never matches.

## Orchestrator Reaction Matrix

```
PHASE:awaiting_ci     → poll CI every 30s
                         on success  → inject "CI passed" into tmux session
                         on failure  → inject CI error log into tmux session
                         on timeout  → inject "CI timeout" + escalate

PHASE:awaiting_review → wait for review-poll.sh to post review comment
                         on REQUEST_CHANGES → inject review text into session
                         on APPROVE         → inject "approved" into session
                         on timeout (3h)    → inject "no review, escalating"

PHASE:escalate        → send vault/forge notification with context (issue/PR link, reason)
                         session stays alive waiting for human reply
                         on timeout → 24h: label issue blocked, kill session

PHASE:done            → verify PR merged on forge
                         if merged   → kill tmux session, clean labels, close issue
                         if not      → inject "PR not merged yet" into session

PHASE:failed          → label issue blocked, post diagnostic comment
                         kill tmux session
                         restore backlog label on issue
```

### `idle_prompt` exit reason

`monitor_phase_loop` (in `lib/agent-session.sh`) can exit with
`_MONITOR_LOOP_EXIT=idle_prompt`. This happens when Claude returns to the
interactive prompt (`❯`) for **3 consecutive polls** without writing any phase
signal to the phase file.

**Trigger conditions:**
- The phase file is empty (no phase has ever been written), **and**
- The Stop-hook idle marker (`/tmp/claude-idle-{session}.ts`) is present
  (meaning Claude finished a response), **and**
- This state persists across 3 consecutive poll cycles.

**Side-effects:**
1. The tmux session is **killed before** the callback is invoked — callbacks
   that handle `PHASE:failed` must not assume the session is alive.
2. The callback is invoked with `PHASE:failed` even though the phase file is
   empty. This is the only situation where `PHASE:failed` is passed to the
   callback without the phase file actually containing that value.

**Agent requirements:**
- **Callback (`_on_phase_change` / `formula_phase_callback`):** Must handle
  `PHASE:failed` defensively — the session is already dead, so any tmux
  send-keys or session-dependent logic must be skipped or guarded.
- **Post-loop exit handler (`case $_MONITOR_LOOP_EXIT`):** Must include an
  `idle_prompt)` branch. Typical actions: log the event, clean up temp files,
  and (for agents that use escalation) write an escalation entry or notify via
  vault/forge. See `dev/dev-agent.sh` and
  `gardener/gardener-agent.sh` for reference implementations.

## Crash Recovery

If the tmux session dies (Claude crash, OOM, kernel OOM-kill, compaction):

### Detection

`dev-poll.sh` detects a crash via:
1. `tmux has-session -t "dev-{project}-{issue}"` returns non-zero, OR
2. Phase file is stale (mtime > `CLAUDE_TIMEOUT` seconds with no `PHASE:done`)

### Recovery procedure

```bash
# 1. Read current state from disk
git_diff=$(git -C "$WORKTREE" diff origin/main..HEAD --stat 2>/dev/null)
last_phase=$(head -1 "$PHASE_FILE" 2>/dev/null | tr -d '[:space:]')
last_phase="${last_phase:-PHASE:unknown}"
last_ci=$(cat "/tmp/ci-result-${PROJECT_NAME}-${ISSUE}.txt" 2>/dev/null || echo "")
review_comments=$(curl -sf ... "${API}/issues/${PR}/comments" | jq ...)

# 2. Spawn new tmux session in same worktree
tmux new-session -d -s "dev-${PROJECT_NAME}-${ISSUE}" \
  -c "$WORKTREE" \
  "claude --dangerously-skip-permissions"

# 3. Inject recovery context
tmux send-keys -t "dev-${PROJECT_NAME}-${ISSUE}" \
  "$(cat recovery-prompt.txt)" Enter
```

**Recovery context injected into new session:**
- Issue body (what to implement)
- `git diff` of work done so far (git is the checkpoint, not memory)
- Last known phase (where we left off)
- Last CI result (if phase was `awaiting_ci`)
- Latest review comments (if phase was `awaiting_review`)

**Key principle:** Git is the checkpoint. The worktree persists across crashes.
Claude can read `git log`, `git diff`, and `git status` to understand exactly
what was done before the crash. No state needs to be stored beyond the phase
file and git history.

### State files summary

| File | Created by | Purpose |
|------|-----------|---------|
| `/tmp/dev-session-{proj}-{issue}.phase` | Claude (in session) | Current phase |
| `/tmp/ci-result-{proj}-{issue}.txt` | Orchestrator | Last CI output for injection |
| `/tmp/dev-{proj}-{issue}.log` | Orchestrator | Session transcript (aspirational — path TBD when tmux session manager is implemented in #80) |
| `/tmp/dev-renotify-{proj}-{issue}` | supervisor-poll.sh | Marker to prevent duplicate 6h re-notifications |
| `WORKTREE` (git worktree) | dev-agent.sh | Code checkpoint |

## Sequence Diagram

```
Claude session                 Orchestrator (dev-poll.sh)
──────────────                 ──────────────────────────
implement issue
push PR branch
echo "PHASE:awaiting_ci" ───→  read phase file
                               poll CI
                               CI passes
                          ←──  tmux send-keys "CI passed"
echo "PHASE:awaiting_review" → read phase file
                               wait for review-poll
                               review: REQUEST_CHANGES
                          ←──  tmux send-keys "Review: ..."
address review comments
push fixes
echo "PHASE:awaiting_review" → read phase file
                               review: APPROVE
                          ←──  tmux send-keys "Approved"
merge PR
echo "PHASE:done" ──────────→  read phase file
                               verify merged
                               kill session
                               close issue
```

## Notes

- The phase file is write-once-per-phase (always overwritten with `>`).
  The orchestrator reads it, acts, then waits for the next write.
- Claude should write the phase sentinel **as the last action** of each phase,
  after any git push or other side effects are complete.
- If Claude writes `PHASE:failed`, it should include a reason on the next line:
  ```bash
  printf 'PHASE:failed\nReason: %s\n' "$reason" > "$PHASE_FILE"
  ```
- Phase files are cleaned up by the orchestrator after `PHASE:done` or
  `PHASE:failed`.
