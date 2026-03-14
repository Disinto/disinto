#!/usr/bin/env bash
# review-poll.sh — Poll open PRs and review those with green CI
#
# Peek while running:  cat /tmp/<project>-review-status
# Full log:            tail -f <factory-root>/review/review.log

set -euo pipefail

# Load shared environment
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
  jq -r --arg branch "${PRIMARY_BRANCH}" '.[] | select(.base.ref == $branch) | select(.draft != true) | select(.title | test("^\\[?WIP[\\]:]"; "i") | not) | "\(.number) \(.head.sha)"')

if [ -z "$PRS" ]; then
  log "No open PRs targeting ${PRIMARY_BRANCH}"
  exit 0
fi

TOTAL=$(echo "$PRS" | wc -l)
log "Found ${TOTAL} open PRs"

REVIEWED=0
SKIPPED=0

while IFS= read -r line; do
  PR_NUM=$(echo "$line" | awk '{print $1}')
  PR_SHA=$(echo "$line" | awk '{print $2}')

  CI_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API_BASE}/commits/${PR_SHA}/status" | jq -r '.state // "unknown"')

  if [ "$CI_STATE" != "success" ]; then
    log "  #${PR_NUM} CI=${CI_STATE}, skip"
    SKIPPED=$((SKIPPED + 1))
    continue
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
