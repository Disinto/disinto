#!/usr/bin/env bash
# dev-agent.sh — Autonomous developer agent for a single issue (tmux session manager)
#
# Usage: ./dev-agent.sh <issue-number>
#
# Lifecycle:
#   1. Fetch issue, check dependencies (preflight)
#   2. Claim issue (label: in-progress, remove backlog)
#   3. Create worktree + branch
#   4. Create tmux session: dev-{project}-{issue} with interactive claude
#   5. Send initial prompt via tmux (issue body, context, phase protocol)
#   6. Monitor phase file — Claude signals when it needs input
#   7. React to phases: create PR, poll CI, inject results, inject review, merge
#   8. Kill session on PHASE:done, PHASE:failed, or 2h idle timeout
#
# Phase file:  /tmp/dev-session-{project}-{issue}.phase
# Session:     dev-{project}-{issue} (tmux)
# Peek phase:  head -1 /tmp/dev-session-{project}-{issue}.phase
# Log:         tail -f dev-agent.log

set -euo pipefail

# Load shared environment
source "$(dirname "$0")/../lib/env.sh"
source "$(dirname "$0")/../lib/ci-helpers.sh"
source "$(dirname "$0")/../lib/agent-session.sh"
source "$(dirname "$0")/../lib/formula-session.sh"
# shellcheck source=./phase-handler.sh
source "$(dirname "$0")/phase-handler.sh"

# Auto-pull factory code to pick up merged fixes before any logic runs
git -C "$FACTORY_ROOT" pull --ff-only origin main 2>/dev/null || true

# --- Config ---
ISSUE="${1:?Usage: dev-agent.sh <issue-number>}"
# shellcheck disable=SC2034
REPO="${FORGE_REPO}"
# shellcheck disable=SC2034
REPO_ROOT="${PROJECT_REPO_ROOT}"

API="${FORGE_API}"
LOCKFILE="/tmp/dev-agent-${PROJECT_NAME:-default}.lock"
STATUSFILE="/tmp/dev-agent-status-${PROJECT_NAME:-default}"

# Gitea labels API requires []int64 — look up the "backlog" label ID once
BACKLOG_LABEL_ID=$(forge_api GET "/labels" 2>/dev/null \
  | jq -r '.[] | select(.name == "backlog") | .id' 2>/dev/null || true)
BACKLOG_LABEL_ID="${BACKLOG_LABEL_ID:-1300815}"

# Same for "in-progress" label
IN_PROGRESS_LABEL_ID=$(forge_api GET "/labels" 2>/dev/null \
  | jq -r '.[] | select(.name == "in-progress") | .id' 2>/dev/null || true)
IN_PROGRESS_LABEL_ID="${IN_PROGRESS_LABEL_ID:-1300818}"

log() {
  printf '[%s] #%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$ISSUE" "$*" >> "$LOGFILE"
}

notify() {
  local thread_id=""
  [ -f "${THREAD_FILE:-}" ] && thread_id=$(cat "$THREAD_FILE" 2>/dev/null || true)
  matrix_send "dev" "🔧 #${ISSUE}: $*" "${thread_id}" 2>/dev/null || true
}

notify_ctx() {
  local plain="$1" html="$2"
  local thread_id=""
  [ -f "${THREAD_FILE:-}" ] && thread_id=$(cat "$THREAD_FILE" 2>/dev/null || true)
  if [ -n "$thread_id" ]; then
    matrix_send_ctx "dev" "🔧 #${ISSUE}: ${plain}" "🔧 #${ISSUE}: ${html}" "${thread_id}" 2>/dev/null || true
  else
    matrix_send "dev" "🔧 #${ISSUE}: ${plain}" "" "${ISSUE}" 2>/dev/null || true
  fi
}

status() {
  printf '[%s] dev-agent #%s: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$ISSUE" "$*" > "$STATUSFILE"
  log "$*"
}
LOGFILE="${FACTORY_ROOT}/dev/dev-agent.log"
PREFLIGHT_RESULT="/tmp/dev-agent-preflight.json"
BRANCH="fix/issue-${ISSUE}"
WORKTREE="/tmp/${PROJECT_NAME}-worktree-${ISSUE}"

# Tmux session + phase protocol
PHASE_FILE="/tmp/dev-session-${PROJECT_NAME}-${ISSUE}.phase"
SESSION_NAME="dev-${PROJECT_NAME}-${ISSUE}"
IMPL_SUMMARY_FILE="/tmp/dev-impl-summary-${PROJECT_NAME}-${ISSUE}.txt"

# Matrix thread tracking — one thread per issue for conversational notifications
THREAD_FILE="/tmp/dev-thread-${PROJECT_NAME}-${ISSUE}"

# Scratch file for context compaction survival
SCRATCH_FILE="/tmp/dev-${PROJECT_NAME}-${ISSUE}-scratch.md"

# Timing
export PHASE_POLL_INTERVAL=30    # seconds between phase checks (read by agent-session.sh)
IDLE_TIMEOUT=7200         # 2h: kill session if phase stale this long
# shellcheck disable=SC2034  # used by phase-handler.sh
CI_POLL_TIMEOUT=1800      # 30min max for CI to complete
# shellcheck disable=SC2034  # used by phase-handler.sh
REVIEW_POLL_TIMEOUT=10800 # 3h max wait for review

# Limits
# shellcheck disable=SC2034  # used by phase-handler.sh
MAX_CI_FIXES=3
# shellcheck disable=SC2034  # used by phase-handler.sh
MAX_REVIEW_ROUNDS=5

# Counters — global state shared with phase-handler.sh across phase transitions
# shellcheck disable=SC2034
CI_RETRY_COUNT=0
# shellcheck disable=SC2034
CI_FIX_COUNT=0
# shellcheck disable=SC2034
REVIEW_ROUND=0
PR_NUMBER=""

# --- Cleanup helpers ---
cleanup_worktree() {
  cd "$REPO_ROOT"
  git worktree remove "$WORKTREE" --force 2>/dev/null || true
  rm -rf "$WORKTREE"
  # Clear Claude Code session history for this worktree to prevent hallucinated "already done"
  CLAUDE_PROJECT_DIR="$HOME/.claude/projects/$(echo "$WORKTREE" | sed 's|/|-|g; s|^-||')"
  rm -rf "$CLAUDE_PROJECT_DIR" 2>/dev/null || true
}

cleanup_labels() {
  curl -sf -X DELETE \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/issues/${ISSUE}/labels/${IN_PROGRESS_LABEL_ID}" >/dev/null 2>&1 || true
}

restore_to_backlog() {
  cleanup_labels
  curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API}/issues/${ISSUE}/labels" \
    -d "{\"labels\":[${BACKLOG_LABEL_ID}]}" >/dev/null 2>&1 || true
  CLAIMED=false  # Don't unclaim again in cleanup()
}

CLAIMED=false
cleanup() {
  rm -f "$LOCKFILE" "$STATUSFILE"
  # Kill any live session so Claude doesn't run without an orchestrator attached
  agent_kill_session "$SESSION_NAME"
  # If we claimed the issue but never created a PR, unclaim it
  if [ "$CLAIMED" = true ] && [ -z "${PR_NUMBER:-}" ]; then
    log "cleanup: unclaiming issue (no PR created)"
    curl -sf -X DELETE \
      -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/issues/${ISSUE}/labels/${IN_PROGRESS_LABEL_ID}" >/dev/null 2>&1 || true
    curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/issues/${ISSUE}/labels" \
      -d "{\"labels\":[${BACKLOG_LABEL_ID}]}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT


# =============================================================================
# LOG ROTATION
# =============================================================================
if [ -f "$LOGFILE" ] && [ "$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)" -gt 102400 ]; then
  mv "$LOGFILE" "$LOGFILE.old"
  log "Log rotated"
fi

# =============================================================================
# MEMORY GUARD
# =============================================================================
AVAIL_MB=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
if [ "$AVAIL_MB" -lt 2000 ]; then
  log "SKIP: only ${AVAIL_MB}MB available (need 2000MB)"
  exit 0
fi

# =============================================================================
# CONCURRENCY LOCK
# =============================================================================
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "SKIP: another dev-agent running (PID ${LOCK_PID})"
    exit 0
  fi
  log "Removing stale lock (PID ${LOCK_PID:-?})"
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"

# =============================================================================
# FETCH ISSUE
# =============================================================================
status "fetching issue"
ISSUE_JSON=$(curl -s -H "Authorization: token ${FORGE_TOKEN}" "${API}/issues/${ISSUE}") || true
if [ -z "$ISSUE_JSON" ] || ! echo "$ISSUE_JSON" | jq -e '.id' >/dev/null 2>&1; then
  log "ERROR: failed to fetch issue #${ISSUE} (API down or invalid response)"
  exit 1
fi
ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body // ""')
ISSUE_BODY_ORIGINAL="$ISSUE_BODY"

# --- Resolve bot username(s) for comment filtering ---
_bot_login=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API%%/repos*}/user" | jq -r '.login // empty' 2>/dev/null || true)

# Build list: token owner + any extra names from FORGE_BOT_USERNAMES (comma-separated)
_bot_logins="${_bot_login}"
if [ -n "${FORGE_BOT_USERNAMES:-}" ]; then
  _bot_logins="${_bot_logins:+${_bot_logins},}${FORGE_BOT_USERNAMES}"
fi

# Append human comments to issue body (filter out bot accounts)
ISSUE_COMMENTS=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/issues/${ISSUE}/comments" | \
  jq -r --arg bots "$_bot_logins" \
    '($bots | split(",") | map(select(. != ""))) as $bl |
     .[] | select(.user.login as $u | $bl | index($u) | not) |
     "### @\(.user.login) (\(.created_at[:10])):\n\(.body)\n"' 2>/dev/null || true)
if [ -n "$ISSUE_COMMENTS" ]; then
  ISSUE_BODY="${ISSUE_BODY}

## Issue comments
${ISSUE_COMMENTS}"
fi
ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state')

if [ "$ISSUE_STATE" != "open" ]; then
  log "SKIP: issue #${ISSUE} is ${ISSUE_STATE}"
  echo '{"status":"already_done","reason":"issue is closed"}' > "$PREFLIGHT_RESULT"
  exit 0
fi

log "Issue: ${ISSUE_TITLE}"

# =============================================================================
# GUARD: Reject formula-labeled issues (feat/formula not yet merged)
# =============================================================================
ISSUE_LABELS=$(echo "$ISSUE_JSON" | jq -r '[.labels[].name] | join(",")') || true
if echo "$ISSUE_LABELS" | grep -qw 'formula'; then
  log "SKIP: issue #${ISSUE} has 'formula' label but formula dispatch is not yet implemented (feat/formula branch not merged)"
  notify "issue #${ISSUE} skipped — formula label requires feat/formula branch (not yet merged to main)"
  echo '{"status":"unmet_dependency","blocked_by":"formula dispatch not implemented — feat/formula branch not merged to main","suggestion":null}' > "$PREFLIGHT_RESULT"
  exit 0
fi

# =============================================================================
# PREFLIGHT: Check dependencies before doing any work
# =============================================================================
status "preflight check"

# Extract dependency references using shared parser (use original body only — not comments)
DEP_NUMBERS=$(echo "$ISSUE_BODY_ORIGINAL" | bash "${FACTORY_ROOT}/lib/parse-deps.sh")

BLOCKED_BY=()
if [ -n "$DEP_NUMBERS" ]; then
  while IFS= read -r dep_num; do
    [ -z "$dep_num" ] && continue
    # Check if dependency issue is closed (= satisfied)
    DEP_STATE=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/issues/${dep_num}" | jq -r '.state // "unknown"')

    if [ "$DEP_STATE" != "closed" ]; then
      BLOCKED_BY+=("$dep_num")
      log "dependency #${dep_num} is ${DEP_STATE} (not satisfied)"
    else
      log "dependency #${dep_num} is closed (satisfied)"
    fi
  done <<< "$DEP_NUMBERS"
fi

if [ "${#BLOCKED_BY[@]}" -gt 0 ]; then
  # Find a suggestion: look for the first blocker that itself has no unmet deps
  SUGGESTION=""
  for blocker in "${BLOCKED_BY[@]}"; do
    BLOCKER_BODY=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/issues/${blocker}" | jq -r '.body // ""')
    BLOCKER_STATE=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/issues/${blocker}" | jq -r '.state')

    if [ "$BLOCKER_STATE" != "open" ]; then
      continue
    fi

    # Check if this blocker has its own unmet deps
    BLOCKER_DEPS=$(echo "$BLOCKER_BODY" | \
      grep -ioP '(?:depends on|blocked by|requires|after)\s+#\K[0-9]+' | sort -un || true)
    BLOCKER_SECTION=$(echo "$BLOCKER_BODY" | sed -n '/^## Dependencies/,/^## /p' | sed '1d;$d')
    if [ -n "$BLOCKER_SECTION" ]; then
      BLOCKER_SECTION_DEPS=$(echo "$BLOCKER_SECTION" | grep -oP '#\K[0-9]+' | sort -un || true)
      BLOCKER_DEPS=$(printf '%s\n%s' "$BLOCKER_DEPS" "$BLOCKER_SECTION_DEPS" | sort -un | grep -v '^$' || true)
    fi

    BLOCKER_BLOCKED=false
    if [ -n "$BLOCKER_DEPS" ]; then
      while IFS= read -r bd; do
        [ -z "$bd" ] && continue
        BD_STATE=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
          "${API}/issues/${bd}" | jq -r '.state // "unknown"')
        if [ "$BD_STATE" != "closed" ]; then
          BLOCKER_BLOCKED=true
          break
        fi
      done <<< "$BLOCKER_DEPS"
    fi

    if [ "$BLOCKER_BLOCKED" = false ]; then
      SUGGESTION="$blocker"
      break
    fi
  done

  # Write preflight result
  BLOCKED_JSON=$(printf '%s\n' "${BLOCKED_BY[@]}" | jq -R 'tonumber' | jq -sc '.')
  if [ -n "$SUGGESTION" ]; then
    jq -n --argjson blocked "$BLOCKED_JSON" --argjson suggestion "$SUGGESTION" \
      '{"status":"unmet_dependency","blocked_by":$blocked,"suggestion":$suggestion}' > "$PREFLIGHT_RESULT"
  else
    jq -n --argjson blocked "$BLOCKED_JSON" \
      '{"status":"unmet_dependency","blocked_by":$blocked,"suggestion":null}' > "$PREFLIGHT_RESULT"
  fi

  # Post comment ONLY if last comment isn't already an unmet dependency notice
  BLOCKED_LIST=$(printf '#%s, ' "${BLOCKED_BY[@]}" | sed 's/, $//')
  LAST_COMMENT_IS_BLOCK=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/issues/${ISSUE}/comments?limit=1" | \
    jq -r '.[0].body // ""' | grep -c 'Dev-agent: Unmet dependency' || true)

  if [ "$LAST_COMMENT_IS_BLOCK" -eq 0 ]; then
    BLOCK_COMMENT="🚧 **Dev-agent: Unmet dependency**

### Blocked by open issues

This issue depends on ${BLOCKED_LIST}, which $(if [ "${#BLOCKED_BY[@]}" -eq 1 ]; then echo "is"; else echo "are"; fi) not yet closed."
    if [ -n "$SUGGESTION" ]; then
      BLOCK_COMMENT="${BLOCK_COMMENT}

**Suggestion:** Work on #${SUGGESTION} first."
    fi
    BLOCK_COMMENT="${BLOCK_COMMENT}

---
*Automated assessment by dev-agent · $(date -u '+%Y-%m-%d %H:%M UTC')*"

    printf '%s' "$BLOCK_COMMENT" > /tmp/block-comment.txt
    jq -Rs '{body: .}' < /tmp/block-comment.txt > /tmp/block-comment.json
    curl -sf -o /dev/null -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/issues/${ISSUE}/comments" \
      --data-binary @/tmp/block-comment.json 2>/dev/null || true
    rm -f /tmp/block-comment.txt /tmp/block-comment.json
  else
    log "skipping duplicate dependency comment"
  fi

  log "BLOCKED: unmet dependencies: ${BLOCKED_BY[*]}$(if [ -n "$SUGGESTION" ]; then echo ", suggest #${SUGGESTION}"; fi)"
  notify "blocked by unmet dependencies: ${BLOCKED_BY[*]}"
  exit 0
fi

# Preflight passed (no explicit unmet deps)
log "preflight passed — no explicit unmet dependencies"

# =============================================================================
# CLAIM ISSUE
# =============================================================================
curl -sf -X POST \
  -H "Authorization: token ${FORGE_TOKEN}" \
  -H "Content-Type: application/json" \
  "${API}/issues/${ISSUE}/labels" \
  -d "{\"labels\":[${IN_PROGRESS_LABEL_ID}]}" >/dev/null 2>&1 || true

curl -sf -X DELETE \
  -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/issues/${ISSUE}/labels/${BACKLOG_LABEL_ID}" >/dev/null 2>&1 || true

CLAIMED=true

# =============================================================================
# CHECK FOR EXISTING PR (recovery mode)
# =============================================================================
EXISTING_PR=""
EXISTING_BRANCH=""
RECOVERY_MODE=false

BODY_PR=$(echo "$ISSUE_BODY_ORIGINAL" | grep -oP 'Existing PR:\s*#\K[0-9]+' | head -1) || true
if [ -n "$BODY_PR" ]; then
  PR_CHECK=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/pulls/${BODY_PR}" | jq -r '{state, head_ref: .head.ref}')
  PR_CHECK_STATE=$(echo "$PR_CHECK" | jq -r '.state')
  if [ "$PR_CHECK_STATE" = "open" ]; then
    EXISTING_PR="$BODY_PR"
    EXISTING_BRANCH=$(echo "$PR_CHECK" | jq -r '.head_ref')
    log "found existing PR #${EXISTING_PR} on branch ${EXISTING_BRANCH} (from issue body)"
  fi
fi

if [ -z "$EXISTING_PR" ]; then
  # Priority 1: match by branch name (most reliable)
  FOUND_PR=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/pulls?state=open&limit=20" | \
    jq -r --arg branch "$BRANCH" \
    '.[] | select(.head.ref == $branch) | "\(.number) \(.head.ref)"' | head -1) || true
  if [ -n "$FOUND_PR" ]; then
    EXISTING_PR=$(echo "$FOUND_PR" | awk '{print $1}')
    EXISTING_BRANCH=$(echo "$FOUND_PR" | awk '{print $2}')
    log "found existing PR #${EXISTING_PR} on branch ${EXISTING_BRANCH} (from branch match)"
  fi
fi

if [ -z "$EXISTING_PR" ]; then
  # Priority 2: match "Fixes #NNN" in PR body
  FOUND_PR=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/pulls?state=open&limit=20" | \
    jq -r --arg issue "ixes #${ISSUE}\\b" \
    '.[] | select(.body | test($issue; "i")) | "\(.number) \(.head.ref)"' | head -1) || true
  if [ -n "$FOUND_PR" ]; then
    EXISTING_PR=$(echo "$FOUND_PR" | awk '{print $1}')
    EXISTING_BRANCH=$(echo "$FOUND_PR" | awk '{print $2}')
    log "found existing PR #${EXISTING_PR} on branch ${EXISTING_BRANCH} (from body match)"
  fi
fi

# Priority 3: check CLOSED PRs for prior art (don't redo work from scratch)
PRIOR_ART_DIFF=""
if [ -z "$EXISTING_PR" ]; then
  CLOSED_PR=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/pulls?state=closed&limit=30" | \
    jq -r --arg issue "#${ISSUE}" \
    '.[] | select(.merged != true) | select((.title | contains($issue)) or (.body // "" | test("ixes " + $issue + "\\b"; "i"))) | "\(.number) \(.head.ref)"' | head -1) || true
  if [ -n "$CLOSED_PR" ]; then
    CLOSED_PR_NUM=$(echo "$CLOSED_PR" | awk '{print $1}')
    log "found closed (unmerged) PR #${CLOSED_PR_NUM} as prior art"
    PRIOR_ART_DIFF=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/pulls/${CLOSED_PR_NUM}.diff" | head -500) || true
    if [ -n "$PRIOR_ART_DIFF" ]; then
      log "captured prior art diff from PR #${CLOSED_PR_NUM} ($(echo "$PRIOR_ART_DIFF" | wc -l) lines)"
    fi
  fi
fi

if [ -n "$EXISTING_PR" ]; then
  RECOVERY_MODE=true
  PR_NUMBER="$EXISTING_PR"
  BRANCH="$EXISTING_BRANCH"
  log "RECOVERY MODE: adopting PR #${PR_NUMBER} on branch ${BRANCH}"
fi

# =============================================================================
# WORKTREE SETUP
# =============================================================================
status "setting up worktree"
cd "$REPO_ROOT"

if [ "$RECOVERY_MODE" = true ]; then
  git fetch origin "$BRANCH" 2>/dev/null

  # Reuse existing worktree if on the right branch (preserves session context)
  REUSE_WORKTREE=false
  if [ -d "$WORKTREE/.git" ] || [ -f "$WORKTREE/.git" ]; then
    WT_BRANCH=$(cd "$WORKTREE" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ "$WT_BRANCH" = "$BRANCH" ]; then
      log "reusing existing worktree (preserves session)"
      cd "$WORKTREE"
      git pull --ff-only origin "$BRANCH" 2>/dev/null || git reset --hard "origin/${BRANCH}" 2>/dev/null || true
      REUSE_WORKTREE=true
    fi
  fi

  if [ "$REUSE_WORKTREE" = false ]; then
    cleanup_worktree
    git worktree add "$WORKTREE" "origin/${BRANCH}" -B "$BRANCH" 2>&1 || {
      log "ERROR: worktree creation failed for recovery"
      cleanup_labels
      exit 1
    }
    cd "$WORKTREE"
    git submodule update --init --recursive 2>/dev/null || true
  fi
else
  # Normal mode: create fresh worktree from primary branch

  # Ensure repo is in clean state (abort stale rebases, checkout primary branch)
  if [ -d "$REPO_ROOT/.git/rebase-merge" ] || [ -d "$REPO_ROOT/.git/rebase-apply" ]; then
    log "WARNING: stale rebase detected in main repo — aborting"
    git rebase --abort 2>/dev/null || true
  fi
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  if [ "$CURRENT_BRANCH" != "${PRIMARY_BRANCH}" ]; then
    log "WARNING: main repo on '$CURRENT_BRANCH' instead of ${PRIMARY_BRANCH} — switching"
    git checkout "${PRIMARY_BRANCH}" 2>/dev/null || true
  fi

  git fetch origin "${PRIMARY_BRANCH}" 2>/dev/null
  git pull --ff-only origin "${PRIMARY_BRANCH}" 2>/dev/null || true
  cleanup_worktree
  git worktree add "$WORKTREE" "origin/${PRIMARY_BRANCH}" -B "$BRANCH" 2>&1 || {
    log "ERROR: worktree creation failed"
    git worktree add "$WORKTREE" "origin/${PRIMARY_BRANCH}" -B "$BRANCH" 2>&1 | while read -r wt_line; do log "  $wt_line"; done || true
    cleanup_labels
    exit 1
  }
  cd "$WORKTREE"
  git checkout -B "$BRANCH" "origin/${PRIMARY_BRANCH}" 2>/dev/null
  git submodule update --init --recursive 2>/dev/null || true

  # Symlink lib node_modules from main repo (submodule init doesn't run npm install)
  for lib_dir in "$REPO_ROOT"/onchain/lib/*/; do
    lib_name=$(basename "$lib_dir")
    if [ -d "$lib_dir/node_modules" ] && [ ! -d "$WORKTREE/onchain/lib/$lib_name/node_modules" ]; then
      ln -s "$lib_dir/node_modules" "$WORKTREE/onchain/lib/$lib_name/node_modules" 2>/dev/null || true
    fi
  done
fi

# =============================================================================
# READ SCRATCH FILE (compaction survival)
# =============================================================================
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# =============================================================================
# BUILD PROMPT
# =============================================================================
OPEN_ISSUES_SUMMARY=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/issues?state=open&labels=backlog&limit=20&type=issues" | \
  jq -r '.[] | "#\(.number) \(.title)"' 2>/dev/null || echo "(could not fetch)")

PHASE_PROTOCOL_INSTRUCTIONS="## Phase-Signaling Protocol (REQUIRED)

You are running in a persistent tmux session managed by an orchestrator.
Communicate progress by writing to the phase file. The orchestrator watches
this file and injects events (CI results, review feedback) back into this session.

### Key files
\`\`\`
PHASE_FILE=\"${PHASE_FILE}\"
SUMMARY_FILE=\"${IMPL_SUMMARY_FILE}\"
\`\`\`

### Phase transitions — write these exactly:

**After committing and pushing your branch:**
\`\`\`bash
git push origin ${BRANCH}
# Write a short summary of what you implemented:
printf '%s' \"<your summary>\" > \"\${SUMMARY_FILE}\"
# Signal the orchestrator to create the PR and watch for CI:
echo \"PHASE:awaiting_ci\" > \"${PHASE_FILE}\"
\`\`\`
Then STOP and wait. The orchestrator will inject CI results.

**When you receive a \"CI passed\" injection:**
\`\`\`bash
echo \"PHASE:awaiting_review\" > \"${PHASE_FILE}\"
\`\`\`
Then STOP and wait. The orchestrator will inject review feedback.

**When you receive a \"CI failed:\" injection:**
Fix the CI issue, commit, push, then:
\`\`\`bash
echo \"PHASE:awaiting_ci\" > \"${PHASE_FILE}\"
\`\`\`
Then STOP and wait.

**When you receive a \"Review: REQUEST_CHANGES\" injection:**
Address ALL review feedback, commit, push, then:
\`\`\`bash
echo \"PHASE:awaiting_ci\" > \"${PHASE_FILE}\"
\`\`\`
(CI runs again after each push — always write awaiting_ci, not awaiting_review)

**When you receive an \"Approved\" injection:**
The orchestrator handles merging and issue closure automatically via the bash
phase handler. You do not need to merge or close anything — stop and wait.

**When you need human help (CI exhausted, merge blocked, stuck on a decision):**
\`\`\`bash
printf 'PHASE:escalate\nReason: %s\n' \"describe what you need\" > \"${PHASE_FILE}\"
\`\`\`
Then STOP and wait. A human will reply via Matrix and the response will be injected.

**If refusing (too large, unmet dep, already done):**
\`\`\`bash
printf '%s' '{\"status\":\"too_large\",\"reason\":\"...\"}' > \"\${SUMMARY_FILE}\"
printf 'PHASE:failed\nReason: refused\n' > \"${PHASE_FILE}\"
\`\`\`

**On unrecoverable failure:**
\`\`\`bash
printf 'PHASE:failed\nReason: %s\n' \"describe what failed\" > \"${PHASE_FILE}\"
\`\`\`"

# Write phase protocol to context file for compaction survival
write_compact_context "$PHASE_FILE" "$PHASE_PROTOCOL_INSTRUCTIONS"

if [ "$RECOVERY_MODE" = true ]; then
  # Build recovery context
  GIT_DIFF_STAT=$(git -C "$WORKTREE" diff "origin/${PRIMARY_BRANCH}..HEAD" --stat 2>/dev/null | head -20 || echo "(no diff)")
  LAST_PHASE=$(read_phase)
  CI_RESULT=$(cat "/tmp/ci-result-${PROJECT_NAME}-${ISSUE}.txt" 2>/dev/null || echo "")
  REVIEW_COMMENTS=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/issues/${PR_NUMBER}/comments?limit=10" | \
    jq -r '.[-3:] | .[] | "[\(.user.login)] \(.body[:500])"' 2>/dev/null || echo "(none)")

  INITIAL_PROMPT="You are working in a git worktree at ${WORKTREE} on branch ${BRANCH}.
This is issue #${ISSUE} for the ${FORGE_REPO} project.

## Issue: ${ISSUE_TITLE}

${ISSUE_BODY}
${SCRATCH_CONTEXT}
## CRASH RECOVERY

Your previous session for this issue was interrupted. Resume from where you left off.
Git is the checkpoint — your code changes survived.

### Work completed before crash:
\`\`\`
${GIT_DIFF_STAT}
\`\`\`

### Last known phase: ${LAST_PHASE:-unknown}

### PR: #${PR_NUMBER} (${BRANCH})

### Recent PR comments:
${REVIEW_COMMENTS}
$(if [ -n "$CI_RESULT" ]; then printf '\n### Last CI result:\n%s\n' "$CI_RESULT"; fi)

### Next steps
1. Run \`git log --oneline -5\` and \`git status\` to understand current state.
2. Resume from the last known phase.
3. Follow the phase protocol below.

${SCRATCH_INSTRUCTION}

${PHASE_PROTOCOL_INSTRUCTIONS}"
else
  # Normal mode: initial implementation prompt
  INITIAL_PROMPT="You are working in a git worktree at ${WORKTREE} on branch ${BRANCH}.
You have been assigned issue #${ISSUE} for the ${FORGE_REPO} project.

## Issue: ${ISSUE_TITLE}

${ISSUE_BODY}
${SCRATCH_CONTEXT}
## Other open issues labeled 'backlog' (for context if you need to suggest alternatives):
${OPEN_ISSUES_SUMMARY}

$(if [ -n "$PRIOR_ART_DIFF" ]; then
  printf '## Prior Art (closed PR — DO NOT start from scratch)\n\nA previous PR attempted this issue but was closed without merging. Review the diff below and reuse as much as possible. Fix whatever caused it to fail (merge conflicts, CI errors, review findings).\n\n```diff\n%s\n```\n' "$PRIOR_ART_DIFF"
fi)

## Instructions

**Before implementing, assess whether you should proceed.** You have two options:

### Option A: Implement
If the issue is clear, dependencies are met, and scope is reasonable:
1. Read AGENTS.md in this repo for project context and coding conventions.
2. Implement the changes described in the issue.
3. Run lint and tests before you're done (see AGENTS.md for commands).
4. Commit your changes with message: fix: ${ISSUE_TITLE} (#${ISSUE})
5. Follow the phase protocol below to signal progress.

### Option B: Refuse (write JSON to SUMMARY_FILE, then write PHASE:failed)
If you cannot or should not implement this issue, write ONLY a JSON object to \$SUMMARY_FILE:

**Unmet dependency** — required code/infrastructure doesn't exist in the repo yet:
\`\`\`
{\"status\": \"unmet_dependency\", \"blocked_by\": \"short explanation of what's missing\", \"suggestion\": <issue-number-to-work-on-first or null>}
\`\`\`

**Too large** — issue needs to be split, spec is too vague, or scope exceeds a single session:
\`\`\`
{\"status\": \"too_large\", \"reason\": \"what makes it too large and how to split it\"}
\`\`\`

**Already done** — the work described is already implemented in the codebase:
\`\`\`
{\"status\": \"already_done\", \"reason\": \"where the existing implementation is\"}
\`\`\`

Then write:
\`\`\`bash
printf 'PHASE:failed\nReason: refused\n' > \"${PHASE_FILE}\"
\`\`\`

### How to decide
- Read the issue carefully. Check if files/functions it references actually exist in the repo.
- If it depends on other issues, check if those issues' deliverables are present in the codebase.
- If the issue spec is vague or requires designing multiple new systems, refuse as too_large.
- If another open issue should be done first, suggest it.
- When in doubt, implement. Only refuse if there's a clear, specific reason.

**Do NOT invent dependencies that aren't real.** If the code compiles and tests pass, that's ready.

${SCRATCH_INSTRUCTION}

${PHASE_PROTOCOL_INSTRUCTIONS}"
fi

# =============================================================================
# CREATE MATRIX THREAD (before tmux so MATRIX_THREAD_ID is available for Stop hook)
# =============================================================================
if [ ! -f "${THREAD_FILE}" ] || [ -z "$(cat "$THREAD_FILE" 2>/dev/null)" ]; then
  ISSUE_URL="${FORGE_WEB}/issues/${ISSUE}"
  _thread_id=$(matrix_send_ctx "dev" \
    "🔧 Issue #${ISSUE}: ${ISSUE_TITLE} — ${ISSUE_URL}" \
    "🔧 <a href='${ISSUE_URL}'>Issue #${ISSUE}</a>: ${ISSUE_TITLE}") || true
  if [ -n "${_thread_id:-}" ]; then
    printf '%s' "$_thread_id" > "$THREAD_FILE"
    # Register thread root in map for listener dispatch
    printf '%s\t%s\t%s\t%s\t%s\n' "$_thread_id" "dev" "$(date +%s)" "${ISSUE}" "${PROJECT_NAME}" >> "${MATRIX_THREAD_MAP:-/tmp/matrix-thread-map}" 2>/dev/null || true
  fi
fi

# Export for on-stop-matrix.sh hook (streams Claude output to thread)
_thread_id=$(cat "$THREAD_FILE" 2>/dev/null || true)
if [ -n "${_thread_id:-}" ]; then
  export MATRIX_THREAD_ID="$_thread_id"
fi

# =============================================================================
# CREATE TMUX SESSION
# =============================================================================
status "creating tmux session: ${SESSION_NAME}"

if ! create_agent_session "${SESSION_NAME}" "${WORKTREE}" "${PHASE_FILE}"; then
  log "ERROR: failed to create agent session"
  cleanup_labels
  cleanup_worktree
  exit 1
fi

# Send initial prompt into the session
inject_formula "${SESSION_NAME}" "${INITIAL_PROMPT}"
log "initial prompt sent to tmux session"

# Signal to dev-poll.sh that we're running (session is up)
echo '{"status":"ready"}' > "$PREFLIGHT_RESULT"
notify "tmux session ${SESSION_NAME} started for issue #${ISSUE}: ${ISSUE_TITLE}"


status "monitoring phase: ${PHASE_FILE}"
monitor_phase_loop "$PHASE_FILE" "$IDLE_TIMEOUT" _on_phase_change

# Handle exit reason from monitor_phase_loop
case "${_MONITOR_LOOP_EXIT:-}" in
  idle_timeout|idle_prompt)
    if [ "${_MONITOR_LOOP_EXIT:-}" = "idle_prompt" ]; then
      notify_ctx \
        "session finished without phase signal — killed. Marking blocked." \
        "session finished without phase signal — killed. Marking blocked.${PR_NUMBER:+ PR <a href='${FORGE_WEB}/pulls/${PR_NUMBER}'>#${PR_NUMBER}</a>}"
    else
      notify_ctx \
        "session idle for 2h — killed. Marking blocked." \
        "session idle for 2h — killed. Marking blocked.${PR_NUMBER:+ PR <a href='${FORGE_WEB}/pulls/${PR_NUMBER}'>#${PR_NUMBER}</a>}"
    fi
    # Post diagnostic comment + label issue blocked
    post_blocked_diagnostic "${_MONITOR_LOOP_EXIT:-idle_timeout}"
    if [ -n "${PR_NUMBER:-}" ]; then
      log "keeping worktree (PR #${PR_NUMBER} still open)"
    else
      cleanup_worktree
    fi
    rm -f "$PHASE_FILE" "${PHASE_FILE%.phase}.context" \
      "$IMPL_SUMMARY_FILE" "$THREAD_FILE" "$SCRATCH_FILE" \
      "/tmp/ci-result-${PROJECT_NAME}-${ISSUE}.txt"
    [ -n "${PR_NUMBER:-}" ] && rm -f "/tmp/review-injected-${PROJECT_NAME}-${PR_NUMBER}"
    ;;
  crashed)
    # Belt-and-suspenders: _on_phase_change(PHASE:crashed) handles primary
    # cleanup (diagnostic comment, blocked label, worktree, files).
    # Only post if the callback didn't already (guard prevents double comment).
    if [ "${_BLOCKED_POSTED:-}" != "true" ]; then
      post_blocked_diagnostic "crashed"
    fi
    ;;
  done)
    # Belt-and-suspenders: callback in phase-handler.sh handles primary cleanup,
    # but ensure sentinel files are removed if callback was interrupted
    rm -f "$PHASE_FILE" "${PHASE_FILE%.phase}.context" \
      "$IMPL_SUMMARY_FILE" "$THREAD_FILE" "$SCRATCH_FILE" \
      "/tmp/ci-result-${PROJECT_NAME}-${ISSUE}.txt"
    [ -n "${PR_NUMBER:-}" ] && rm -f "/tmp/review-injected-${PROJECT_NAME}-${PR_NUMBER}"
    CLAIMED=false
    ;;
esac

log "dev-agent finished for issue #${ISSUE}"
