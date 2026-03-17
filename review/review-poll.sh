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


REPO="${CODEBERG_REPO}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

API_BASE="${CODEBERG_API}"
LOGFILE="$SCRIPT_DIR/review.log"
MAX_REVIEWS=3

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

PRS=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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

  local review_comment
  review_comment=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API_BASE}/issues/${pr_num}/comments?limit=50" | \
    jq -r --arg sha "${pr_sha}" \
    '[.[] | select(.body | contains("<!-- reviewed: " + $sha))] | last // empty') || true
  if [ -z "${review_comment}" ] || [ "${review_comment}" = "null" ]; then
    return 0
  fi

  local review_text verdict
  review_text=$(printf '%s' "${review_comment}" | jq -r '.body')
  verdict=$(printf '%s' "${review_text}" | grep -oP '\*\*(APPROVE|REQUEST_CHANGES|DISCUSS)\*\*' | head -1 | tr -d '*' || true)

  local inject_msg=""
  if [ "${verdict}" = "APPROVE" ]; then
    inject_msg="Approved! PR #${pr_num} has been approved by the reviewer.
Write PHASE:done to the phase file — the orchestrator will handle the merge:
  echo \"PHASE:done\" > \"${phase_file}\""
  elif [ "${verdict}" = "REQUEST_CHANGES" ] || [ "${verdict}" = "DISCUSS" ]; then
    inject_msg="Review: ${verdict} on PR #${pr_num}:

${review_text}

Instructions:
1. Address each piece of feedback carefully.
2. Run lint and tests when done.
3. Commit your changes and push: git push origin ${pr_branch}
4. Write: echo \"PHASE:awaiting_ci\" > \"${phase_file}\"
5. Stop and wait for the next CI result."
  fi

  [ -z "${inject_msg}" ] && return 0

  local inject_tmp
  inject_tmp=$(mktemp /tmp/review-inject-XXXXXX)
  printf '%s' "${inject_msg}" > "${inject_tmp}"
  tmux load-buffer -b "review-inject-${issue_num}" "${inject_tmp}"
  tmux paste-buffer -t "${session}" -b "review-inject-${issue_num}"
  sleep 0.5
  tmux send-keys -t "${session}" "" Enter
  tmux delete-buffer -b "review-inject-${issue_num}" 2>/dev/null || true
  rm -f "${inject_tmp}"
  log "  #${pr_num} review (${verdict}) injected into session ${session}"
}

while IFS= read -r line; do
  PR_NUM=$(echo "$line" | awk '{print $1}')
  PR_SHA=$(echo "$line" | awk '{print $2}')
  PR_BRANCH=$(echo "$line" | awk '{print $3}')

  CI_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API_BASE}/commits/${PR_SHA}/status" | jq -r '.state // "unknown"')

  # Skip if CI is running/failed. Allow "success" or no CI configured (empty/pending with no pipelines)
  if [ "$CI_STATE" != "success" ]; then
    # Projects without CI (woodpecker_repo_id=0) treat empty/pending as pass
    if [ "${WOODPECKER_REPO_ID:-2}" = "0" ] && { [ "$CI_STATE" = "" ] || [ "$CI_STATE" = "pending" ]; }; then
      : # no CI configured, proceed to review
    else
      log "  #${PR_NUM} CI=${CI_STATE}, skip"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi

  # Check formal Codeberg reviews (not comment markers)
  HAS_REVIEW=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API_BASE}/pulls/${PR_NUM}/reviews" | \
    jq -r --arg sha "$PR_SHA" \
    '[.[] | select(.commit_id == $sha) | select(.state != "COMMENT")] | length')

  if [ "${HAS_REVIEW:-0}" -gt "0" ]; then
    log "  #${PR_NUM} formal review exists for ${PR_SHA:0:7}, skip"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  log "  #${PR_NUM} needs review (CI=success, SHA=${PR_SHA:0:7})"

  if "${SCRIPT_DIR}/review-pr.sh" "$PR_NUM" 2>&1; then
    REVIEWED=$((REVIEWED + 1))
    inject_review_into_dev_session "$PR_NUM" "$PR_SHA" "$PR_BRANCH"
  else
    log "  #${PR_NUM} review failed"
    matrix_send "review" "❌ PR #${PR_NUM} review failed" 2>/dev/null || true
  fi

  if [ "$REVIEWED" -ge "$MAX_REVIEWS" ]; then
    log "Hit max reviews (${MAX_REVIEWS}), stopping"
    break
  fi

  sleep 2

done <<< "$PRS"

log "--- Poll done: ${REVIEWED} reviewed, ${SKIPPED} skipped ---"
