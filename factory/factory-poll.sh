#!/usr/bin/env bash
# factory-poll.sh — Factory supervisor: bash checks + claude -p for fixes
#
# Runs every 10min via cron. Does all health checks in bash (zero tokens).
# Only invokes claude -p when intervention is needed.
#
# Cron: */10 * * * * /path/to/dark-factory/factory/factory-poll.sh
#
# Peek:  cat /tmp/factory-status
# Log:   tail -f /path/to/dark-factory/factory/factory.log

source "$(dirname "$0")/../lib/env.sh"

LOGFILE="${FACTORY_ROOT}/factory/factory.log"
STATUSFILE="/tmp/factory-status"
LOCKFILE="/tmp/factory-poll.lock"

# Prevent overlapping runs
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
  if kill -0 "$LOCK_PID" 2>/dev/null; then
    exit 0
  fi
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE" "$STATUSFILE"' EXIT

status() {
  printf '[%s] factory: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" > "$STATUSFILE"
  log "$*" >> "$LOGFILE"
}

ALERTS=""
alert() {
  ALERTS="${ALERTS}• $*\n"
  log "ALERT: $*" >> "$LOGFILE"
}

# =============================================================================
# CHECK 1: Stuck/failed CI pipelines
# =============================================================================
status "checking CI"

STUCK_CI=$(wpdb -c "SELECT count(*) FROM pipelines WHERE repo_id=2 AND status='running' AND EXTRACT(EPOCH FROM now() - to_timestamp(started)) > 1200;" 2>/dev/null | xargs)
[ "${STUCK_CI:-0}" -gt 0 ] && alert "CI: ${STUCK_CI} pipeline(s) running >20min"

PENDING_CI=$(wpdb -c "SELECT count(*) FROM pipelines WHERE repo_id=2 AND status='pending' AND EXTRACT(EPOCH FROM now() - to_timestamp(created)) > 1800;" 2>/dev/null | xargs)
[ "${PENDING_CI:-0}" -gt 0 ] && alert "CI: ${PENDING_CI} pipeline(s) pending >30min"

# =============================================================================
# CHECK 2: Derailed PRs — open with CI failure + no push in 30min
# =============================================================================
status "checking PRs"

OPEN_PRS=$(codeberg_api GET "/pulls?state=open&limit=10" 2>/dev/null | jq -r '.[].number' 2>/dev/null || true)
for pr in $OPEN_PRS; do
  PR_SHA=$(codeberg_api GET "/pulls/${pr}" 2>/dev/null | jq -r '.head.sha' 2>/dev/null || true)
  [ -z "$PR_SHA" ] && continue

  CI_STATE=$(codeberg_api GET "/commits/${PR_SHA}/status" 2>/dev/null | jq -r '.state // "unknown"' 2>/dev/null || true)
  if [ "$CI_STATE" = "failure" ] || [ "$CI_STATE" = "error" ]; then
    # Check when last push happened
    UPDATED=$(codeberg_api GET "/pulls/${pr}" 2>/dev/null | jq -r '.updated_at // ""' 2>/dev/null || true)
    if [ -n "$UPDATED" ]; then
      UPDATED_EPOCH=$(date -d "$UPDATED" +%s 2>/dev/null || echo 0)
      NOW_EPOCH=$(date +%s)
      AGE_MIN=$(( (NOW_EPOCH - UPDATED_EPOCH) / 60 ))
      if [ "$AGE_MIN" -gt 30 ]; then
        alert "PR #${pr}: CI=${CI_STATE}, no activity for ${AGE_MIN}min"
      fi
    fi
  fi
done

# =============================================================================
# CHECK 3: Dev-agent health
# =============================================================================
status "checking dev-agent"

DEV_LOCK="/tmp/dev-agent.lock"
if [ -f "$DEV_LOCK" ]; then
  DEV_PID=$(cat "$DEV_LOCK" 2>/dev/null)
  if ! kill -0 "$DEV_PID" 2>/dev/null; then
    alert "Dev-agent: lock file exists but PID ${DEV_PID} is dead (stale lock)"
  else
    # Check if it's making progress — same status for >30min?
    DEV_STATUS=$(cat /tmp/dev-agent-status 2>/dev/null || echo "")
    DEV_STATUS_AGE=$(stat -c %Y /tmp/dev-agent-status 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    STATUS_AGE_MIN=$(( (NOW_EPOCH - DEV_STATUS_AGE) / 60 ))
    if [ "$STATUS_AGE_MIN" -gt 30 ]; then
      alert "Dev-agent: status unchanged for ${STATUS_AGE_MIN}min — possibly stuck"
    fi
  fi
fi

# =============================================================================
# CHECK 4: Git repo health
# =============================================================================
status "checking git repo"

cd "${HARB_REPO_ROOT}" 2>/dev/null || true
GIT_STATUS=$(git status --porcelain 2>/dev/null | wc -l)
GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
GIT_REBASE=$([ -d .git/rebase-merge ] || [ -d .git/rebase-apply ] && echo "yes" || echo "no")

if [ "$GIT_REBASE" = "yes" ]; then
  alert "Git: stale rebase in progress on main repo"
fi
if [ "$GIT_BRANCH" != "master" ]; then
  alert "Git: main repo on branch '${GIT_BRANCH}' instead of master"
fi

# =============================================================================
# CHECK 5: Infra — RAM, swap, disk, docker
# =============================================================================
status "checking infra"

AVAIL_MB=$(free -m | awk '/Mem:/{print $7}')
SWAP_USED_MB=$(free -m | awk '/Swap:/{print $3}')
DISK_PERCENT=$(df -h / | awk 'NR==2{print $5}' | tr -d '%')

if [ "${AVAIL_MB:-0}" -lt 500 ]; then
  alert "RAM: only ${AVAIL_MB}MB available"
fi
if [ "${SWAP_USED_MB:-0}" -gt 3000 ]; then
  alert "Swap: ${SWAP_USED_MB}MB used (>3GB)"
fi
if [ "${DISK_PERCENT:-0}" -gt 85 ]; then
  alert "Disk: ${DISK_PERCENT}% full"
fi

# Check if Anvil is responsive
ANVIL_OK=$(curl -sf -m 5 -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://localhost:8545 2>/dev/null | jq -r '.result // "fail"' 2>/dev/null || echo "fail")
if [ "$ANVIL_OK" = "fail" ]; then
  # Try to auto-fix
  sudo docker restart harb-anvil-1 2>/dev/null && \
    log "Auto-fixed: restarted frozen Anvil" >> "$LOGFILE" || \
    alert "Anvil: unresponsive and restart failed"
fi

# =============================================================================
# CHECK 6: Review bot — unreviewed PRs older than 1h
# =============================================================================
status "checking review backlog"

for pr in $OPEN_PRS; do
  PR_SHA=$(codeberg_api GET "/pulls/${pr}" 2>/dev/null | jq -r '.head.sha' 2>/dev/null || true)
  [ -z "$PR_SHA" ] && continue

  CI_STATE=$(codeberg_api GET "/commits/${PR_SHA}/status" 2>/dev/null | jq -r '.state // "unknown"' 2>/dev/null || true)
  [ "$CI_STATE" != "success" ] && continue

  # CI passed — check if reviewed at this SHA
  HAS_REVIEW=$(codeberg_api GET "/issues/${pr}/comments?limit=50" 2>/dev/null | \
    jq -r --arg sha "$PR_SHA" '[.[] | select(.body | contains("<!-- reviewed: " + $sha))] | length' 2>/dev/null || echo "0")

  if [ "${HAS_REVIEW:-0}" -eq 0 ]; then
    PR_UPDATED=$(codeberg_api GET "/pulls/${pr}" 2>/dev/null | jq -r '.updated_at // ""' 2>/dev/null || true)
    if [ -n "$PR_UPDATED" ]; then
      UPDATED_EPOCH=$(date -d "$PR_UPDATED" +%s 2>/dev/null || echo 0)
      NOW_EPOCH=$(date +%s)
      AGE_MIN=$(( (NOW_EPOCH - UPDATED_EPOCH) / 60 ))
      if [ "$AGE_MIN" -gt 60 ]; then
        alert "PR #${pr}: CI passed but no review for ${AGE_MIN}min"
        # Auto-trigger review
        bash "${FACTORY_ROOT}/review/review-pr.sh" "$pr" >> "$LOGFILE" 2>&1 &
        log "Auto-triggered review for PR #${pr}" >> "$LOGFILE"
      fi
    fi
  fi
done

# =============================================================================
# RESULT: escalate or all clear
# =============================================================================

if [ -n "$ALERTS" ]; then
  log "$(echo -e "$ALERTS")" >> "$LOGFILE"

  # Determine if claude -p is needed (complex issues) or just notify
  NEEDS_CLAUDE=false

  # For now: notify via openclaw system event, let Clawy decide
  ALERT_TEXT=$(echo -e "$ALERTS")
  openclaw system event --text "🏭 Factory Alert:\n${ALERT_TEXT}" --mode now 2>/dev/null || true

  status "alerts sent"
else
  log "all clear" >> "$LOGFILE"
  status "all clear"
fi
