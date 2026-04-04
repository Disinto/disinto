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

# --- Clean up stale review sessions (.sid files + worktrees) ---
# Remove .sid files, phase files, and worktrees for merged/closed PRs or idle > 4h
REVIEW_SIDS=$(compgen -G "/tmp/review-session-${PROJECT_NAME}-*.sid" 2>/dev/null || true)
if [ -n "$REVIEW_SIDS" ]; then
  while IFS= read -r sid_file; do
    base=$(basename "$sid_file")
    pr_num="${base#review-session-"${PROJECT_NAME}"-}"
    pr_num="${pr_num%.sid}"
    phase_file="/tmp/review-session-${PROJECT_NAME}-${pr_num}.phase"
    worktree="/tmp/${PROJECT_NAME}-review-${pr_num}"

    # Check if PR is still open
    pr_state=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API_BASE}/pulls/${pr_num}" | jq -r '.state // "unknown"' 2>/dev/null) || true

    if [ "$pr_state" != "open" ]; then
      log "cleanup: PR #${pr_num} state=${pr_state} — removing sid/worktree"
      rm -f "$sid_file" "$phase_file" "/tmp/${PROJECT_NAME}-review-output-${pr_num}.json"
      cd "$REPO_ROOT"
      git worktree remove "$worktree" --force 2>/dev/null || true
      rm -rf "$worktree" 2>/dev/null || true
      continue
    fi

    # Check idle timeout (4h) via .sid file mtime
    sid_mtime=$(stat -c %Y "$sid_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ "$sid_mtime" -gt 0 ] && [ $(( now - sid_mtime )) -gt "$REVIEW_IDLE_TIMEOUT" ]; then
      log "cleanup: PR #${pr_num} idle > 4h — removing sid/worktree"
      rm -f "$sid_file" "$phase_file" "/tmp/${PROJECT_NAME}-review-output-${pr_num}.json"
      cd "$REPO_ROOT"
      git worktree remove "$worktree" --force 2>/dev/null || true
      rm -rf "$worktree" 2>/dev/null || true
      continue
    fi
  done <<< "$REVIEW_SIDS"
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

# --- Re-review: trigger review for .sid files in awaiting_changes state with new commits ---
if [ -n "$REVIEW_SIDS" ]; then
  while IFS= read -r sid_file; do
    base=$(basename "$sid_file")
    pr_num="${base#review-session-"${PROJECT_NAME}"-}"
    pr_num="${pr_num%.sid}"
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
    else
      log "  #${pr_num} re-review failed"
    fi

    [ "$REVIEWED" -lt "$MAX_REVIEWS" ] || break
  done <<< "$REVIEW_SIDS"
fi

while IFS= read -r line; do
  PR_NUM=$(echo "$line" | awk '{print $1}')
  PR_SHA=$(echo "$line" | awk '{print $2}')

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
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  log "  #${PR_NUM} needs review (CI=success, SHA=${PR_SHA:0:7})"

  # Circuit breaker: count existing review-error comments for this SHA
  ERROR_COMMENTS=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API_BASE}/issues/${PR_NUM}/comments" | \
    jq --arg sha "$PR_SHA" \
    '[.[] | select(.body | contains("<!-- review-error: " + $sha + " -->"))] | length')

  if [ "${ERROR_COMMENTS:-0}" -ge 3 ]; then
    log "  #${PR_NUM} blocked: ${ERROR_COMMENTS} consecutive error comments for ${PR_SHA:0:7}, skipping"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  log "  #${PR_NUM} error check: ${ERROR_COMMENTS:-0} prior error(s) for ${PR_SHA:0:7}"

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
