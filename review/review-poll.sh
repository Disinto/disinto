#!/usr/bin/env bash
# review-poll.sh — Poll open PRs and review those with green CI
#
# Peek while running:  cat /tmp/<project>-review-status
# Full log:            tail -f <factory-root>/review/review.log

set -euo pipefail

# Load shared environment (with optional project TOML override)
# Usage: review-poll.sh [projects/harb.toml]
export PROJECT_TOML="${1:-}"
source "$(dirname "$0")/../lib/env.sh"
source "$(dirname "$0")/../lib/ci-helpers.sh"
# shellcheck source=../lib/guard.sh
source "$(dirname "$0")/../lib/guard.sh"
check_active reviewer

REPO_ROOT="${PROJECT_REPO_ROOT}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

API_BASE="${FORGE_API}"
LOGFILE="${DISINTO_LOG_DIR}/review/review-poll.log"
MAX_REVIEWS=3
REVIEW_IDLE_TIMEOUT=14400  # 4h: kill review session if idle

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

# Log rotation
if [ -f "$LOGFILE" ]; then
  LOGSIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
  if [ "$LOGSIZE" -gt 102400 ]; then
    mv "$LOGFILE" "$LOGFILE.old"
    log "Log rotated"
  fi
fi

log "--- Poll start ---"

# --- Clean up stale review sessions ---
# Kill sessions for merged/closed PRs or idle > 4h
REVIEW_SESSIONS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^review-${PROJECT_NAME}-" || true)
if [ -n "$REVIEW_SESSIONS" ]; then
  while IFS= read -r session; do
    pr_num="${session#review-"${PROJECT_NAME}"-}"
    phase_file="/tmp/review-session-${PROJECT_NAME}-${pr_num}.phase"

    # Check if PR is still open
    pr_state=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API_BASE}/pulls/${pr_num}" | jq -r '.state // "unknown"' 2>/dev/null) || true

    if [ "$pr_state" != "open" ]; then
      log "cleanup: killing session ${session} (PR #${pr_num} state=${pr_state})"
      tmux kill-session -t "$session" 2>/dev/null || true
      rm -f "$phase_file" "/tmp/${PROJECT_NAME}-review-output-${pr_num}.json" \
        "/tmp/review-injected-${PROJECT_NAME}-${pr_num}"
      cd "$REPO_ROOT"
      git worktree remove "/tmp/${PROJECT_NAME}-review-${pr_num}" --force 2>/dev/null || true
      rm -rf "/tmp/${PROJECT_NAME}-review-${pr_num}" 2>/dev/null || true
      continue
    fi

    # Check idle timeout (4h)
    phase_mtime=$(stat -c %Y "$phase_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ "$phase_mtime" -gt 0 ] && [ $(( now - phase_mtime )) -gt "$REVIEW_IDLE_TIMEOUT" ]; then
      log "cleanup: killing session ${session} (idle > 4h)"
      tmux kill-session -t "$session" 2>/dev/null || true
      rm -f "$phase_file" "/tmp/${PROJECT_NAME}-review-output-${pr_num}.json" \
        "/tmp/review-injected-${PROJECT_NAME}-${pr_num}"
      cd "$REPO_ROOT"
      git worktree remove "/tmp/${PROJECT_NAME}-review-${pr_num}" --force 2>/dev/null || true
      rm -rf "/tmp/${PROJECT_NAME}-review-${pr_num}" 2>/dev/null || true
      continue
    fi

    # Safety net: clean up sessions in terminal phases (review already posted)
    current_phase=$(head -1 "$phase_file" 2>/dev/null | tr -d '[:space:]' || true)
    if [ "$current_phase" = "PHASE:review_complete" ]; then
      log "cleanup: killing session ${session} (terminal phase: review_complete)"
      tmux kill-session -t "$session" 2>/dev/null || true
      rm -f "$phase_file" "/tmp/${PROJECT_NAME}-review-output-${pr_num}.json" \
        "/tmp/review-injected-${PROJECT_NAME}-${pr_num}"
      cd "$REPO_ROOT"
      git worktree remove "/tmp/${PROJECT_NAME}-review-${pr_num}" --force 2>/dev/null || true
      rm -rf "/tmp/${PROJECT_NAME}-review-${pr_num}" 2>/dev/null || true
      continue
    fi
  done <<< "$REVIEW_SESSIONS"
fi

PRS=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${API_BASE}/pulls?state=open&limit=20" | \
  jq -r --arg branch "${PRIMARY_BRANCH}" '.[] | select(.base.ref == $branch) | select(.draft != true) | select(.title | test("^\\[?WIP[\\]:]"; "i") | not) | "\(.number) \(.head.sha) \(.head.ref)"')

if [ -z "$PRS" ]; then
  log "No open PRs targeting ${PRIMARY_BRANCH}"
  exit 0
fi

TOTAL=$(echo "$PRS" | wc -l)
log "Found ${TOTAL} open PRs"

REVIEWED=0
SKIPPED=0

inject_review_into_dev_session() {
  local pr_num="$1" pr_sha="$2" pr_branch="$3"

  local issue_num
  issue_num=$(printf '%s' "$pr_branch" | grep -oP 'issue-\K[0-9]+' || true)
  [ -z "$issue_num" ] && return 0

  local session="dev-${PROJECT_NAME}-${issue_num}"
  local phase_file="/tmp/dev-session-${PROJECT_NAME}-${issue_num}.phase"

  tmux has-session -t "${session}" 2>/dev/null || return 0

  local current_phase
  current_phase=$(head -1 "${phase_file}" 2>/dev/null | tr -d '[:space:]' || true)
  [ "${current_phase}" = "PHASE:awaiting_review" ] || return 0

  local review_text="" verdict=""

  # Try bot review comment first (richer content with <!-- reviewed: SHA --> marker)
  local review_comment
  review_comment=$(forge_api_all "/issues/${pr_num}/comments" | \
    jq -r --arg sha "${pr_sha}" \
    '[.[] | select(.body | contains("<!-- reviewed: " + $sha))] | last // empty') || true
  if [ -n "${review_comment}" ] && [ "${review_comment}" != "null" ]; then
    review_text=$(printf '%s' "${review_comment}" | jq -r '.body')
    verdict=$(printf '%s' "${review_text}" | grep -oP '\*\*(APPROVE|REQUEST_CHANGES|DISCUSS)\*\*' | head -1 | tr -d '*' || true)
  fi

  # Fallback: check formal forge reviews (#771)
  if [ -z "$verdict" ]; then
    local formal_review formal_state
    formal_review=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API_BASE}/pulls/${pr_num}/reviews" | \
      jq -r '[.[] | select(.stale == false) | select(.state == "APPROVED" or .state == "REQUEST_CHANGES")] | last // empty') || true
    if [ -n "$formal_review" ] && [ "$formal_review" != "null" ]; then
      formal_state=$(printf '%s' "$formal_review" | jq -r '.state // ""')
      if [ "$formal_state" = "APPROVED" ]; then
        verdict="APPROVE"
      elif [ "$formal_state" = "REQUEST_CHANGES" ]; then
        verdict="REQUEST_CHANGES"
      fi
      [ -z "$review_text" ] && review_text=$(printf '%s' "$formal_review" | jq -r '.body // ""')
    fi
  fi

  [ -z "$verdict" ] && return 0

  local inject_msg=""
  if [ "${verdict}" = "APPROVE" ]; then
    inject_msg="Approved! PR #${pr_num} has been approved by the reviewer.

The orchestrator will handle merging and closing the issue automatically.
You do not need to take any action — stop and wait."
  elif [ "${verdict}" = "REQUEST_CHANGES" ] || [ "${verdict}" = "DISCUSS" ]; then
    inject_msg="Review: ${verdict} on PR #${pr_num}:

${review_text}

Instructions:
1. Address each piece of feedback carefully.
2. Run lint and tests when done.
3. Commit your changes and push: git push ${FORGE_REMOTE:-origin} ${pr_branch}
4. Write: echo \"PHASE:awaiting_ci\" > \"${phase_file}\"
5. Stop and wait for the next CI result."
  fi

  [ -z "${inject_msg}" ] && return 0

  local inject_tmp
  inject_tmp=$(mktemp /tmp/review-inject-XXXXXX)
  printf '%s' "${inject_msg}" > "${inject_tmp}"
  # All tmux calls guarded with || true: the dev session is external and may die
  # between the has-session check above and here; a non-zero exit must not abort
  # the outer poll loop under set -euo pipefail.
  tmux load-buffer -b "review-inject-${pr_num}" "${inject_tmp}" || true
  tmux paste-buffer -t "${session}" -b "review-inject-${pr_num}" || true
  sleep 0.5
  tmux send-keys -t "${session}" "" Enter || true
  tmux delete-buffer -b "review-inject-${pr_num}" 2>/dev/null || true
  rm -f "${inject_tmp}"
  log "  #${pr_num} review (${verdict}) injected into session ${session}"
  # Write sentinel so dev-agent.sh awaiting_review loop skips its own injection
  touch "/tmp/review-injected-${PROJECT_NAME}-${pr_num}"
}

# --- Re-review: trigger review for awaiting_changes sessions with new commits ---
if [ -n "${REVIEW_SESSIONS:-}" ]; then
  while IFS= read -r session; do
    pr_num="${session#review-"${PROJECT_NAME}"-}"
    phase_file="/tmp/review-session-${PROJECT_NAME}-${pr_num}.phase"

    current_phase=$(head -1 "$phase_file" 2>/dev/null | tr -d '[:space:]' || true)
    [ "$current_phase" = "PHASE:awaiting_changes" ] || continue

    reviewed_sha=$(sed -n 's/^SHA://p' "$phase_file" 2>/dev/null | tr -d '[:space:]' || true)
    [ -n "$reviewed_sha" ] || continue

    pr_json=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API_BASE}/pulls/${pr_num}" 2>/dev/null || true)
    [ -n "$pr_json" ] || continue

    pr_state=$(printf '%s' "$pr_json" | jq -r '.state // "unknown"')
    [ "$pr_state" = "open" ] || continue

    current_sha=$(printf '%s' "$pr_json" | jq -r '.head.sha // ""')
    pr_branch=$(printf '%s' "$pr_json" | jq -r '.head.ref // ""')
    if [ -z "$current_sha" ] || [ "$current_sha" = "$reviewed_sha" ]; then continue; fi

    ci_state=$(ci_commit_status "$current_sha")

    if ! ci_passed "$ci_state"; then
      if ci_required_for_pr "$pr_num"; then
        log "  #${pr_num} awaiting_changes: new SHA ${current_sha:0:7} CI=${ci_state}, waiting"
        continue
      fi
    fi

    log "  #${pr_num} re-review: new commits (${reviewed_sha:0:7}→${current_sha:0:7})"

    if "${SCRIPT_DIR}/review-pr.sh" "$pr_num" 2>&1; then
      REVIEWED=$((REVIEWED + 1))
      FRESH_SHA=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
        "${API_BASE}/pulls/${pr_num}" | jq -r '.head.sha // ""') || true
      inject_review_into_dev_session "$pr_num" "${FRESH_SHA:-$current_sha}" "$pr_branch"
    else
      log "  #${pr_num} re-review failed"
    fi

    [ "$REVIEWED" -lt "$MAX_REVIEWS" ] || break
  done <<< "$REVIEW_SESSIONS"
fi

while IFS= read -r line; do
  PR_NUM=$(echo "$line" | awk '{print $1}')
  PR_SHA=$(echo "$line" | awk '{print $2}')
  PR_BRANCH=$(echo "$line" | awk '{print $3}')

  CI_STATE=$(ci_commit_status "$PR_SHA")

  # Skip if CI is running/failed. Allow "success", no CI configured, or non-code PRs
  if ! ci_passed "$CI_STATE"; then
    if ci_required_for_pr "$PR_NUM"; then
      log "  #${PR_NUM} CI=${CI_STATE}, skip"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    log "  #${PR_NUM} CI=${CI_STATE} but no code files — proceeding"
  fi

  # Check formal forge reviews (not comment markers)
  HAS_REVIEW=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API_BASE}/pulls/${PR_NUM}/reviews" | \
    jq -r --arg sha "$PR_SHA" \
    '[.[] | select(.commit_id == $sha) | select(.state != "COMMENT")] | length')

  if [ "${HAS_REVIEW:-0}" -gt "0" ]; then
    log "  #${PR_NUM} formal review exists for ${PR_SHA:0:7}, skip"
    # Inject review feedback into dev session if awaiting (#771)
    inject_review_into_dev_session "$PR_NUM" "$PR_SHA" "$PR_BRANCH"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  log "  #${PR_NUM} needs review (CI=success, SHA=${PR_SHA:0:7})"

  if "${SCRIPT_DIR}/review-pr.sh" "$PR_NUM" 2>&1; then
    REVIEWED=$((REVIEWED + 1))
    # Re-fetch current SHA: review-pr.sh fetches the PR independently and tags its
    # comment with whatever SHA it saw.  If a commit arrived while review-pr.sh was
    # running those two SHA captures diverge and we would miss the comment.
    FRESH_SHA=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API_BASE}/pulls/${PR_NUM}" | jq -r '.head.sha // ""') || true
    inject_review_into_dev_session "$PR_NUM" "${FRESH_SHA:-$PR_SHA}" "$PR_BRANCH"
  else
    log "  #${PR_NUM} review failed"
  fi

  if [ "$REVIEWED" -ge "$MAX_REVIEWS" ]; then
    log "Hit max reviews (${MAX_REVIEWS}), stopping"
    break
  fi

  sleep 2

done <<< "$PRS"

log "--- Poll done: ${REVIEWED} reviewed, ${SKIPPED} skipped ---"
