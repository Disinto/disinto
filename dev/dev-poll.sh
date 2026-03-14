#!/usr/bin/env bash
# dev-poll.sh — Pull-based factory: find the next ready issue and start dev-agent
#
# Pull system: issues labeled "backlog" are candidates. An issue is READY when
# ALL its dependency issues are closed AND their PRs are merged into master.
# No "todo" label needed — readiness is derived from reality.
#
# Priority:
#   1. Orphaned "in-progress" issues (agent died or PR needs attention)
#   2. Ready "backlog" issues (all deps merged)
#
# Usage: cron every 10min

set -euo pipefail

# Load shared environment
source "$(dirname "$0")/../lib/env.sh"


REPO="${CODEBERG_REPO}"

API="${CODEBERG_API}"
LOCKFILE="/tmp/dev-agent.lock"
LOGFILE="${FACTORY_ROOT}/dev/dev-agent.log"
PREFLIGHT_RESULT="/tmp/dev-agent-preflight.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
  printf '[%s] poll: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

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

  # Issue closed = dep satisfied. The factory only closes issues after
  # merging, so closed state is trustworthy. No need to hunt for the
  # specific PR — that was over-engineering that caused false negatives.
  return 0
}

# =============================================================================
# HELPER: extract dependency numbers from issue body
# =============================================================================
get_deps() {
  local issue_body="$1"
  # Extract #NNN references from "Depends on" / "Blocked by" sections
  # Capture the header line AND subsequent lines until next ## section
  {
    echo "$issue_body" | awk '
      BEGIN { IGNORECASE=1 }
      /^##? *(Depends on|Blocked by|Dependencies)/ { capture=1; next }
      capture && /^##? / { capture=0 }
      capture { print }
    ' | grep -oP '#\K[0-9]+' || true
    # Also check inline deps on same line as keyword
    echo "$issue_body" | grep -iE '(depends on|blocked by)' | grep -oP '#\K[0-9]+' || true
  } | sort -un
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

    # Check formal reviews
    HAS_APPROVE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${HAS_PR}/reviews" | \
      jq -r '[.[] | select(.state == "APPROVED") | select(.stale == false)] | length') || true
    HAS_CHANGES=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${HAS_PR}/reviews" | \
      jq -r '[.[] | select(.state == "REQUEST_CHANGES") | select(.stale == false)] | length') || true

    if [ "$CI_STATE" = "success" ] && [ "${HAS_APPROVE:-0}" -gt 0 ]; then
      log "PR #${HAS_PR} approved + CI green → merging"
      MERGE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/pulls/${HAS_PR}/merge" \
        -d '{"Do":"merge","delete_branch_after_merge":true}')

      if [ "$MERGE_CODE" = "200" ] || [ "$MERGE_CODE" = "204" ] ; then
        log "PR #${HAS_PR} merged! Closing #${ISSUE_NUM}"
        curl -sf -X PATCH -H "Authorization: token ${CODEBERG_TOKEN}" \
          -H "Content-Type: application/json" \
          "${API}/issues/${ISSUE_NUM}" -d '{"state":"closed"}' >/dev/null 2>&1 || true
        curl -sf -X DELETE -H "Authorization: token ${CODEBERG_TOKEN}" \
          "${API}/issues/${ISSUE_NUM}/labels/in-progress" >/dev/null 2>&1 || true
        openclaw system event --text "✅ PR #${HAS_PR} merged! Issue #${ISSUE_NUM} done." --mode now 2>/dev/null || true
      else
        log "merge failed (HTTP ${MERGE_CODE})"
      fi
      exit 0

    elif [ "$CI_STATE" = "success" ] && [ "${HAS_CHANGES:-0}" -gt 0 ]; then
      log "issue #${ISSUE_NUM} PR #${HAS_PR} has REQUEST_CHANGES — spawning agent"
      nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
      log "started dev-agent PID $! for issue #${ISSUE_NUM} (review fix)"
      exit 0

    elif [ "$CI_STATE" = "failure" ] || [ "$CI_STATE" = "error" ]; then
      log "issue #${ISSUE_NUM} PR #${HAS_PR} CI failed — spawning agent to fix"
      nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
      log "started dev-agent PID $! for issue #${ISSUE_NUM} (CI fix)"
      exit 0

    else
      log "issue #${ISSUE_NUM} has open PR #${HAS_PR} (CI: ${CI_STATE}, waiting)"
    fi
  else
    log "recovering orphaned issue #${ISSUE_NUM} (no PR found)"
    nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
    log "started dev-agent PID $! for issue #${ISSUE_NUM} (recovery)"
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

  # Extract issue number from branch name (fix/issue-NNN)
  STUCK_ISSUE=$(echo "$PR_BRANCH" | grep -oP '(?<=fix/issue-)\d+' || true)
  [ -z "$STUCK_ISSUE" ] && continue

  CI_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/commits/${PR_SHA}/status" | jq -r '.state // "unknown"') || true
  HAS_CHANGES=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls/${PR_NUM}/reviews" | \
    jq -r '[.[] | select(.state == "REQUEST_CHANGES") | select(.stale == false)] | length') || true
  HAS_APPROVE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls/${PR_NUM}/reviews" | \
    jq -r '[.[] | select(.state == "APPROVED") | select(.stale == false)] | length') || true

  # Try merge if approved + CI green
  if [ "$CI_STATE" = "success" ] && [ "${HAS_APPROVE:-0}" -gt 0 ]; then
    log "PR #${PR_NUM} (issue #${STUCK_ISSUE}) approved + CI green → merging"
    MERGE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/pulls/${PR_NUM}/merge" \
      -d '{"Do":"merge","delete_branch_after_merge":true}')
    if [ "$MERGE_CODE" = "200" ] || [ "$MERGE_CODE" = "204" ]; then
      log "PR #${PR_NUM} merged! Closing #${STUCK_ISSUE}"
      curl -sf -X PATCH -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/issues/${STUCK_ISSUE}" -d '{"state":"closed"}' >/dev/null 2>&1 || true
      openclaw system event --text "✅ PR #${PR_NUM} merged! Issue #${STUCK_ISSUE} done." --mode now 2>/dev/null || true
    fi
    continue
  fi

  # Stuck: REQUEST_CHANGES or CI failure → spawn agent
  if [ "$CI_STATE" = "success" ] && [ "${HAS_CHANGES:-0}" -gt 0 ]; then
    log "PR #${PR_NUM} (issue #${STUCK_ISSUE}) has REQUEST_CHANGES — fixing first"
    nohup "${SCRIPT_DIR}/dev-agent.sh" "$STUCK_ISSUE" >> "$LOGFILE" 2>&1 &
    log "started dev-agent PID $! for stuck PR #${PR_NUM}"
    exit 0
  elif [ "$CI_STATE" = "failure" ] || [ "$CI_STATE" = "error" ]; then
    log "PR #${PR_NUM} (issue #${STUCK_ISSUE}) CI failed — fixing first"
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
  "${API}/issues?state=open&labels=backlog&limit=20&type=issues")

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
    HAS_APPROVE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${EXISTING_PR}/reviews" | \
      jq -r '[.[] | select(.state == "APPROVED") | select(.stale == false)] | length') || true
    HAS_CHANGES=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${EXISTING_PR}/reviews" | \
      jq -r '[.[] | select(.state == "REQUEST_CHANGES") | select(.stale == false)] | length') || true

    if [ "$CI_STATE" = "success" ] && [ "${HAS_APPROVE:-0}" -gt 0 ]; then
      log "#${ISSUE_NUM} PR #${EXISTING_PR} approved + CI green → merging"
      MERGE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/pulls/${EXISTING_PR}/merge" \
        -d '{"Do":"merge","delete_branch_after_merge":true}')
      if [ "$MERGE_CODE" = "200" ] || [ "$MERGE_CODE" = "204" ] ; then
        log "PR #${EXISTING_PR} merged! Closing #${ISSUE_NUM}"
        curl -sf -X PATCH -H "Authorization: token ${CODEBERG_TOKEN}" \
          -H "Content-Type: application/json" \
          "${API}/issues/${ISSUE_NUM}" -d '{"state":"closed"}' >/dev/null 2>&1 || true
        openclaw system event --text "✅ PR #${EXISTING_PR} merged! Issue #${ISSUE_NUM} done." --mode now 2>/dev/null || true
      fi
      continue

    elif [ "${HAS_CHANGES:-0}" -gt 0 ]; then
      log "#${ISSUE_NUM} PR #${EXISTING_PR} has REQUEST_CHANGES — picking up"
      READY_ISSUE="$ISSUE_NUM"
      break

    elif [ "$CI_STATE" = "failure" ] || [ "$CI_STATE" = "error" ]; then
      log "#${ISSUE_NUM} PR #${EXISTING_PR} CI failed — picking up"
      READY_ISSUE="$ISSUE_NUM"
      break

    else
      log "#${ISSUE_NUM} PR #${EXISTING_PR} exists (CI: ${CI_STATE}, waiting)"
      continue
    fi
  fi

  READY_ISSUE="$ISSUE_NUM"
  log "#${ISSUE_NUM} is READY (all deps merged, no existing PR)"
  break
done

if [ -z "$READY_ISSUE" ]; then
  log "no ready issues (all blocked by unmerged deps)"
  exit 0
fi

# =============================================================================
# LAUNCH: start dev-agent for the ready issue
# =============================================================================
log "launching dev-agent for #${READY_ISSUE}"
rm -f "$PREFLIGHT_RESULT"

nohup "${SCRIPT_DIR}/dev-agent.sh" "$READY_ISSUE" >> "$LOGFILE" 2>&1 &
AGENT_PID=$!

# Wait briefly for preflight (agent writes result before claiming)
for w in $(seq 1 30); do
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
        -d '{"labels":["underspecified"]}' >/dev/null 2>&1 || true
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
