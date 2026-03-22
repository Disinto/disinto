#!/usr/bin/env bash
# dev-poll.sh — Pull-based scheduler: find the next ready issue and start dev-agent
#
# Pull system: issues labeled "backlog" are candidates. An issue is READY when
# ALL its dependency issues are closed (and their PRs merged).
# No "todo" label needed — readiness is derived from reality.
#
# Priority:
#   1. Orphaned "in-progress" issues (agent died or PR needs attention)
#   2. Ready "backlog" issues (all deps merged)
#
# Usage:
#   cron every 10min
#   dev-poll.sh [projects/harb.toml]   # optional project config

set -euo pipefail

# Load shared environment (with optional project TOML override)
export PROJECT_TOML="${1:-}"
source "$(dirname "$0")/../lib/env.sh"
source "$(dirname "$0")/../lib/ci-helpers.sh"

# Gitea labels API requires []int64 — look up the "underspecified" label ID once
UNDERSPECIFIED_LABEL_ID=$(codeberg_api GET "/labels" 2>/dev/null \
  | jq -r '.[] | select(.name == "underspecified") | .id' 2>/dev/null || true)
UNDERSPECIFIED_LABEL_ID="${UNDERSPECIFIED_LABEL_ID:-1300816}"

# Track CI fix attempts per PR to avoid infinite respawn loops
CI_FIX_TRACKER="${FACTORY_ROOT}/dev/ci-fixes-${PROJECT_NAME:-default}.json"
CI_FIX_LOCK="${CI_FIX_TRACKER}.lock"
ci_fix_count() {
  local pr="$1"
  flock "$CI_FIX_LOCK" python3 -c "import json,sys;d=json.load(open('$CI_FIX_TRACKER')) if __import__('os').path.exists('$CI_FIX_TRACKER') else {};print(d.get(str($pr),0))" 2>/dev/null || echo 0
}
ci_fix_increment() {
  local pr="$1"
  flock "$CI_FIX_LOCK" python3 -c "
import json,os
f='$CI_FIX_TRACKER'
d=json.load(open(f)) if os.path.exists(f) else {}
d[str($pr)]=d.get(str($pr),0)+1
json.dump(d,open(f,'w'))
" 2>/dev/null || true
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
  codeberg_api GET "/issues/${issue}/labels" 2>/dev/null \
    | jq -e '.[] | select(.name == "blocked")' >/dev/null 2>&1
}

# Post a CI-exhaustion diagnostic comment and label issue as blocked.
# Args: issue_num pr_num attempts
_post_ci_blocked_comment() {
  local issue_num="$1" pr_num="$2" attempts="$3"
  local blocked_id
  blocked_id=$(ensure_blocked_label_id)
  [ -z "$blocked_id" ] && return 0

  local comment
  comment="### Session failure diagnostic

| Field | Value |
|---|---|
| Exit reason | \`ci_exhausted_poll (${attempts} attempts)\` |
| Timestamp | \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\` |
| PR | #${pr_num} |"

  curl -sf -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${CODEBERG_API}/issues/${issue_num}/comments" \
    -d "$(jq -nc --arg b "$comment" '{body:$b}')" >/dev/null 2>&1 || true
  curl -sf -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${CODEBERG_API}/issues/${issue_num}/labels" \
    -d "{\"labels\":[${blocked_id}]}" >/dev/null 2>&1 || true
}

# =============================================================================
# HELPER: handle CI-exhaustion check/block (DRY for 3 call sites)
# Sets CI_FIX_ATTEMPTS for caller use. Returns 0 if exhausted, 1 if not.
#
# Pass "check_only" as third arg for the backlog scan path: ok-counts are
# returned without incrementing (deferred to launch time so a WAITING_PRS
# exit cannot waste a fix attempt). The 3→4 sentinel bump is always atomic
# regardless of mode, preventing duplicate blocked labels from concurrent
# pollers.
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

  # Single flock-protected call: read + threshold-check + conditional bump.
  # In check_only mode, ok-counts are returned without incrementing (deferred
  # to launch time). In both modes, the 3→4 sentinel bump is atomic, so only
  # one concurrent poller can ever receive exhausted_first_time:3 and label
  # the issue blocked.
  result=$(ci_fix_check_and_increment "$pr_num" "$check_only")
  case "$result" in
    ok:*)
      CI_FIX_ATTEMPTS="${result#ok:}"
      return 1
      ;;
    exhausted_first_time:*)
      CI_FIX_ATTEMPTS="${result#exhausted_first_time:}"
      log "PR #${pr_num} (issue #${issue_num}) CI exhausted (${CI_FIX_ATTEMPTS} attempts) — marking blocked"
      _post_ci_blocked_comment "$issue_num" "$pr_num" "$CI_FIX_ATTEMPTS"
      matrix_send "dev" "🚨 PR #${pr_num} (issue #${issue_num}) CI failed after ${CI_FIX_ATTEMPTS} attempts — marked blocked" 2>/dev/null || true
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
# HELPER: merge an approved PR directly (no Claude needed)
#
# Merging an approved, CI-green PR is a single API call. Spawning dev-agent
# for this fails when the issue is already closed (Codeberg auto-closes issues
# on PR creation when body contains "Fixes #N"), causing a respawn loop (#344).
# =============================================================================
try_direct_merge() {
  local pr_num="$1" issue_num="$2"

  log "PR #${pr_num} (issue #${issue_num}) approved + CI green → attempting direct merge"

  local merge_resp merge_http
  merge_resp=$(curl -sf -w '\n%{http_code}' -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H 'Content-Type: application/json' \
    "${API}/pulls/${pr_num}/merge" \
    -d '{"Do":"merge","delete_branch_after_merge":true}' 2>/dev/null) || true

  merge_http=$(echo "$merge_resp" | tail -1)

  if [ "${merge_http:-0}" = "200" ] || [ "${merge_http:-0}" = "204" ]; then
    log "PR #${pr_num} merged successfully"
    # Close the issue (may already be closed by Codeberg auto-close)
    curl -sf -X PATCH \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      -H 'Content-Type: application/json' \
      "${API}/issues/${issue_num}" \
      -d '{"state":"closed"}' >/dev/null 2>&1 || true
    # Remove in-progress label
    curl -sf -X DELETE \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/issues/${issue_num}/labels/in-progress" >/dev/null 2>&1 || true
    # Clean up CI fix tracker
    ci_fix_reset "$pr_num"
    # Clean up phase/session artifacts
    rm -f "/tmp/dev-session-${PROJECT_NAME}-${issue_num}.phase" \
          "/tmp/dev-impl-summary-${PROJECT_NAME}-${issue_num}.txt"
    matrix_send "dev" "✅ PR #${pr_num} (issue #${issue_num}) merged directly by dev-poll" 2>/dev/null || true
    return 0
  fi

  log "PR #${pr_num} direct merge failed (HTTP ${merge_http:-?}) — falling back to dev-agent"
  return 1
}

API="${CODEBERG_API}"
LOCKFILE="/tmp/dev-agent-${PROJECT_NAME:-default}.lock"
LOGFILE="${FACTORY_ROOT}/dev/dev-agent-${PROJECT_NAME:-default}.log"
PREFLIGHT_RESULT="/tmp/dev-agent-preflight.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
  printf '[%s] poll: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

# =============================================================================
# PRE-LOCK: merge approved + CI-green PRs (no Claude session needed)
#
# Merging is a single API call — it doesn't need the dev-agent lock.
# This ensures approved PRs get merged even while a dev-agent is running.
# (See #531: direct merges should not be blocked by agent lock)
# =============================================================================
log "pre-lock: scanning for mergeable PRs"
PL_PRS=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API}/pulls?state=open&limit=20")

PL_MERGED_ANY=false
for i in $(seq 0 $(($(echo "$PL_PRS" | jq 'length') - 1))); do
  PL_PR_NUM=$(echo "$PL_PRS" | jq -r ".[$i].number")
  PL_PR_SHA=$(echo "$PL_PRS" | jq -r ".[$i].head.sha")
  PL_PR_BRANCH=$(echo "$PL_PRS" | jq -r ".[$i].head.ref")
  PL_PR_TITLE=$(echo "$PL_PRS" | jq -r ".[$i].title")
  PL_PR_BODY=$(echo "$PL_PRS" | jq -r ".[$i].body // \"\"")

  # Extract issue number from branch name, PR title, or PR body
  PL_ISSUE=$(echo "$PL_PR_BRANCH" | grep -oP '(?<=fix/issue-)\d+' || true)
  if [ -z "$PL_ISSUE" ]; then
    PL_ISSUE=$(echo "$PL_PR_TITLE" | grep -oP '#\K\d+' | tail -1 || true)
  fi
  if [ -z "$PL_ISSUE" ]; then
    PL_ISSUE=$(echo "$PL_PR_BODY" | grep -oiP '(?:closes|fixes|resolves)\s*#\K\d+' | head -1 || true)
  fi
  if [ -z "$PL_ISSUE" ]; then
    continue
  fi

  PL_CI_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/commits/${PL_PR_SHA}/status" | jq -r '.state // "unknown"') || true

  # Non-code PRs may have no CI — treat as passed
  if ! ci_passed "$PL_CI_STATE" && ! ci_required_for_pr "$PL_PR_NUM"; then
    PL_CI_STATE="success"
  fi

  if ! ci_passed "$PL_CI_STATE"; then
    continue
  fi

  # Check for approval (non-stale)
  PL_REVIEWS=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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

# --- Check if dev-agent already running ---
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "agent running (PID ${LOCK_PID})"
    exit 0
  fi
  rm -f "$LOCKFILE"
fi

# --- Memory guard ---
AVAIL_MB=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
if [ "$AVAIL_MB" -lt 2000 ]; then
  log "SKIP: only ${AVAIL_MB}MB available (need 2000MB)"
  matrix_send "dev" "⚠️ Low memory (${AVAIL_MB}MB) — skipping dev-agent" 2>/dev/null || true
  exit 0
fi

# =============================================================================
# HELPER: check if a dependency issue is fully resolved (closed + PR merged)
# =============================================================================
dep_is_merged() {
  local dep_num="$1"

  # Check issue is closed
  local dep_state
  dep_state=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/issues/${dep_num}" | jq -r '.state // "open"')
  if [ "$dep_state" != "closed" ]; then
    return 1
  fi

  # Issue closed = dep satisfied. The scheduler only closes issues after
  # merging, so closed state is trustworthy. No need to hunt for the
  # specific PR — that was over-engineering that caused false negatives.
  return 0
}

# =============================================================================
# HELPER: extract dependency numbers from issue body
# =============================================================================
get_deps() {
  local issue_body="$1"
  # Shared parser: lib/parse-deps.sh (single source of truth)
  echo "$issue_body" | bash "${FACTORY_ROOT}/lib/parse-deps.sh"
}

# =============================================================================
# HELPER: check if issue is ready (all deps merged)
# =============================================================================
issue_is_ready() {
  local issue_num="$1"
  local issue_body="$2"

  local deps
  deps=$(get_deps "$issue_body")

  if [ -z "$deps" ]; then
    # No dependencies — always ready
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
# PRIORITY 1: orphaned in-progress issues
# =============================================================================
log "checking for in-progress issues"
ORPHANS_JSON=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API}/issues?state=open&labels=in-progress&limit=10&type=issues")

ORPHAN_COUNT=$(echo "$ORPHANS_JSON" | jq 'length')
if [ "$ORPHAN_COUNT" -gt 0 ]; then
  ISSUE_NUM=$(echo "$ORPHANS_JSON" | jq -r '.[0].number')

  # Formula guard: formula-labeled issues should not be worked on by dev-agent.
  # Remove in-progress label and skip to prevent infinite respawn cycle (#115).
  ORPHAN_LABELS=$(echo "$ORPHANS_JSON" | jq -r '.[0].labels[].name' 2>/dev/null) || true
  SKIP_LABEL=$(echo "$ORPHAN_LABELS" | grep -oE '^(formula|action|prediction/backlog|prediction/unreviewed)$' | head -1) || true
  if [ -n "$SKIP_LABEL" ]; then
    log "issue #${ISSUE_NUM} has '${SKIP_LABEL}' label — removing in-progress, skipping"
    curl -sf -X DELETE -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/issues/${ISSUE_NUM}/labels/in-progress" >/dev/null 2>&1 || true
    exit 0
  fi

  # Check if there's already an open PR for this issue
  HAS_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls?state=open&limit=20" | \
    jq -r --arg branch "fix/issue-${ISSUE_NUM}" \
    '.[] | select(.head.ref == $branch) | .number' | head -1) || true

  if [ -n "$HAS_PR" ]; then
    PR_SHA=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${HAS_PR}" | jq -r '.head.sha') || true
    CI_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/commits/${PR_SHA}/status" | jq -r '.state // "unknown"') || true

    # Non-code PRs (docs, formulas, evidence) may have no CI — treat as passed
    if ! ci_passed "$CI_STATE" && ! ci_required_for_pr "$HAS_PR"; then
      CI_STATE="success"
      log "PR #${HAS_PR} has no code files — treating CI as passed"
    fi

    # Check formal reviews (single fetch to avoid race window)
    REVIEWS_JSON=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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
      SESSION_NAME="dev-${PROJECT_NAME}-${ISSUE_NUM}"
      if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log "issue #${ISSUE_NUM} already has active session ${SESSION_NAME} — skipping"
      else
        log "falling back to dev-agent for PR #${HAS_PR} merge"
        nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
        log "started dev-agent PID $! for issue #${ISSUE_NUM} (agent-merge)"
      fi
      exit 0

    # Do NOT gate REQUEST_CHANGES on ci_passed: act immediately even if CI is
    # pending/unknown. Definitive CI failure is handled by the elif below.
    elif [ "${HAS_CHANGES:-0}" -gt 0 ] && { ci_passed "$CI_STATE" || [ "$CI_STATE" = "pending" ] || [ "$CI_STATE" = "unknown" ] || [ -z "$CI_STATE" ]; }; then
      SESSION_NAME="dev-${PROJECT_NAME}-${ISSUE_NUM}"
      if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log "issue #${ISSUE_NUM} already has active session ${SESSION_NAME} — skipping"
      else
        log "issue #${ISSUE_NUM} PR #${HAS_PR} has REQUEST_CHANGES — spawning agent"
        nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
        log "started dev-agent PID $! for issue #${ISSUE_NUM} (review fix)"
      fi
      exit 0

    elif ci_failed "$CI_STATE"; then
      SESSION_NAME="dev-${PROJECT_NAME}-${ISSUE_NUM}"
      if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log "issue #${ISSUE_NUM} already has active session ${SESSION_NAME} — skipping"
        exit 0
      fi
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
    fi
  else
    SESSION_NAME="dev-${PROJECT_NAME}-${ISSUE_NUM}"
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
      log "issue #${ISSUE_NUM} already has active session ${SESSION_NAME} — skipping"
    else
      log "recovering orphaned issue #${ISSUE_NUM} (no PR found)"
      nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
      log "started dev-agent PID $! for issue #${ISSUE_NUM} (recovery)"
    fi
    exit 0
  fi
fi

# =============================================================================
# PRIORITY 1.5: any open PR with REQUEST_CHANGES or CI failure (stuck PRs)
# =============================================================================
log "checking for stuck PRs"
OPEN_PRS=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API}/pulls?state=open&limit=20")

for i in $(seq 0 $(($(echo "$OPEN_PRS" | jq 'length') - 1))); do
  PR_NUM=$(echo "$OPEN_PRS" | jq -r ".[$i].number")
  PR_BRANCH=$(echo "$OPEN_PRS" | jq -r ".[$i].head.ref")
  PR_SHA=$(echo "$OPEN_PRS" | jq -r ".[$i].head.sha")

  # Extract issue number from branch name (fix/issue-NNN), PR title (#NNN), or PR body (Closes #NNN)
  PR_TITLE=$(echo "$OPEN_PRS" | jq -r ".[$i].title")
  PR_BODY=$(echo "$OPEN_PRS" | jq -r ".[$i].body // \"\"")
  STUCK_ISSUE=$(echo "$PR_BRANCH" | grep -oP '(?<=fix/issue-)\d+' || true)
  if [ -z "$STUCK_ISSUE" ]; then
    STUCK_ISSUE=$(echo "$PR_TITLE" | grep -oP '#\K\d+' | tail -1 || true)
  fi
  if [ -z "$STUCK_ISSUE" ]; then
    STUCK_ISSUE=$(echo "$PR_BODY" | grep -oiP '(?:closes|fixes|resolves)\s*#\K\d+' | head -1 || true)
  fi
  if [ -z "$STUCK_ISSUE" ]; then
    log "PR #${PR_NUM} has no issue ref — cannot spawn dev-agent, skipping"
    continue
  fi

  CI_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/commits/${PR_SHA}/status" | jq -r '.state // "unknown"') || true

  # Non-code PRs (docs, formulas, evidence) may have no CI — treat as passed
  if ! ci_passed "$CI_STATE" && ! ci_required_for_pr "$PR_NUM"; then
    CI_STATE="success"
    log "PR #${PR_NUM} has no code files — treating CI as passed"
  fi

  # Single fetch to avoid race window between review checks
  REVIEWS_JSON=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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
    # Direct merge failed (conflicts?) — fall back to dev-agent
    SESSION_NAME="dev-${PROJECT_NAME}-${STUCK_ISSUE}"
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
      log "issue #${STUCK_ISSUE} already has active session ${SESSION_NAME} — skipping"
    else
      log "falling back to dev-agent for PR #${PR_NUM} merge"
      nohup "${SCRIPT_DIR}/dev-agent.sh" "$STUCK_ISSUE" >> "$LOGFILE" 2>&1 &
      log "started dev-agent PID $! for stuck PR #${PR_NUM} (agent-merge)"
    fi
    exit 0
  fi

  # Stuck: REQUEST_CHANGES or CI failure → spawn agent
  # Do NOT gate REQUEST_CHANGES on ci_passed: if a reviewer leaves REQUEST_CHANGES
  # while CI is still pending/unknown, we must act immediately rather than wait for
  # CI to settle. Definitive CI failure (non-pending, non-unknown) is handled by
  # the elif below, so we only spawn here when CI has not definitively failed.
  if [ "${HAS_CHANGES:-0}" -gt 0 ] && { ci_passed "$CI_STATE" || [ "$CI_STATE" = "pending" ] || [ "$CI_STATE" = "unknown" ] || [ -z "$CI_STATE" ]; }; then
    SESSION_NAME="dev-${PROJECT_NAME}-${STUCK_ISSUE}"
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
      log "issue #${STUCK_ISSUE} already has active session ${SESSION_NAME} — skipping"
      continue
    fi
    log "PR #${PR_NUM} (issue #${STUCK_ISSUE}) has REQUEST_CHANGES — fixing first"
    nohup "${SCRIPT_DIR}/dev-agent.sh" "$STUCK_ISSUE" >> "$LOGFILE" 2>&1 &
    log "started dev-agent PID $! for stuck PR #${PR_NUM}"
    exit 0
  elif ci_failed "$CI_STATE"; then
    SESSION_NAME="dev-${PROJECT_NAME}-${STUCK_ISSUE}"
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
      log "issue #${STUCK_ISSUE} already has active session ${SESSION_NAME} — skipping"
      continue
    fi
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
# =============================================================================
log "scanning backlog for ready issues"
BACKLOG_JSON=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API}/issues?state=open&labels=backlog&limit=20&type=issues&sort=oldest")

BACKLOG_COUNT=$(echo "$BACKLOG_JSON" | jq 'length')
if [ "$BACKLOG_COUNT" -eq 0 ]; then
  log "no backlog issues"
  exit 0
fi

log "found ${BACKLOG_COUNT} backlog issues"

# Check each for readiness
READY_ISSUE=""
for i in $(seq 0 $((BACKLOG_COUNT - 1))); do
  ISSUE_NUM=$(echo "$BACKLOG_JSON" | jq -r ".[$i].number")
  ISSUE_BODY=$(echo "$BACKLOG_JSON" | jq -r ".[$i].body // \"\"")

  # Formula guard: formula-labeled issues must not be picked up by dev-agent.
  # A formula issue that accidentally acquires the backlog label should be skipped.
  ISSUE_LABELS=$(echo "$BACKLOG_JSON" | jq -r ".[$i].labels[].name" 2>/dev/null) || true
  SKIP_LABEL=$(echo "$ISSUE_LABELS" | grep -oE '^(formula|action|prediction/backlog|prediction/unreviewed)$' | head -1) || true
  if [ -n "$SKIP_LABEL" ]; then
    log "issue #${ISSUE_NUM} has '${SKIP_LABEL}' label — skipping in backlog scan"
    continue
  fi

  if ! issue_is_ready "$ISSUE_NUM" "$ISSUE_BODY"; then
    continue
  fi

  # Check if there's already an open PR for this issue that needs attention
  EXISTING_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls?state=open&limit=20" | \
    jq -r --arg branch "fix/issue-${ISSUE_NUM}" --arg num "#${ISSUE_NUM}" \
    '.[] | select((.head.ref == $branch) or (.title | contains($num))) | .number' | head -1) || true

  if [ -n "$EXISTING_PR" ]; then
    PR_SHA=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${EXISTING_PR}" | jq -r '.head.sha') || true
    CI_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/commits/${PR_SHA}/status" | jq -r '.state // "unknown"') || true

    # Non-code PRs (docs, formulas, evidence) may have no CI — treat as passed
    if ! ci_passed "$CI_STATE" && ! ci_required_for_pr "$EXISTING_PR"; then
      CI_STATE="success"
      log "PR #${EXISTING_PR} has no code files — treating CI as passed"
    fi

    # Single fetch to avoid race window between review checks
    REVIEWS_JSON=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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
# Uses the atomic ci_fix_check_and_increment (inside handle_ci_exhaustion) so
# the counter is bumped exactly once even under concurrent poll invocations,
# and a WAITING_PRS exit above cannot silently consume a fix attempt.
if [ -n "${READY_PR_FOR_INCREMENT:-}" ]; then
  if handle_ci_exhaustion "$READY_PR_FOR_INCREMENT" "$READY_ISSUE"; then
    # exhausted (another poller incremented between scan and launch) — bail out
    exit 0
  fi
fi

log "launching dev-agent for #${READY_ISSUE}"
matrix_send "dev" "🚀 Starting dev-agent on issue #${READY_ISSUE}" 2>/dev/null || true
rm -f "$PREFLIGHT_RESULT"

nohup "${SCRIPT_DIR}/dev-agent.sh" "$READY_ISSUE" >> "$LOGFILE" 2>&1 &
AGENT_PID=$!

# Wait briefly for preflight (agent writes result before claiming)
for _w in $(seq 1 30); do
  if [ -f "$PREFLIGHT_RESULT" ]; then
    break
  fi
  if ! kill -0 "$AGENT_PID" 2>/dev/null; then
    break
  fi
  sleep 2
done

if [ -f "$PREFLIGHT_RESULT" ]; then
  PREFLIGHT_STATUS=$(jq -r '.status // "unknown"' < "$PREFLIGHT_RESULT")
  rm -f "$PREFLIGHT_RESULT"

  case "$PREFLIGHT_STATUS" in
    ready)
      log "dev-agent running for #${READY_ISSUE}"
      ;;
    unmet_dependency)
      log "#${READY_ISSUE} has code-level dependency (preflight blocked)"
      wait "$AGENT_PID" 2>/dev/null || true
      ;;
    too_large)
      REASON=$(jq -r '.reason // "unspecified"' < "$PREFLIGHT_RESULT" 2>/dev/null || echo "unspecified")
      log "#${READY_ISSUE} too large: ${REASON}"
      # Label as underspecified
      curl -sf -X POST -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/issues/${READY_ISSUE}/labels" \
        -d "{\"labels\":[${UNDERSPECIFIED_LABEL_ID}]}" >/dev/null 2>&1 || true
      ;;
    already_done)
      log "#${READY_ISSUE} already done"
      ;;
    *)
      log "#${READY_ISSUE} unknown preflight: ${PREFLIGHT_STATUS}"
      ;;
  esac
elif kill -0 "$AGENT_PID" 2>/dev/null; then
  log "dev-agent running for #${READY_ISSUE} (passed preflight)"
else
  log "dev-agent exited for #${READY_ISSUE} without preflight result"
fi
