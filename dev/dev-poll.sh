#!/usr/bin/env bash
# dev-poll.sh — Pull-based scheduler: find the next ready issue and start dev-agent
#
# SDK version: No tmux — checks PID lockfile for active agents.
# Uses pr_merge() and issue_block() from shared libraries.
#
# Pull system: issues labeled "backlog" are candidates. An issue is READY when
# ALL its dependency issues are closed (and their PRs merged).
# No "todo" label needed — readiness is derived from reality.
#
# Priority:
#   1. Orphaned "in-progress" issues (agent died or PR needs attention)
#   2. Ready "priority" + "backlog" issues (FIFO within tier)
#   3. Ready "backlog" issues without "priority" (FIFO within tier)
#
# Usage:
#   cron every 10min
#   dev-poll.sh [projects/harb.toml]   # optional project config

set -euo pipefail

# Load shared environment and libraries
export PROJECT_TOML="${1:-}"
source "$(dirname "$0")/../lib/env.sh"
source "$(dirname "$0")/../lib/ci-helpers.sh"
# shellcheck source=../lib/pr-lifecycle.sh
source "$(dirname "$0")/../lib/pr-lifecycle.sh"
# shellcheck source=../lib/issue-lifecycle.sh
source "$(dirname "$0")/../lib/issue-lifecycle.sh"
# shellcheck source=../lib/mirrors.sh
source "$(dirname "$0")/../lib/mirrors.sh"
# shellcheck source=../lib/guard.sh
source "$(dirname "$0")/../lib/guard.sh"
check_active dev

API="${FORGE_API}"
LOCKFILE="/tmp/dev-agent-${PROJECT_NAME:-default}.lock"
LOGFILE="${DISINTO_LOG_DIR}/dev/dev-agent-${PROJECT_NAME:-default}.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
  printf '[%s] poll: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

# =============================================================================
# CI FIX TRACKER: per-PR counter to avoid infinite respawn loops (max 3)
# =============================================================================
CI_FIX_TRACKER="${DISINTO_LOG_DIR}/dev/ci-fixes-${PROJECT_NAME:-default}.json"
CI_FIX_LOCK="${CI_FIX_TRACKER}.lock"

ci_fix_count() {
  local pr="$1"
  flock "$CI_FIX_LOCK" python3 -c "import json,sys;d=json.load(open('$CI_FIX_TRACKER')) if __import__('os').path.exists('$CI_FIX_TRACKER') else {};print(d.get(str($pr),0))" 2>/dev/null || echo 0
}
ci_fix_reset() {
  local pr="$1"
  flock "$CI_FIX_LOCK" python3 -c "
import json,os
f='$CI_FIX_TRACKER'
d=json.load(open(f)) if os.path.exists(f) else {}
d.pop(str($pr),None)
json.dump(d,open(f,'w'))
" 2>/dev/null || true
}
ci_fix_check_and_increment() {
  local pr="$1"
  local check_only="${2:-}"
  flock "$CI_FIX_LOCK" python3 -c "
import json,os
f='$CI_FIX_TRACKER'
check_only = '${check_only}' == 'check_only'
d=json.load(open(f)) if os.path.exists(f) else {}
count=d.get(str($pr),0)
if count>3:
    print('exhausted:'+str(count))
elif count==3:
    d[str($pr)]=4
    json.dump(d,open(f,'w'))
    print('exhausted_first_time:3')
elif check_only:
    print('ok:'+str(count))
else:
    count+=1
    d[str($pr)]=count
    json.dump(d,open(f,'w'))
    print('ok:'+str(count))
" 2>/dev/null || echo "exhausted:99"
}

# Check whether an issue already has the "blocked" label
is_blocked() {
  local issue="$1"
  forge_api GET "/issues/${issue}/labels" 2>/dev/null \
    | jq -e '.[] | select(.name == "blocked")' >/dev/null 2>&1
}

# =============================================================================
# STALENESS DETECTION FOR IN-PROGRESS ISSUES
# =============================================================================

# Check if a tmux session for a specific issue is alive
# Args: project_name issue_number
# Returns: 0 if session is alive, 1 if not
session_is_alive() {
  local project="$1" issue="$2"
  local session="dev-${project}-${issue}"
  tmux has-session -t "$session" 2>/dev/null
}

# Check if there's an open PR for a specific issue
# Args: project_name issue_number
# Returns: 0 if open PR exists, 1 if not
open_pr_exists() {
  local project="$1" issue="$2"
  local branch="fix/issue-${issue}"
  local pr_num

  pr_num=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/pulls?state=open&limit=20" | \
    jq -r --arg branch "$branch" \
    '.[] | select(.head.ref == $branch) | .number' | head -1) || true

  [ -n "$pr_num" ]
}

# Relabel a stale in-progress issue to blocked with diagnostic comment
# Args: issue_number reason
# Uses shared helpers from lib/issue-lifecycle.sh
relabel_stale_issue() {
  local issue="$1" reason="$2"

  log "relabeling stale in-progress issue #${issue} to blocked: ${reason}"

  # Remove in-progress label
  local ip_id
  ip_id=$(_ilc_in_progress_id)
  if [ -n "$ip_id" ]; then
    curl -sf -X DELETE -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/issues/${issue}/labels/${ip_id}" >/dev/null 2>&1 || true
  fi

  # Add blocked label
  local bk_id
  bk_id=$(_ilc_blocked_id)
  if [ -n "$bk_id" ]; then
    curl -sf -X POST -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/issues/${issue}/labels" \
      -d "{\"labels\":[${bk_id}]}" >/dev/null 2>&1 || true
  fi

  # Post diagnostic comment using shared helper
  local comment_body
  comment_body=$(
    printf '### Stale in-progress issue detected\n\n'
    printf '| Field | Value |\n|---|---|\n'
    printf '| Detection reason | `%s` |\n' "$reason"
    printf '| Timestamp | `%s` |\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '\n**Status:** This issue was labeled `in-progress` but no active tmux session exists.\n'
    printf '**Action required:** A maintainer should triage this issue.\n'
  )
  _ilc_post_comment "$issue" "$comment_body"

  _ilc_log "stale issue #${issue} relabeled to blocked: ${reason}"
}

# =============================================================================
# HELPER: handle CI-exhaustion check/block (DRY for 3 call sites)
# Sets CI_FIX_ATTEMPTS for caller use. Returns 0 if exhausted, 1 if not.
# Uses issue_block() from lib/issue-lifecycle.sh for blocking.
#
# Pass "check_only" as third arg for the backlog scan path: ok-counts are
# returned without incrementing (deferred to launch time so a WAITING_PRS
# exit cannot waste a fix attempt). The 3->4 sentinel bump is always atomic.
# =============================================================================
handle_ci_exhaustion() {
  local pr_num="$1" issue_num="$2"
  local check_only="${3:-}"
  local result

  # Fast path: already blocked — skip without touching counter.
  if is_blocked "$issue_num"; then
    CI_FIX_ATTEMPTS=$(ci_fix_count "$pr_num")
    log "PR #${pr_num} (issue #${issue_num}) already blocked (${CI_FIX_ATTEMPTS} attempts) — skipping"
    return 0
  fi

  result=$(ci_fix_check_and_increment "$pr_num" "$check_only")
  case "$result" in
    ok:*)
      CI_FIX_ATTEMPTS="${result#ok:}"
      return 1
      ;;
    exhausted_first_time:*)
      CI_FIX_ATTEMPTS="${result#exhausted_first_time:}"
      log "PR #${pr_num} (issue #${issue_num}) CI exhausted (${CI_FIX_ATTEMPTS} attempts) — marking blocked"
      issue_block "$issue_num" "ci_exhausted_poll (${CI_FIX_ATTEMPTS} attempts, PR #${pr_num})"
      ;;
    exhausted:*)
      CI_FIX_ATTEMPTS="${result#exhausted:}"
      log "PR #${pr_num} (issue #${issue_num}) CI exhausted (${CI_FIX_ATTEMPTS} attempts) — already blocked, skipping"
      ;;
    *)
      CI_FIX_ATTEMPTS=99
      log "PR #${pr_num} (issue #${issue_num}) CI exhausted (${CI_FIX_ATTEMPTS} attempts) — already blocked, skipping"
      ;;
  esac
  return 0
}

# =============================================================================
# HELPER: merge an approved PR directly via pr_merge() (no Claude needed)
#
# Merging an approved, CI-green PR is a single API call. Spawning dev-agent
# for this fails when the issue is already closed (forge auto-closes issues
# on PR creation when body contains "Fixes #N"), causing a respawn loop (#344).
# =============================================================================
try_direct_merge() {
  local pr_num="$1" issue_num="$2"

  log "PR #${pr_num} (issue #${issue_num}) approved + CI green → attempting direct merge"

  if pr_merge "$pr_num"; then
    log "PR #${pr_num} merged successfully"
    if [ "$issue_num" -gt 0 ]; then
      issue_close "$issue_num"
      # Remove in-progress label (don't re-add backlog — issue is closed)
      IP_ID=$(_ilc_in_progress_id)
      curl -sf -X DELETE \
        -H "Authorization: token ${FORGE_TOKEN}" \
        "${API}/issues/${issue_num}/labels/${IP_ID}" >/dev/null 2>&1 || true
      rm -f "/tmp/dev-session-${PROJECT_NAME}-${issue_num}.sid" \
            "/tmp/dev-impl-summary-${PROJECT_NAME}-${issue_num}.txt"
    fi
    # Pull merged primary branch and push to mirrors
    git -C "${PROJECT_REPO_ROOT:-}" fetch origin "${PRIMARY_BRANCH:-}" 2>/dev/null || true
    git -C "${PROJECT_REPO_ROOT:-}" checkout "${PRIMARY_BRANCH:-}" 2>/dev/null || true
    git -C "${PROJECT_REPO_ROOT:-}" pull --ff-only origin "${PRIMARY_BRANCH:-}" 2>/dev/null || true
    mirror_push
    ci_fix_reset "$pr_num"
    return 0
  fi

  log "PR #${pr_num} direct merge failed — falling back to dev-agent"
  return 1
}

# =============================================================================
# HELPER: extract issue number from PR branch/title/body
# =============================================================================
extract_issue_from_pr() {
  local branch="$1" title="$2" body="$3"
  local issue
  issue=$(echo "$branch" | grep -oP '(?<=fix/issue-)\d+' || true)
  if [ -z "$issue" ]; then
    issue=$(echo "$title" | grep -oP '#\K\d+' | tail -1 || true)
  fi
  if [ -z "$issue" ]; then
    issue=$(echo "$body" | grep -oiP '(?:closes|fixes|resolves)\s*#\K\d+' | head -1 || true)
  fi
  printf '%s' "$issue"
}

# =============================================================================
# DEPENDENCY HELPERS
# =============================================================================
dep_is_merged() {
  local dep_num="$1"
  local dep_state
  dep_state=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/issues/${dep_num}" | jq -r '.state // "open"')
  if [ "$dep_state" != "closed" ]; then
    return 1
  fi
  return 0
}

get_deps() {
  local issue_body="$1"
  echo "$issue_body" | bash "${FACTORY_ROOT}/lib/parse-deps.sh"
}

issue_is_ready() {
  local issue_num="$1"
  local issue_body="$2"
  local deps
  deps=$(get_deps "$issue_body")

  if [ -z "$deps" ]; then
    return 0
  fi

  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    if ! dep_is_merged "$dep"; then
      log "  #${issue_num} blocked: dep #${dep} not merged"
      return 1
    fi
  done <<< "$deps"

  return 0
}

# =============================================================================
# PRE-LOCK: merge approved + CI-green PRs (no Claude session needed)
#
# Merging is a single API call — it doesn't need the dev-agent lock.
# This ensures approved PRs get merged even while a dev-agent is running.
# (See #531: direct merges should not be blocked by agent lock)
# =============================================================================
log "pre-lock: scanning for mergeable PRs"
PL_PRS=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/pulls?state=open&limit=20")

PL_MERGED_ANY=false
for i in $(seq 0 $(($(echo "$PL_PRS" | jq 'length') - 1))); do
  PL_PR_NUM=$(echo "$PL_PRS" | jq -r ".[$i].number")
  PL_PR_SHA=$(echo "$PL_PRS" | jq -r ".[$i].head.sha")
  PL_PR_BRANCH=$(echo "$PL_PRS" | jq -r ".[$i].head.ref")
  PL_PR_TITLE=$(echo "$PL_PRS" | jq -r ".[$i].title")
  PL_PR_BODY=$(echo "$PL_PRS" | jq -r ".[$i].body // \"\"")

  PL_ISSUE=$(extract_issue_from_pr "$PL_PR_BRANCH" "$PL_PR_TITLE" "$PL_PR_BODY")
  if [ -z "$PL_ISSUE" ]; then
    # Allow chore PRs from gardener/planner/predictor to merge without issue number
    if [[ "$PL_PR_BRANCH" =~ ^chore/(gardener|planner|predictor)- ]]; then
      PL_ISSUE=0
    else
      continue
    fi
  fi

  PL_CI_STATE=$(ci_commit_status "$PL_PR_SHA") || true

  # Non-code PRs may have no CI — treat as passed
  if ! ci_passed "$PL_CI_STATE" && ! ci_required_for_pr "$PL_PR_NUM"; then
    PL_CI_STATE="success"
  fi

  if ! ci_passed "$PL_CI_STATE"; then
    continue
  fi

  # Check for approval (non-stale)
  PL_REVIEWS=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/pulls/${PL_PR_NUM}/reviews") || true
  PL_HAS_APPROVE=$(echo "$PL_REVIEWS" | \
    jq -r '[.[] | select(.state == "APPROVED") | select(.stale == false)] | length') || true

  if [ "${PL_HAS_APPROVE:-0}" -gt 0 ]; then
    if try_direct_merge "$PL_PR_NUM" "$PL_ISSUE"; then
      PL_MERGED_ANY=true
    fi
    # Direct merge failed — will fall through to post-lock dev-agent fallback
  fi
done

if [ "$PL_MERGED_ANY" = true ]; then
  log "pre-lock: merged PR(s) successfully — exiting"
  exit 0
fi
log "pre-lock: no PRs merged, checking agent lock"

# --- Check if dev-agent already running (PID lockfile) ---
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "agent running (PID ${LOCK_PID})"
    exit 0
  fi
  rm -f "$LOCKFILE"
fi

# --- Fetch origin refs before any stale branch checks ---
git fetch origin --prune 2>/dev/null || true

# --- Memory guard ---
memory_guard 2000

# =============================================================================
# PRIORITY 1: orphaned in-progress issues
# =============================================================================
log "checking for in-progress issues"

# Get current bot identity for assignee checks
BOT_USER=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API%%/repos*}/user" | jq -r '.login') || BOT_USER=""

ORPHANS_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/issues?state=open&labels=in-progress&limit=10&type=issues")

ORPHAN_COUNT=$(echo "$ORPHANS_JSON" | jq 'length')
if [ "$ORPHAN_COUNT" -gt 0 ]; then
  ISSUE_NUM=$(echo "$ORPHANS_JSON" | jq -r '.[0].number')

  # Staleness check: if no tmux session and no open PR, the issue is stale
  SESSION_ALIVE=false
  OPEN_PR=false
  if tmux has-session -t "dev-${PROJECT_NAME}-${ISSUE_NUM}" 2>/dev/null; then
    SESSION_ALIVE=true
  fi
  if curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/pulls?state=open&limit=20" | \
    jq -e --arg branch "fix/issue-${ISSUE_NUM}" \
    '.[] | select(.head.ref == $branch)' >/dev/null 2>&1; then
    OPEN_PR=true
  fi

  if [ "$SESSION_ALIVE" = false ] && [ "$OPEN_PR" = false ]; then
    log "issue #${ISSUE_NUM} is stale (no active tmux session, no open PR) — relabeling to blocked"
    relabel_stale_issue "$ISSUE_NUM" "no_active_session_no_open_pr"
    exit 0
  fi

  # Formula guard: formula-labeled issues should not be worked on by dev-agent.
  # Remove in-progress label and skip to prevent infinite respawn cycle (#115).
  ORPHAN_LABELS=$(echo "$ORPHANS_JSON" | jq -r '.[0].labels[].name' 2>/dev/null) || true
  SKIP_LABEL=$(echo "$ORPHAN_LABELS" | grep -oE '^(formula|prediction/dismissed|prediction/unreviewed)$' | head -1) || true
  if [ -n "$SKIP_LABEL" ]; then
    log "issue #${ISSUE_NUM} has '${SKIP_LABEL}' label — removing in-progress, skipping"
    IP_ID=$(_ilc_in_progress_id)
    curl -sf -X DELETE -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/issues/${ISSUE_NUM}/labels/${IP_ID}" >/dev/null 2>&1 || true
    exit 0
  fi

  # Check if there's already an open PR for this issue
  HAS_PR=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/pulls?state=open&limit=20" | \
    jq -r --arg branch "fix/issue-${ISSUE_NUM}" \
    '.[] | select(.head.ref == $branch) | .number' | head -1) || true

  if [ -n "$HAS_PR" ]; then
    # Check if branch is stale (behind primary branch)
    BRANCH="fix/issue-${ISSUE_NUM}"
    AHEAD=$(git rev-list --count "origin/${BRANCH}..origin/${PRIMARY_BRANCH}" 2>/dev/null || echo "0")
    if [ "$AHEAD" -gt 0 ]; then
      log "issue #${ISSUE_NUM} PR #${HAS_PR} is $AHEAD commits behind ${PRIMARY_BRANCH} — abandoning stale PR"
      # Close the PR via API
      curl -sf -X PATCH \
        -H "Authorization: token ${FORGE_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/pulls/${HAS_PR}" \
        -d '{"state":"closed"}' >/dev/null 2>&1 || true
      # Delete the branch via git push
      git -C "${PROJECT_REPO_ROOT:-}" push origin --delete "${BRANCH}" 2>/dev/null || true
      # Reset to fresh start on primary branch
      git -C "${PROJECT_REPO_ROOT:-}" checkout "${PRIMARY_BRANCH}" 2>/dev/null || true
      git -C "${PROJECT_REPO_ROOT:-}" pull --ff-only origin "${PRIMARY_BRANCH}" 2>/dev/null || true
      # Exit to restart poll cycle (issue will be picked up fresh)
      exit 0
    fi

    PR_SHA=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/pulls/${HAS_PR}" | jq -r '.head.sha') || true
    CI_STATE=$(ci_commit_status "$PR_SHA") || true

    # Non-code PRs (docs, formulas, evidence) may have no CI — treat as passed
    if ! ci_passed "$CI_STATE" && ! ci_required_for_pr "$HAS_PR"; then
      CI_STATE="success"
      log "PR #${HAS_PR} has no code files — treating CI as passed"
    fi

    # Check formal reviews (single fetch to avoid race window)
    REVIEWS_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/pulls/${HAS_PR}/reviews") || true
    HAS_APPROVE=$(echo "$REVIEWS_JSON" | \
      jq -r '[.[] | select(.state == "APPROVED") | select(.stale == false)] | length') || true
    HAS_CHANGES=$(echo "$REVIEWS_JSON" | \
      jq -r '[.[] | select(.state == "REQUEST_CHANGES") | select(.stale == false)] | length') || true

    if ci_passed "$CI_STATE" && [ "${HAS_APPROVE:-0}" -gt 0 ]; then
      if try_direct_merge "$HAS_PR" "$ISSUE_NUM"; then
        exit 0
      fi
      # Direct merge failed (conflicts?) — fall back to dev-agent
      log "falling back to dev-agent for PR #${HAS_PR} merge"
      nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
      log "started dev-agent PID $! for issue #${ISSUE_NUM} (agent-merge)"
      exit 0

    # Do NOT gate REQUEST_CHANGES on ci_passed: act immediately even if CI is
    # pending/unknown. Definitive CI failure is handled by the elif below.
    elif [ "${HAS_CHANGES:-0}" -gt 0 ] && { ci_passed "$CI_STATE" || [ "$CI_STATE" = "pending" ] || [ "$CI_STATE" = "unknown" ] || [ -z "$CI_STATE" ]; }; then
      log "issue #${ISSUE_NUM} PR #${HAS_PR} has REQUEST_CHANGES — spawning agent"
      nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
      log "started dev-agent PID $! for issue #${ISSUE_NUM} (review fix)"
      exit 0

    elif ci_failed "$CI_STATE"; then
      if handle_ci_exhaustion "$HAS_PR" "$ISSUE_NUM" "check_only"; then
        # Fall through to backlog scan instead of exit
        :
      else
        # Increment at actual launch time (not on guard-hit paths)
        if handle_ci_exhaustion "$HAS_PR" "$ISSUE_NUM"; then
          exit 0  # exhausted between check and launch
        fi
        log "issue #${ISSUE_NUM} PR #${HAS_PR} CI failed — spawning agent to fix (attempt ${CI_FIX_ATTEMPTS}/3)"
        nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
        log "started dev-agent PID $! for issue #${ISSUE_NUM} (CI fix)"
        exit 0
      fi

    else
      log "issue #${ISSUE_NUM} has open PR #${HAS_PR} (CI: ${CI_STATE}, waiting)"
      exit 0
    fi
  else
    # Check assignee before adopting orphaned issue
    ISSUE_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/issues/${ISSUE_NUM}") || true
    ASSIGNEE=$(echo "$ISSUE_JSON" | jq -r '.assignee.login // ""') || true

    if [ -n "$ASSIGNEE" ] && [ "$ASSIGNEE" != "$BOT_USER" ]; then
      log "issue #${ISSUE_NUM} assigned to ${ASSIGNEE} — skipping (not orphaned)"
      # Remove in-progress label since this agent isn't working on it
      IP_ID=$(_ilc_in_progress_id)
      curl -sf -X DELETE -H "Authorization: token ${FORGE_TOKEN}" \
        "${API}/issues/${ISSUE_NUM}/labels/${IP_ID}" >/dev/null 2>&1 || true
      exit 0
    fi

    log "recovering orphaned issue #${ISSUE_NUM} (no PR found, assigned to ${BOT_USER:-unassigned})"
    nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
    log "started dev-agent PID $! for issue #${ISSUE_NUM} (recovery)"
    exit 0
  fi
fi

# =============================================================================
# PRIORITY 1.5: any open PR with REQUEST_CHANGES or CI failure (stuck PRs)
# =============================================================================
log "checking for stuck PRs"
OPEN_PRS=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/pulls?state=open&limit=20")

for i in $(seq 0 $(($(echo "$OPEN_PRS" | jq 'length') - 1))); do
  PR_NUM=$(echo "$OPEN_PRS" | jq -r ".[$i].number")
  PR_BRANCH=$(echo "$OPEN_PRS" | jq -r ".[$i].head.ref")
  PR_SHA=$(echo "$OPEN_PRS" | jq -r ".[$i].head.sha")
  PR_TITLE=$(echo "$OPEN_PRS" | jq -r ".[$i].title")
  PR_BODY=$(echo "$OPEN_PRS" | jq -r ".[$i].body // \"\"")

  STUCK_ISSUE=$(extract_issue_from_pr "$PR_BRANCH" "$PR_TITLE" "$PR_BODY")
  if [ -z "$STUCK_ISSUE" ]; then
    # Allow chore PRs from gardener/planner/predictor to merge without issue number
    if [[ "$PR_BRANCH" =~ ^chore/(gardener|planner|predictor)- ]]; then
      STUCK_ISSUE=0
    else
      log "PR #${PR_NUM} has no issue ref — cannot spawn dev-agent, skipping"
      continue
    fi
  fi

  CI_STATE=$(ci_commit_status "$PR_SHA") || true

  # Non-code PRs (docs, formulas, evidence) may have no CI — treat as passed
  if ! ci_passed "$CI_STATE" && ! ci_required_for_pr "$PR_NUM"; then
    CI_STATE="success"
    log "PR #${PR_NUM} has no code files — treating CI as passed"
  fi

  # Single fetch to avoid race window between review checks
  REVIEWS_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/pulls/${PR_NUM}/reviews") || true
  HAS_CHANGES=$(echo "$REVIEWS_JSON" | \
    jq -r '[.[] | select(.state == "REQUEST_CHANGES") | select(.stale == false)] | length') || true
  HAS_APPROVE=$(echo "$REVIEWS_JSON" | \
    jq -r '[.[] | select(.state == "APPROVED") | select(.stale == false)] | length') || true

  # Merge directly if approved + CI green (no Claude needed — single API call)
  if ci_passed "$CI_STATE" && [ "${HAS_APPROVE:-0}" -gt 0 ]; then
    if try_direct_merge "$PR_NUM" "$STUCK_ISSUE"; then
      exit 0
    fi
    # Direct merge failed — dev-agent fallback requires a real issue number
    if [ "$STUCK_ISSUE" -eq 0 ]; then
      log "PR #${PR_NUM} direct merge failed — no issue ref for dev-agent, skipping"
      continue
    fi
    # Direct merge failed (conflicts?) — fall back to dev-agent
    log "falling back to dev-agent for PR #${PR_NUM} merge"
    nohup "${SCRIPT_DIR}/dev-agent.sh" "$STUCK_ISSUE" >> "$LOGFILE" 2>&1 &
    log "started dev-agent PID $! for stuck PR #${PR_NUM} (agent-merge)"
    exit 0
  fi

  # Chore PRs without issue ref can only be direct-merged — skip dev-agent paths
  if [ "$STUCK_ISSUE" -eq 0 ]; then
    continue
  fi

  # Stuck: REQUEST_CHANGES or CI failure -> spawn agent
  if [ "${HAS_CHANGES:-0}" -gt 0 ] && { ci_passed "$CI_STATE" || [ "$CI_STATE" = "pending" ] || [ "$CI_STATE" = "unknown" ] || [ -z "$CI_STATE" ]; }; then
    log "PR #${PR_NUM} (issue #${STUCK_ISSUE}) has REQUEST_CHANGES — fixing first"
    nohup "${SCRIPT_DIR}/dev-agent.sh" "$STUCK_ISSUE" >> "$LOGFILE" 2>&1 &
    log "started dev-agent PID $! for stuck PR #${PR_NUM}"
    exit 0
  elif ci_failed "$CI_STATE"; then
    if handle_ci_exhaustion "$PR_NUM" "$STUCK_ISSUE" "check_only"; then
      continue  # skip this PR, check next stuck PR or fall through to backlog
    fi
    # Increment at actual launch time (not on guard-hit paths)
    if handle_ci_exhaustion "$PR_NUM" "$STUCK_ISSUE"; then
      continue  # exhausted between check and launch
    fi
    log "PR #${PR_NUM} (issue #${STUCK_ISSUE}) CI failed — fixing (attempt ${CI_FIX_ATTEMPTS}/3)"
    nohup "${SCRIPT_DIR}/dev-agent.sh" "$STUCK_ISSUE" >> "$LOGFILE" 2>&1 &
    log "started dev-agent PID $! for stuck PR #${PR_NUM}"
    exit 0
  fi
done

# =============================================================================
# PRIORITY 2: find ready backlog issues (pull system)
#
# Two-tier pickup: priority+backlog issues first (FIFO), then plain backlog
# issues (FIFO). The "priority" label is added alongside "backlog", not instead.
# =============================================================================
log "scanning backlog for ready issues"

# Ensure the priority label exists on this repo
ensure_priority_label >/dev/null 2>&1 || true

# Tier 1: issues with both "priority" and "backlog" labels
PRIORITY_BACKLOG_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/issues?state=open&labels=priority,backlog&limit=20&type=issues&sort=oldest") || true
PRIORITY_BACKLOG_JSON="${PRIORITY_BACKLOG_JSON:-[]}"

# Tier 2: all "backlog" issues (includes priority ones — deduplicated below)
ALL_BACKLOG_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/issues?state=open&labels=backlog&limit=20&type=issues&sort=oldest")

# Combine: priority issues first, then remaining backlog issues (deduped)
BACKLOG_JSON=$(jq -n \
  --argjson pri "$PRIORITY_BACKLOG_JSON" \
  --argjson all "$ALL_BACKLOG_JSON" \
  '($pri | map(.number)) as $pnums | $pri + [$all[] | select(.number as $n | $pnums | map(. == $n) | any | not)]')

BACKLOG_COUNT=$(echo "$BACKLOG_JSON" | jq 'length')
if [ "$BACKLOG_COUNT" -eq 0 ]; then
  log "no backlog issues"
  exit 0
fi

PRIORITY_COUNT=$(echo "$PRIORITY_BACKLOG_JSON" | jq 'length')
log "found ${BACKLOG_COUNT} backlog issues (${PRIORITY_COUNT} priority)"

# Check each for readiness
READY_ISSUE=""
READY_PR_FOR_INCREMENT=""
WAITING_PRS=""
for i in $(seq 0 $((BACKLOG_COUNT - 1))); do
  ISSUE_NUM=$(echo "$BACKLOG_JSON" | jq -r ".[$i].number")
  ISSUE_BODY=$(echo "$BACKLOG_JSON" | jq -r ".[$i].body // \"\"")

  # Check assignee before claiming — skip if assigned to another bot
  ISSUE_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/issues/${ISSUE_NUM}") || true
  ASSIGNEE=$(echo "$ISSUE_JSON" | jq -r '.assignee.login // ""') || true
  if [ -n "$ASSIGNEE" ] && [ "$ASSIGNEE" != "$BOT_USER" ]; then
    log "  #${ISSUE_NUM} assigned to ${ASSIGNEE} — skipping"
    continue
  fi

  # Formula guard: formula-labeled issues must not be picked up by dev-agent.
  ISSUE_LABELS=$(echo "$BACKLOG_JSON" | jq -r ".[$i].labels[].name" 2>/dev/null) || true
  SKIP_LABEL=$(echo "$ISSUE_LABELS" | grep -oE '^(formula|prediction/dismissed|prediction/unreviewed)$' | head -1) || true
  if [ -n "$SKIP_LABEL" ]; then
    log "issue #${ISSUE_NUM} has '${SKIP_LABEL}' label — skipping in backlog scan"
    continue
  fi

  if ! issue_is_ready "$ISSUE_NUM" "$ISSUE_BODY"; then
    continue
  fi

  # Check if there's already an open PR for this issue that needs attention
  EXISTING_PR=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/pulls?state=open&limit=20" | \
    jq -r --arg branch "fix/issue-${ISSUE_NUM}" --arg num "#${ISSUE_NUM}" \
    '.[] | select((.head.ref == $branch) or (.title | contains($num))) | .number' | head -1) || true

  if [ -n "$EXISTING_PR" ]; then
    # Check if branch is stale (behind primary branch)
    BRANCH="fix/issue-${ISSUE_NUM}"
    AHEAD=$(git rev-list --count "origin/${BRANCH}..origin/${PRIMARY_BRANCH}" 2>/dev/null || echo "0")
    if [ "$AHEAD" -gt 0 ]; then
      log "issue #${ISSUE_NUM} PR #${EXISTING_PR} is $AHEAD commits behind ${PRIMARY_BRANCH} — abandoning stale PR"
      # Close the PR via API
      curl -sf -X PATCH \
        -H "Authorization: token ${FORGE_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/pulls/${EXISTING_PR}" \
        -d '{"state":"closed"}' >/dev/null 2>&1 || true
      # Delete the branch via git push
      git -C "${PROJECT_REPO_ROOT:-}" push origin --delete "${BRANCH}" 2>/dev/null || true
      # Reset to fresh start on primary branch
      git -C "${PROJECT_REPO_ROOT:-}" checkout "${PRIMARY_BRANCH}" 2>/dev/null || true
      git -C "${PROJECT_REPO_ROOT:-}" pull --ff-only origin "${PRIMARY_BRANCH}" 2>/dev/null || true
      # Continue to find another ready issue
      continue
    fi

    PR_SHA=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/pulls/${EXISTING_PR}" | jq -r '.head.sha') || true
    CI_STATE=$(ci_commit_status "$PR_SHA") || true

    # Non-code PRs (docs, formulas, evidence) may have no CI — treat as passed
    if ! ci_passed "$CI_STATE" && ! ci_required_for_pr "$EXISTING_PR"; then
      CI_STATE="success"
      log "PR #${EXISTING_PR} has no code files — treating CI as passed"
    fi

    # Single fetch to avoid race window between review checks
    REVIEWS_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/pulls/${EXISTING_PR}/reviews") || true
    HAS_APPROVE=$(echo "$REVIEWS_JSON" | \
      jq -r '[.[] | select(.state == "APPROVED") | select(.stale == false)] | length') || true
    HAS_CHANGES=$(echo "$REVIEWS_JSON" | \
      jq -r '[.[] | select(.state == "REQUEST_CHANGES") | select(.stale == false)] | length') || true

    if ci_passed "$CI_STATE" && [ "${HAS_APPROVE:-0}" -gt 0 ]; then
      if try_direct_merge "$EXISTING_PR" "$ISSUE_NUM"; then
        exit 0
      fi
      # Direct merge failed (conflicts?) — fall back to dev-agent
      log "falling back to dev-agent for PR #${EXISTING_PR} merge"
      nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
      log "started dev-agent PID $! for issue #${ISSUE_NUM} (agent-merge)"
      exit 0

    elif [ "${HAS_CHANGES:-0}" -gt 0 ]; then
      log "#${ISSUE_NUM} PR #${EXISTING_PR} has REQUEST_CHANGES — picking up"
      READY_ISSUE="$ISSUE_NUM"
      break

    elif ci_failed "$CI_STATE"; then
      if handle_ci_exhaustion "$EXISTING_PR" "$ISSUE_NUM" "check_only"; then
        # Don't add to WAITING_PRS — escalated PRs should not block new work
        continue
      fi
      log "#${ISSUE_NUM} PR #${EXISTING_PR} CI failed — picking up (attempt $((CI_FIX_ATTEMPTS+1))/3)"
      READY_ISSUE="$ISSUE_NUM"
      READY_PR_FOR_INCREMENT="$EXISTING_PR"
      break

    else
      log "#${ISSUE_NUM} PR #${EXISTING_PR} exists (CI: ${CI_STATE}, waiting)"
      WAITING_PRS="${WAITING_PRS:-}${WAITING_PRS:+, }#${EXISTING_PR}"
      continue
    fi
  fi

  READY_ISSUE="$ISSUE_NUM"
  log "#${ISSUE_NUM} is READY (all deps merged, no existing PR)"
  break
done

# Single-threaded per project: if any issue has an open PR waiting for review/CI,
# don't start new work — let the pipeline drain first
if [ -n "$READY_ISSUE" ] && [ -n "${WAITING_PRS:-}" ]; then
  log "holding #${READY_ISSUE} — waiting for open PR(s) to land first: ${WAITING_PRS}"
  exit 0
fi

if [ -z "$READY_ISSUE" ]; then
  log "no ready issues (all blocked by unmerged deps)"
  exit 0
fi

# =============================================================================
# LAUNCH: start dev-agent for the ready issue
# =============================================================================
# Deferred CI fix increment — only now that we're certain we are launching.
if [ -n "${READY_PR_FOR_INCREMENT:-}" ]; then
  if handle_ci_exhaustion "$READY_PR_FOR_INCREMENT" "$READY_ISSUE"; then
    # exhausted (another poller incremented between scan and launch) — bail out
    exit 0
  fi
fi

log "launching dev-agent for #${READY_ISSUE}"
nohup "${SCRIPT_DIR}/dev-agent.sh" "$READY_ISSUE" >> "$LOGFILE" 2>&1 &
log "started dev-agent PID $! for issue #${READY_ISSUE}"
