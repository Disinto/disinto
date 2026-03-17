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

# Auto-pull factory code to pick up merged fixes before any logic runs
git -C "$FACTORY_ROOT" pull --ff-only origin main 2>/dev/null || true

# --- Config ---
ISSUE="${1:?Usage: dev-agent.sh <issue-number>}"
REPO="${CODEBERG_REPO}"
REPO_ROOT="${PROJECT_REPO_ROOT}"

API="${CODEBERG_API}"
LOCKFILE="/tmp/dev-agent-${PROJECT_NAME:-harb}.lock"
STATUSFILE="/tmp/dev-agent-status"
LOGFILE="${FACTORY_ROOT}/dev/dev-agent.log"
PREFLIGHT_RESULT="/tmp/dev-agent-preflight.json"
BRANCH="fix/issue-${ISSUE}"
WORKTREE="/tmp/${PROJECT_NAME}-worktree-${ISSUE}"

# Tmux session + phase protocol
PHASE_FILE="/tmp/dev-session-${PROJECT_NAME}-${ISSUE}.phase"
SESSION_NAME="dev-${PROJECT_NAME}-${ISSUE}"
IMPL_SUMMARY_FILE="/tmp/dev-impl-summary-${PROJECT_NAME}-${ISSUE}.txt"

# Timing
PHASE_POLL_INTERVAL=30    # seconds between phase checks
IDLE_TIMEOUT=7200         # 2h: kill session if phase stale this long
CI_POLL_TIMEOUT=1800      # 30min max for CI to complete
REVIEW_POLL_TIMEOUT=10800 # 3h max wait for review

# Counters — global state across phase transitions
CI_RETRY_COUNT=0
CI_FIX_COUNT=0
REVIEW_ROUND=0
PR_NUMBER=""

# --- Logging ---
log() {
  printf '[%s] #%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$ISSUE" "$*" >> "$LOGFILE"
}

status() {
  printf '[%s] dev-agent #%s: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$ISSUE" "$*" > "$STATUSFILE"
  log "$*"
}

notify() {
  matrix_send "dev" "🔧 #${ISSUE}: $*" 2>/dev/null || true
}

# --- Phase helpers ---
read_phase() {
  { cat "$PHASE_FILE" 2>/dev/null || true; } | head -1 | tr -d '[:space:]'
}

inject_into_session() {
  local text="$1"
  local tmpfile
  tmpfile=$(mktemp /tmp/tmux-inject-XXXXXX)
  printf '%s' "$text" > "$tmpfile"
  tmux load-buffer -b "inject-${ISSUE}" "$tmpfile"
  tmux paste-buffer -t "${SESSION_NAME}" -b "inject-${ISSUE}"
  sleep 0.5
  tmux send-keys -t "${SESSION_NAME}" "" Enter
  tmux delete-buffer -b "inject-${ISSUE}" 2>/dev/null || true
  rm -f "$tmpfile"
}

kill_tmux_session() {
  tmux kill-session -t "${SESSION_NAME}" 2>/dev/null || true
}

# --- Refusal comment helper (used in PHASE:failed handler) ---
post_refusal_comment() {
  local emoji="$1" title="$2" body="$3"
  local last_has_title
  last_has_title=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/issues/${ISSUE}/comments?limit=1" | \
    jq -r --arg t "Dev-agent: ${title}" '.[0].body // "" | contains($t)') || true
  if [ "$last_has_title" = "true" ]; then
    log "skipping duplicate refusal comment: ${title}"
    return 0
  fi
  local comment="${emoji} **Dev-agent: ${title}**

${body}

---
*Automated assessment by dev-agent · $(date -u '+%Y-%m-%d %H:%M UTC')*"
  printf '%s' "$comment" > "/tmp/refusal-comment.txt"
  jq -Rs '{body: .}' < "/tmp/refusal-comment.txt" > "/tmp/refusal-comment.json"
  curl -sf -o /dev/null -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API}/issues/${ISSUE}/comments" \
    --data-binary @"/tmp/refusal-comment.json" 2>/dev/null || \
    log "WARNING: failed to post refusal comment"
  rm -f "/tmp/refusal-comment.txt" "/tmp/refusal-comment.json"
}

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
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/issues/${ISSUE}/labels/in-progress" >/dev/null 2>&1 || true
}

CLAIMED=false
cleanup() {
  rm -f "$LOCKFILE" "$STATUSFILE"
  # If we claimed the issue but never created a PR, unclaim it
  if [ "$CLAIMED" = true ] && [ -z "${PR_NUMBER:-}" ]; then
    log "cleanup: unclaiming issue (no PR created)"
    curl -sf -X DELETE \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/issues/${ISSUE}/labels/in-progress" >/dev/null 2>&1 || true
    curl -sf -X POST \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/issues/${ISSUE}/labels" \
      -d '{"labels":["backlog"]}' >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# =============================================================================
# MERGE HELPER
# =============================================================================
do_merge() {
  local sha="$1"
  local pr="${PR_NUMBER}"

  for _m in $(seq 1 20); do
    local ci
    ci=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/commits/${sha}/status" | jq -r '.state // "unknown"')
    [ "$ci" = "success" ] && break
    sleep 30
  done

  # Pre-emptive rebase to avoid merge conflicts
  local mergeable
  mergeable=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls/${pr}" | jq -r '.mergeable // true')
  if [ "$mergeable" = "false" ]; then
    log "PR #${pr} has merge conflicts — attempting rebase"
    local work_dir="${WORKTREE:-$REPO_ROOT}"
    if (cd "$work_dir" && git fetch origin "${PRIMARY_BRANCH}" && git rebase "origin/${PRIMARY_BRANCH}" 2>&1); then
      log "rebase succeeded — force pushing"
      (cd "$work_dir" && git push origin "${BRANCH}" --force-with-lease 2>&1) || true
      sha=$(cd "$work_dir" && git rev-parse HEAD)
      log "waiting for CI on rebased commit ${sha:0:7}"
      local r_ci
      for _r in $(seq 1 20); do
        r_ci=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
          "${API}/commits/${sha}/status" | jq -r '.state // "unknown"')
        [ "$r_ci" = "success" ] && break
        if [ "$r_ci" = "failure" ] || [ "$r_ci" = "error" ]; then
          log "CI failed after rebase"
          notify "PR #${pr} CI failed after rebase. Needs manual fix."
          return 1
        fi
        sleep 30
      done
    else
      log "rebase failed — aborting and escalating"
      (cd "$work_dir" && git rebase --abort 2>/dev/null) || true
      notify "PR #${pr} has merge conflicts that need manual resolution."
      return 1
    fi
  fi

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API}/pulls/${pr}/merge" \
    -d '{"Do":"merge","delete_branch_after_merge":true}')

  if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
    log "PR #${pr} merged!"
    curl -sf -X DELETE \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/branches/${BRANCH}" >/dev/null 2>&1 || true
    curl -sf -X PATCH \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/issues/${ISSUE}" \
      -d '{"state":"closed"}' >/dev/null 2>&1 || true
    cleanup_labels
    notify "✅ PR #${pr} merged! Issue #${ISSUE} done."
    kill_tmux_session
    cleanup_worktree
    rm -f "$PHASE_FILE" "$IMPL_SUMMARY_FILE"
    exit 0
  else
    log "merge failed (HTTP ${http_code}) — attempting rebase and retry"
    local work_dir="${WORKTREE:-$REPO_ROOT}"
    if (cd "$work_dir" && git fetch origin "${PRIMARY_BRANCH}" && git rebase "origin/${PRIMARY_BRANCH}" 2>&1); then
      log "rebase succeeded — force pushing"
      (cd "$work_dir" && git push origin "${BRANCH}" --force-with-lease 2>&1) || true
      sha=$(cd "$work_dir" && git rev-parse HEAD)
      log "waiting for CI on rebased commit ${sha:0:7}"
      local r2_ci
      for _r2 in $(seq 1 20); do
        r2_ci=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
          "${API}/commits/${sha}/status" | jq -r '.state // "unknown"')
        [ "$r2_ci" = "success" ] && break
        if [ "$r2_ci" = "failure" ] || [ "$r2_ci" = "error" ]; then
          log "CI failed after merge-retry rebase"
          notify "PR #${pr} CI failed after rebase. Needs manual fix."
          return 1
        fi
        sleep 30
      done
      # Re-approve (force push dismisses stale approvals)
      curl -sf -X POST \
        -H "Authorization: token ${REVIEW_BOT_TOKEN:-${CODEBERG_TOKEN}}" \
        -H "Content-Type: application/json" \
        "${API}/pulls/${pr}/reviews" \
        -d '{"event":"APPROVED","body":"Auto-approved after rebase."}' >/dev/null 2>&1 || true
      # Retry merge
      http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/pulls/${pr}/merge" \
        -d '{"Do":"merge","delete_branch_after_merge":true}')
      if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
        log "PR #${pr} merged after rebase!"
        notify "✅ PR #${pr} merged! Issue #${ISSUE} done."
        curl -sf -X PATCH -H "Authorization: token ${CODEBERG_TOKEN}" \
          -H "Content-Type: application/json" \
          "${API}/issues/${ISSUE}" -d '{"state":"closed"}' >/dev/null 2>&1 || true
        cleanup_labels
        kill_tmux_session
        cleanup_worktree
        rm -f "$PHASE_FILE" "$IMPL_SUMMARY_FILE"
        exit 0
      fi
    else
      (cd "$work_dir" && git rebase --abort 2>/dev/null) || true
    fi
    log "merge still failing after rebase (HTTP ${http_code})"
    notify "PR #${pr} merge failed after rebase (HTTP ${http_code}). Needs human attention."
    return 1
  fi
}

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
ISSUE_JSON=$(curl -s -H "Authorization: token ${CODEBERG_TOKEN}" "${API}/issues/${ISSUE}") || true
if [ -z "$ISSUE_JSON" ] || ! echo "$ISSUE_JSON" | jq -e '.id' >/dev/null 2>&1; then
  log "ERROR: failed to fetch issue #${ISSUE} (API down or invalid response)"
  exit 1
fi
ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body // ""')
ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state')

if [ "$ISSUE_STATE" != "open" ]; then
  log "SKIP: issue #${ISSUE} is ${ISSUE_STATE}"
  echo '{"status":"already_done","reason":"issue is closed"}' > "$PREFLIGHT_RESULT"
  exit 0
fi

log "Issue: ${ISSUE_TITLE}"

# =============================================================================
# PREFLIGHT: Check dependencies before doing any work
# =============================================================================
status "preflight check"

# Extract dependency references from issue body
# Only from ## Dependencies / ## Depends on / ## Blocked by sections
# and inline "depends on #NNN" / "blocked by #NNN" phrases.
# NEVER extract from ## Related or other sections.
DEP_NUMBERS=""

# 1. Inline phrases anywhere in body (explicit dep language only)
INLINE_DEPS=$(echo "$ISSUE_BODY" | \
  grep -ioP '(?:depends on|blocked by)\s+#\K[0-9]+' | \
  sort -un || true)
[ -n "$INLINE_DEPS" ] && DEP_NUMBERS="$INLINE_DEPS"

# 2. ## Dependencies / ## Depends on / ## Blocked by section (bullet items)
DEP_SECTION=$(echo "$ISSUE_BODY" | sed -n '/^##\?\s*\(Dependencies\|Depends on\|Blocked by\)/I,/^##/p' | sed '1d;$d')
if [ -n "$DEP_SECTION" ]; then
  SECTION_DEPS=$(echo "$DEP_SECTION" | grep -oP '#\K[0-9]+' | sort -un || true)
  DEP_NUMBERS=$(printf '%s\n%s' "$DEP_NUMBERS" "$SECTION_DEPS" | sort -un | grep -v '^$' || true)
fi

BLOCKED_BY=()
if [ -n "$DEP_NUMBERS" ]; then
  while IFS= read -r dep_num; do
    [ -z "$dep_num" ] && continue
    # Check if dependency issue is closed (= satisfied)
    DEP_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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
    BLOCKER_BODY=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/issues/${blocker}" | jq -r '.body // ""')
    BLOCKER_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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
        BD_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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
  LAST_COMMENT_IS_BLOCK=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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
      -H "Authorization: token ${CODEBERG_TOKEN}" \
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
  -H "Authorization: token ${CODEBERG_TOKEN}" \
  -H "Content-Type: application/json" \
  "${API}/issues/${ISSUE}/labels" \
  -d '{"labels":["in-progress"]}' >/dev/null 2>&1 || true

curl -sf -X DELETE \
  -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API}/issues/${ISSUE}/labels/backlog" >/dev/null 2>&1 || true

curl -sf -X DELETE \
  -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API}/issues/${ISSUE}/labels/backlog" >/dev/null 2>&1 || true

CLAIMED=true

# =============================================================================
# CHECK FOR EXISTING PR (recovery mode)
# =============================================================================
EXISTING_PR=""
EXISTING_BRANCH=""
RECOVERY_MODE=false

BODY_PR=$(echo "$ISSUE_BODY" | grep -oP 'Existing PR:\s*#\K[0-9]+' | head -1) || true
if [ -n "$BODY_PR" ]; then
  PR_CHECK=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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
  FOUND_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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
  FOUND_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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
  CLOSED_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls?state=closed&limit=30" | \
    jq -r --arg issue "#${ISSUE}" \
    '.[] | select(.merged != true) | select((.title | contains($issue)) or (.body // "" | test("ixes " + $issue + "\\b"; "i"))) | "\(.number) \(.head.ref)"' | head -1) || true
  if [ -n "$CLOSED_PR" ]; then
    CLOSED_PR_NUM=$(echo "$CLOSED_PR" | awk '{print $1}')
    log "found closed (unmerged) PR #${CLOSED_PR_NUM} as prior art"
    PRIOR_ART_DIFF=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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
# BUILD PROMPT
# =============================================================================
OPEN_ISSUES_SUMMARY=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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
\`\`\`bash
echo \"PHASE:done\" > \"${PHASE_FILE}\"
\`\`\`
The orchestrator handles the merge. You are done.

**If refusing (too large, unmet dep, already done):**
\`\`\`bash
printf '%s' '{\"status\":\"too_large\",\"reason\":\"...\"}' > \"\${SUMMARY_FILE}\"
printf 'PHASE:failed\nReason: refused\n' > \"${PHASE_FILE}\"
\`\`\`

**On unrecoverable failure:**
\`\`\`bash
printf 'PHASE:failed\nReason: %s\n' \"describe what failed\" > \"${PHASE_FILE}\"
\`\`\`"

if [ "$RECOVERY_MODE" = true ]; then
  # Build recovery context
  GIT_DIFF_STAT=$(git -C "$WORKTREE" diff "origin/${PRIMARY_BRANCH}..HEAD" --stat 2>/dev/null | head -20 || echo "(no diff)")
  LAST_PHASE=$(read_phase)
  CI_RESULT=$(cat "/tmp/ci-result-${PROJECT_NAME}-${ISSUE}.txt" 2>/dev/null || echo "")
  REVIEW_COMMENTS=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/issues/${PR_NUMBER}/comments?limit=10" | \
    jq -r '.[-3:] | .[] | "[\(.user.login)] \(.body[:500])"' 2>/dev/null || echo "(none)")

  INITIAL_PROMPT="You are working in a git worktree at ${WORKTREE} on branch ${BRANCH}.
This is issue #${ISSUE} for the ${CODEBERG_REPO} project.

## Issue: ${ISSUE_TITLE}

${ISSUE_BODY}

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

${PHASE_PROTOCOL_INSTRUCTIONS}"
else
  # Normal mode: initial implementation prompt
  INITIAL_PROMPT="You are working in a git worktree at ${WORKTREE} on branch ${BRANCH}.
You have been assigned issue #${ISSUE} for the ${CODEBERG_REPO} project.

## Issue: ${ISSUE_TITLE}

${ISSUE_BODY}

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

${PHASE_PROTOCOL_INSTRUCTIONS}"
fi

# =============================================================================
# CREATE TMUX SESSION
# =============================================================================
status "creating tmux session: ${SESSION_NAME}"

# Reuse existing session if still alive (orchestrator may have been restarted)
if ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
  # Kill any stale entry
  tmux kill-session -t "${SESSION_NAME}" 2>/dev/null || true

  # Create new detached session running interactive claude in the worktree
  tmux new-session -d -s "${SESSION_NAME}" -c "${WORKTREE}" \
    "claude --dangerously-skip-permissions"

  # Wait for Claude to initialize
  sleep 3

  if ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
    log "ERROR: failed to create tmux session ${SESSION_NAME}"
    cleanup_labels
    cleanup_worktree
    exit 1
  fi
  log "tmux session created: ${SESSION_NAME}"
else
  log "reusing existing tmux session: ${SESSION_NAME}"
fi

# Send initial prompt via paste buffer (handles long text and special chars)
PROMPT_TMPFILE=$(mktemp /tmp/dev-prompt-XXXXXX)
printf '%s' "$INITIAL_PROMPT" > "$PROMPT_TMPFILE"
tmux load-buffer -b "prompt-${ISSUE}" "$PROMPT_TMPFILE"
tmux paste-buffer -t "${SESSION_NAME}" -b "prompt-${ISSUE}"
sleep 1
tmux send-keys -t "${SESSION_NAME}" "" Enter
tmux delete-buffer -b "prompt-${ISSUE}" 2>/dev/null || true
rm -f "$PROMPT_TMPFILE"

log "initial prompt sent to tmux session"

# Signal to dev-poll.sh that we're running (session is up)
echo '{"status":"ready"}' > "$PREFLIGHT_RESULT"
notify "tmux session ${SESSION_NAME} started for issue #${ISSUE}: ${ISSUE_TITLE}"

# =============================================================================
# PHASE MONITORING LOOP
# =============================================================================
status "monitoring phase: ${PHASE_FILE}"

LAST_PHASE_MTIME=0
IDLE_ELAPSED=0

while true; do
  sleep "$PHASE_POLL_INTERVAL"
  IDLE_ELAPSED=$(( IDLE_ELAPSED + PHASE_POLL_INTERVAL ))

  # --- Session health check ---
  if ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
    CURRENT_PHASE=$(read_phase)
    case "$CURRENT_PHASE" in
      PHASE:done|PHASE:failed)
        # Expected terminal phases — fall through to phase handler below
        ;;
      *)
        log "WARNING: tmux session died unexpectedly (phase: ${CURRENT_PHASE:-none})"
        notify "session crashed (phase: ${CURRENT_PHASE:-none}), attempting recovery"

        # Attempt crash recovery: restart session with recovery context
        CRASH_DIFF=$(git -C "${WORKTREE}" diff "origin/${PRIMARY_BRANCH}..HEAD" --stat 2>/dev/null | head -20 || echo "(no diff)")
        RECOVERY_MSG="## Session Recovery

Your Claude Code session for issue #${ISSUE} was interrupted unexpectedly.
The git worktree at ${WORKTREE} is intact — your changes survived.

Last known phase: ${CURRENT_PHASE:-unknown}

Work so far:
${CRASH_DIFF}

Run: git log --oneline -5 && git status
Then resume from the last phase following the original phase protocol.
Phase file: ${PHASE_FILE}"

        if tmux new-session -d -s "${SESSION_NAME}" -c "${WORKTREE}" \
          "claude --dangerously-skip-permissions" 2>/dev/null; then
          sleep 3
          inject_into_session "$RECOVERY_MSG"
          log "recovery session started"
          IDLE_ELAPSED=0
        else
          log "ERROR: could not restart session after crash"
          notify "session crashed and could not recover — needs human attention"
          cleanup_labels
          break
        fi
        continue
        ;;
    esac
  fi

  # --- Check phase file for changes ---
  PHASE_MTIME=$(stat -c %Y "$PHASE_FILE" 2>/dev/null || echo 0)
  CURRENT_PHASE=$(read_phase)

  if [ -z "$CURRENT_PHASE" ] || [ "$PHASE_MTIME" -le "$LAST_PHASE_MTIME" ]; then
    # No phase change — check idle timeout
    if [ "$IDLE_ELAPSED" -ge "$IDLE_TIMEOUT" ]; then
      log "TIMEOUT: no phase update for ${IDLE_TIMEOUT}s — killing session"
      notify "session idle for 2h — killed"
      kill_tmux_session
      cleanup_labels
      if [ -n "${PR_NUMBER:-}" ]; then
        log "keeping worktree (PR #${PR_NUMBER} still open)"
      else
        cleanup_worktree
      fi
      break
    fi
    continue
  fi

  # Phase changed — handle it
  LAST_PHASE_MTIME="$PHASE_MTIME"
  IDLE_ELAPSED=0
  log "phase: ${CURRENT_PHASE}"
  status "${CURRENT_PHASE}"

  # ── PHASE: awaiting_ci ──────────────────────────────────────────────────────
  if [ "$CURRENT_PHASE" = "PHASE:awaiting_ci" ]; then

    # Create PR if not yet created
    if [ -z "${PR_NUMBER:-}" ]; then
      status "creating PR for issue #${ISSUE}"
      IMPL_SUMMARY=""
      if [ -f "$IMPL_SUMMARY_FILE" ]; then
        # Don't treat refusal JSON as a PR summary
        if ! jq -e '.status' < "$IMPL_SUMMARY_FILE" >/dev/null 2>&1; then
          IMPL_SUMMARY=$(head -c 4000 "$IMPL_SUMMARY_FILE")
        fi
      fi

      printf 'Fixes #%s\n\n## Changes\n%s' "$ISSUE" "$IMPL_SUMMARY" > "/tmp/pr-body-${ISSUE}.txt"
      jq -n \
        --arg title "fix: ${ISSUE_TITLE} (#${ISSUE})" \
        --rawfile body "/tmp/pr-body-${ISSUE}.txt" \
        --arg head "$BRANCH" \
        --arg base "${PRIMARY_BRANCH}" \
        '{title: $title, body: $body, head: $head, base: $base}' > "/tmp/pr-request-${ISSUE}.json"

      PR_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/pulls" \
        --data-binary @"/tmp/pr-request-${ISSUE}.json")

      PR_HTTP_CODE=$(echo "$PR_RESPONSE" | tail -1)
      PR_RESPONSE_BODY=$(echo "$PR_RESPONSE" | sed '$d')
      rm -f "/tmp/pr-body-${ISSUE}.txt" "/tmp/pr-request-${ISSUE}.json"

      if [ "$PR_HTTP_CODE" = "201" ] || [ "$PR_HTTP_CODE" = "200" ]; then
        PR_NUMBER=$(echo "$PR_RESPONSE_BODY" | jq -r '.number')
        log "created PR #${PR_NUMBER}"
        notify "PR #${PR_NUMBER} created for issue #${ISSUE}: ${ISSUE_TITLE}"
      elif [ "$PR_HTTP_CODE" = "409" ]; then
        # PR already exists (race condition) — find it
        FOUND_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
          "${API}/pulls?state=open&limit=20" | \
          jq -r --arg branch "$BRANCH" \
          '.[] | select(.head.ref == $branch) | .number' | head -1) || true
        if [ -n "$FOUND_PR" ]; then
          PR_NUMBER="$FOUND_PR"
          log "PR already exists: #${PR_NUMBER}"
        else
          log "ERROR: PR creation got 409 but no existing PR found"
          inject_into_session "ERROR: Could not create PR (HTTP 409, no existing PR found). Check the Codeberg API. Retry by writing PHASE:awaiting_ci again after verifying the branch was pushed."
          continue
        fi
      else
        log "ERROR: PR creation failed (HTTP ${PR_HTTP_CODE})"
        notify "failed to create PR (HTTP ${PR_HTTP_CODE})"
        inject_into_session "ERROR: Could not create PR (HTTP ${PR_HTTP_CODE}). Check branch was pushed: git push origin ${BRANCH}. Then write PHASE:awaiting_ci again."
        continue
      fi
    fi

    # No CI configured? Treat as success immediately
    if [ "${WOODPECKER_REPO_ID:-2}" = "0" ]; then
      log "no CI configured — treating as passed"
      inject_into_session "CI passed on PR #${PR_NUMBER} (no CI configured for this project).
Write PHASE:awaiting_review to the phase file, then stop and wait for review feedback."
      continue
    fi

    # Poll CI until done or timeout
    status "waiting for CI on PR #${PR_NUMBER}"
    CI_CURRENT_SHA=$(git -C "${WORKTREE}" rev-parse HEAD 2>/dev/null || \
      curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${API}/pulls/${PR_NUMBER}" | jq -r '.head.sha')

    CI_DONE=false
    CI_STATE="unknown"
    CI_POLL_ELAPSED=0
    while [ "$CI_POLL_ELAPSED" -lt "$CI_POLL_TIMEOUT" ]; do
      sleep 30
      CI_POLL_ELAPSED=$(( CI_POLL_ELAPSED + 30 ))

      # Check session still alive during CI wait
      if ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
        log "session died during CI wait"
        break
      fi

      CI_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${API}/commits/${CI_CURRENT_SHA}/status" | jq -r '.state // "unknown"')
      if [ "$CI_STATE" = "success" ] || [ "$CI_STATE" = "failure" ] || [ "$CI_STATE" = "error" ]; then
        CI_DONE=true
        [ "$CI_STATE" = "success" ] && CI_FIX_COUNT=0
        break
      fi
    done

    if ! $CI_DONE; then
      log "TIMEOUT: CI didn't complete in ${CI_POLL_TIMEOUT}s"
      notify "CI timeout on PR #${PR_NUMBER}"
      inject_into_session "CI TIMEOUT: CI did not complete within 30 minutes for PR #${PR_NUMBER} (SHA: ${CI_CURRENT_SHA:0:7}). This may be an infrastructure issue. Write PHASE:needs_human if you cannot proceed."
      continue
    fi

    log "CI: ${CI_STATE}"

    if [ "$CI_STATE" = "success" ]; then
      inject_into_session "CI passed on PR #${PR_NUMBER}.
Write PHASE:awaiting_review to the phase file, then stop and wait for review feedback:
  echo \"PHASE:awaiting_review\" > \"${PHASE_FILE}\""
    else
      # Fetch CI error details
      PIPELINE_NUM=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${API}/commits/${CI_CURRENT_SHA}/status" | \
        jq -r '.statuses[0].target_url // ""' | grep -oP 'pipeline/\K[0-9]+' | head -1 || true)

      FAILED_STEP=""
      FAILED_EXIT=""
      IS_INFRA=false
      if [ -n "$PIPELINE_NUM" ]; then
        FAILED_INFO=$(curl -sf \
          -H "Authorization: Bearer ${WOODPECKER_TOKEN}" \
          "${WOODPECKER_SERVER}/api/repos/${WOODPECKER_REPO_ID}/pipelines/${PIPELINE_NUM}" | \
          jq -r '.workflows[]?.children[]? | select(.state=="failure") | "\(.name)|\(.exit_code)"' | head -1 || true)
        FAILED_STEP=$(echo "$FAILED_INFO" | cut -d'|' -f1)
        FAILED_EXIT=$(echo "$FAILED_INFO" | cut -d'|' -f2)
      fi

      log "CI failed: step=${FAILED_STEP:-unknown} exit=${FAILED_EXIT:-?}"

      case "${FAILED_STEP}" in git*) IS_INFRA=true ;; esac
      case "${FAILED_EXIT}" in 128|137) IS_INFRA=true ;; esac

      if [ "$IS_INFRA" = true ] && [ "${CI_RETRY_COUNT:-0}" -lt 1 ]; then
        CI_RETRY_COUNT=$(( CI_RETRY_COUNT + 1 ))
        log "infra failure — retrigger CI (retry ${CI_RETRY_COUNT})"
        (cd "$WORKTREE" && git commit --allow-empty \
          -m "ci: retrigger after infra failure (#${ISSUE})" --no-verify 2>&1 | tail -1)
        (cd "$WORKTREE" && git push origin "$BRANCH" --force 2>&1 | tail -3)
        # Touch phase file so we recheck CI on the new SHA
        touch "$PHASE_FILE"
        LAST_PHASE_MTIME=$(stat -c %Y "$PHASE_FILE" 2>/dev/null || echo 0)
        CI_CURRENT_SHA=$(git -C "${WORKTREE}" rev-parse HEAD 2>/dev/null || true)
        continue
      fi

      CI_FIX_COUNT=$(( CI_FIX_COUNT + 1 ))
      if [ "$CI_FIX_COUNT" -gt "$MAX_CI_FIXES" ]; then
        log "CI failure not recoverable after ${CI_FIX_COUNT} fix attempts — escalating"
        echo "{\"issue\":${ISSUE},\"pr\":${PR_NUMBER},\"reason\":\"ci_exhausted\",\"step\":\"${FAILED_STEP:-unknown}\",\"attempts\":${CI_FIX_COUNT},\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
          >> "${FACTORY_ROOT}/supervisor/escalations.jsonl"
        notify "CI exhausted after ${CI_FIX_COUNT} attempts — escalated to supervisor"
        printf 'PHASE:failed\nReason: ci_exhausted after %d attempts\n' "$CI_FIX_COUNT" > "$PHASE_FILE"
        LAST_PHASE_MTIME=$(stat -c %Y "$PHASE_FILE" 2>/dev/null || echo 0)
        continue
      fi

      CI_ERROR_LOG=""
      if [ -n "$PIPELINE_NUM" ]; then
        CI_ERROR_LOG=$(bash "${FACTORY_ROOT}/lib/ci-debug.sh" failures "$PIPELINE_NUM" 2>/dev/null | tail -80 | head -c 8000 || echo "")
      fi

      # Save CI result for crash recovery
      printf 'CI failed (attempt %d/%d)\nStep: %s\nExit: %s\n\n%s' \
        "$CI_FIX_COUNT" "$MAX_CI_FIXES" "${FAILED_STEP:-unknown}" "${FAILED_EXIT:-?}" "$CI_ERROR_LOG" \
        > "/tmp/ci-result-${PROJECT_NAME}-${ISSUE}.txt" 2>/dev/null || true

      inject_into_session "CI failed on PR #${PR_NUMBER} (attempt ${CI_FIX_COUNT}/${MAX_CI_FIXES}).

Failed step: ${FAILED_STEP:-unknown} (exit code ${FAILED_EXIT:-?}, pipeline #${PIPELINE_NUM:-?})

CI debug tool:
  bash ${FACTORY_ROOT}/lib/ci-debug.sh failures ${PIPELINE_NUM:-0}
  bash ${FACTORY_ROOT}/lib/ci-debug.sh logs ${PIPELINE_NUM:-0} <step-name>

Error snippet:
${CI_ERROR_LOG:-No logs available. Use ci-debug.sh to query the pipeline.}

Instructions:
1. Run ci-debug.sh failures to get the full error output.
2. Read the failing test file(s) — understand what the tests EXPECT.
3. Fix the root cause — do NOT weaken tests.
4. Commit your fix and push: git push origin ${BRANCH}
5. Write: echo \"PHASE:awaiting_ci\" > \"${PHASE_FILE}\"
6. Stop and wait."
    fi

  # ── PHASE: awaiting_review ──────────────────────────────────────────────────
  elif [ "$CURRENT_PHASE" = "PHASE:awaiting_review" ]; then
    status "waiting for review on PR #${PR_NUMBER:-?}"
    CI_FIX_COUNT=0  # Reset CI fix budget for this review cycle

    if [ -z "${PR_NUMBER:-}" ]; then
      log "WARNING: awaiting_review but PR_NUMBER unknown — searching for PR"
      FOUND_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${API}/pulls?state=open&limit=20" | \
        jq -r --arg branch "$BRANCH" \
        '.[] | select(.head.ref == $branch) | .number' | head -1) || true
      if [ -n "$FOUND_PR" ]; then
        PR_NUMBER="$FOUND_PR"
        log "found PR #${PR_NUMBER}"
      else
        inject_into_session "ERROR: Cannot find open PR for branch ${BRANCH}. Did you push? Verify with git status and git push origin ${BRANCH}, then write PHASE:awaiting_ci."
        continue
      fi
    fi

    REVIEW_POLL_ELAPSED=0
    REVIEW_FOUND=false
    while [ "$REVIEW_POLL_ELAPSED" -lt "$REVIEW_POLL_TIMEOUT" ]; do
      sleep 300  # 5 min between review checks
      REVIEW_POLL_ELAPSED=$(( REVIEW_POLL_ELAPSED + 300 ))

      # Check session still alive
      if ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
        log "session died during review wait"
        REVIEW_FOUND=false
        break
      fi

      # Check if phase was updated while we wait (e.g., Claude reacted to something)
      NEW_MTIME=$(stat -c %Y "$PHASE_FILE" 2>/dev/null || echo 0)
      if [ "$NEW_MTIME" -gt "$LAST_PHASE_MTIME" ]; then
        log "phase file updated during review wait — re-entering main loop"
        LAST_PHASE_MTIME="$NEW_MTIME"
        REVIEW_FOUND=true  # Prevent timeout injection
        break
      fi

      REVIEW_SHA=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${API}/pulls/${PR_NUMBER}" | jq -r '.head.sha') || true
      REVIEW_COMMENT=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${API}/issues/${PR_NUMBER}/comments?limit=50" | \
        jq -r --arg sha "$REVIEW_SHA" \
        '[.[] | select(.body | contains("<!-- reviewed: " + $sha))] | last // empty') || true

      if [ -n "$REVIEW_COMMENT" ] && [ "$REVIEW_COMMENT" != "null" ]; then
        REVIEW_TEXT=$(echo "$REVIEW_COMMENT" | jq -r '.body')

        # Skip error reviews — they have no verdict
        if echo "$REVIEW_TEXT" | grep -q "review-error\|Review — Error"; then
          log "review was an error, waiting for re-review"
          continue
        fi

        VERDICT=$(echo "$REVIEW_TEXT" | grep -oP '\*\*(APPROVE|REQUEST_CHANGES|DISCUSS)\*\*' | head -1 | tr -d '*' || true)
        log "review verdict: ${VERDICT:-unknown}"

        # Also check formal Codeberg reviews
        if [ -z "$VERDICT" ]; then
          VERDICT=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
            "${API}/pulls/${PR_NUMBER}/reviews" | \
            jq -r '[.[] | select(.stale == false)] | last | .state // empty' || true)
          if [ "$VERDICT" = "APPROVED" ]; then
            VERDICT="APPROVE"
          elif [ "$VERDICT" != "REQUEST_CHANGES" ]; then
            VERDICT=""
          fi
          [ -n "$VERDICT" ] && log "verdict from formal review: $VERDICT"
        fi

        if [ "$VERDICT" = "APPROVE" ]; then
          REVIEW_FOUND=true
          inject_into_session "Approved! PR #${PR_NUMBER} has been approved by the reviewer.
Write PHASE:done to the phase file — the orchestrator will handle the merge:
  echo \"PHASE:done\" > \"${PHASE_FILE}\""
          break

        elif [ "$VERDICT" = "REQUEST_CHANGES" ] || [ "$VERDICT" = "DISCUSS" ]; then
          REVIEW_ROUND=$(( REVIEW_ROUND + 1 ))
          if [ "$REVIEW_ROUND" -ge "$MAX_REVIEW_ROUNDS" ]; then
            log "hit max review rounds (${MAX_REVIEW_ROUNDS})"
            notify "PR #${PR_NUMBER}: hit ${MAX_REVIEW_ROUNDS} review rounds, needs human attention"
          fi
          REVIEW_FOUND=true
          inject_into_session "Review feedback (round ${REVIEW_ROUND}) on PR #${PR_NUMBER}:

${REVIEW_TEXT}

Instructions:
1. Address each piece of feedback carefully.
2. Run lint and tests when done.
3. Commit your changes and push: git push origin ${BRANCH}
4. Write: echo \"PHASE:awaiting_ci\" > \"${PHASE_FILE}\"
5. Stop and wait for the next CI result."
          log "review REQUEST_CHANGES received (round ${REVIEW_ROUND})"
          break

        else
          # No verdict found in comment or formal review — keep waiting
          log "review comment found but no verdict, continuing to wait"
          continue
        fi
      fi

      # Check if PR was merged or closed externally
      PR_JSON=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${API}/pulls/${PR_NUMBER}") || true
      PR_STATE=$(echo "$PR_JSON" | jq -r '.state // "unknown"')
      PR_MERGED=$(echo "$PR_JSON" | jq -r '.merged // false')
      if [ "$PR_STATE" != "open" ]; then
        if [ "$PR_MERGED" = "true" ]; then
          log "PR #${PR_NUMBER} was merged externally"
          notify "✅ PR #${PR_NUMBER} merged externally! Issue #${ISSUE} done."
          curl -sf -X PATCH -H "Authorization: token ${CODEBERG_TOKEN}" \
            -H "Content-Type: application/json" \
            "${API}/issues/${ISSUE}" -d '{"state":"closed"}' >/dev/null 2>&1 || true
          cleanup_labels
          kill_tmux_session
          cleanup_worktree
          rm -f "$PHASE_FILE" "$IMPL_SUMMARY_FILE"
          exit 0
        else
          log "PR #${PR_NUMBER} was closed WITHOUT merge — NOT closing issue"
          notify "⚠️ PR #${PR_NUMBER} closed without merge. Issue #${ISSUE} remains open."
          cleanup_labels
          kill_tmux_session
          cleanup_worktree
          exit 0
        fi
      fi

      log "waiting for review on PR #${PR_NUMBER} (${REVIEW_POLL_ELAPSED}s elapsed)"
    done

    if ! $REVIEW_FOUND && [ "$REVIEW_POLL_ELAPSED" -ge "$REVIEW_POLL_TIMEOUT" ]; then
      log "TIMEOUT: no review after 3h"
      notify "no review received for PR #${PR_NUMBER} after 3h"
      inject_into_session "TIMEOUT: No review received after 3 hours for PR #${PR_NUMBER}. Write PHASE:needs_human to escalate to a human reviewer."
    fi

  # ── PHASE: needs_human ──────────────────────────────────────────────────────
  elif [ "$CURRENT_PHASE" = "PHASE:needs_human" ]; then
    status "needs human input on issue #${ISSUE}"
    HUMAN_REASON=$(sed -n '2p' "$PHASE_FILE" 2>/dev/null | sed 's/^Reason: //' || echo "")
    notify "⚠️ Issue #${ISSUE} (PR #${PR_NUMBER:-none}) needs human input.${HUMAN_REASON:+ Reason: ${HUMAN_REASON}}"
    log "phase: needs_human — notified via Matrix, waiting for injection from #81/#82/#83"
    # Don't inject anything — other scripts (#81, #82, #83) will inject human replies

  # ── PHASE: done ─────────────────────────────────────────────────────────────
  elif [ "$CURRENT_PHASE" = "PHASE:done" ]; then
    status "phase done — merging PR #${PR_NUMBER:-?}"

    if [ -z "${PR_NUMBER:-}" ]; then
      log "ERROR: PHASE:done but no PR_NUMBER — cannot merge"
      notify "PHASE:done but no PR known — needs human attention"
      kill_tmux_session
      cleanup_labels
      break
    fi

    MERGE_SHA=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${PR_NUMBER}" | jq -r '.head.sha') || true

    # do_merge exits 0 on success; returns 1 on failure
    do_merge "$MERGE_SHA" || true

    # If we reach here, merge failed (do_merge returned 1)
    log "merge failed — injecting error into session"
    inject_into_session "Merge failed for PR #${PR_NUMBER}. The orchestrator could not merge automatically. This may be due to merge conflicts or CI. Investigate the PR state and write PHASE:needs_human if human intervention is required."

  # ── PHASE: failed ───────────────────────────────────────────────────────────
  elif [ "$CURRENT_PHASE" = "PHASE:failed" ]; then
    FAILURE_REASON=$(sed -n '2p' "$PHASE_FILE" 2>/dev/null | sed 's/^Reason: //' || echo "unspecified")
    log "phase: failed — reason: ${FAILURE_REASON}"

    # Check if this is a refusal (Claude wrote refusal JSON to IMPL_SUMMARY_FILE)
    REFUSAL_JSON=""
    if [ -f "$IMPL_SUMMARY_FILE" ] && jq -e '.status' < "$IMPL_SUMMARY_FILE" >/dev/null 2>&1; then
      REFUSAL_JSON=$(cat "$IMPL_SUMMARY_FILE")
    fi

    if [ -n "$REFUSAL_JSON" ] && [ "$FAILURE_REASON" = "refused" ]; then
      REFUSAL_STATUS=$(printf '%s' "$REFUSAL_JSON" | jq -r '.status')
      log "claude refused: ${REFUSAL_STATUS}"

      # Write preflight result for dev-poll.sh
      printf '%s' "$REFUSAL_JSON" > "$PREFLIGHT_RESULT"

      # Unclaim issue (restore backlog label, remove in-progress)
      cleanup_labels
      curl -sf -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/issues/${ISSUE}/labels" \
        -d '{"labels":["backlog"]}' >/dev/null 2>&1 || true

      case "$REFUSAL_STATUS" in
        unmet_dependency)
          BLOCKED_BY_MSG=$(printf '%s' "$REFUSAL_JSON" | jq -r '.blocked_by // "unknown"')
          SUGGESTION=$(printf '%s' "$REFUSAL_JSON" | jq -r '.suggestion // empty')
          COMMENT_BODY="### Blocked by unmet dependency

${BLOCKED_BY_MSG}"
          if [ -n "$SUGGESTION" ] && [ "$SUGGESTION" != "null" ]; then
            COMMENT_BODY="${COMMENT_BODY}

**Suggestion:** Work on #${SUGGESTION} first."
          fi
          post_refusal_comment "🚧" "Unmet dependency" "$COMMENT_BODY"
          notify "refused #${ISSUE}: unmet dependency — ${BLOCKED_BY_MSG}"
          ;;
        too_large)
          REASON=$(printf '%s' "$REFUSAL_JSON" | jq -r '.reason // "unspecified"')
          post_refusal_comment "📏" "Too large for single session" "### Why this can't be implemented as-is

${REASON}

### Next steps
A maintainer should split this issue or add more detail to the spec."
          curl -sf -X POST \
            -H "Authorization: token ${CODEBERG_TOKEN}" \
            -H "Content-Type: application/json" \
            "${API}/issues/${ISSUE}/labels" \
            -d '{"labels":["underspecified"]}' >/dev/null 2>&1 || true
          curl -sf -X DELETE \
            -H "Authorization: token ${CODEBERG_TOKEN}" \
            "${API}/issues/${ISSUE}/labels/backlog" >/dev/null 2>&1 || true
          notify "refused #${ISSUE}: too large — ${REASON}"
          ;;
        already_done)
          REASON=$(printf '%s' "$REFUSAL_JSON" | jq -r '.reason // "unspecified"')
          post_refusal_comment "✅" "Already implemented" "### Existing implementation

${REASON}

Closing as already implemented."
          curl -sf -X PATCH \
            -H "Authorization: token ${CODEBERG_TOKEN}" \
            -H "Content-Type: application/json" \
            "${API}/issues/${ISSUE}" \
            -d '{"state":"closed"}' >/dev/null 2>&1 || true
          notify "refused #${ISSUE}: already done — ${REASON}"
          ;;
        *)
          post_refusal_comment "❓" "Unable to proceed" "The dev-agent could not process this issue.

Raw response:
\`\`\`json
$(printf '%s' "$REFUSAL_JSON" | head -c 2000)
\`\`\`"
          notify "refused #${ISSUE}: unknown reason"
          ;;
      esac

      CLAIMED=false  # Don't unclaim again in cleanup()
      kill_tmux_session
      cleanup_worktree
      rm -f "$PHASE_FILE" "$IMPL_SUMMARY_FILE"
      break

    else
      # Genuine unrecoverable failure — escalate to supervisor
      log "session failed: ${FAILURE_REASON}"
      notify "❌ Issue #${ISSUE} session failed: ${FAILURE_REASON}"
      echo "{\"issue\":${ISSUE},\"pr\":${PR_NUMBER:-0},\"reason\":\"${FAILURE_REASON}\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
        >> "${FACTORY_ROOT}/supervisor/escalations.jsonl"

      # Restore backlog label
      cleanup_labels
      curl -sf -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/issues/${ISSUE}/labels" \
        -d '{"labels":["backlog"]}' >/dev/null 2>&1 || true

      CLAIMED=false  # Don't unclaim again in cleanup()
      kill_tmux_session
      if [ -n "${PR_NUMBER:-}" ]; then
        log "keeping worktree (PR #${PR_NUMBER} still open)"
      else
        cleanup_worktree
      fi
      rm -f "$PHASE_FILE" "$IMPL_SUMMARY_FILE"
      break
    fi

  else
    log "WARNING: unknown phase value: ${CURRENT_PHASE}"
  fi
done

log "dev-agent finished for issue #${ISSUE}"
