#!/usr/bin/env bash
# factory-poll.sh — Factory supervisor: bash checks + claude -p for fixes
#
# Runs every 10min via cron. Does all health checks in bash (zero tokens).
# Only invokes claude -p when auto-fix fails or issue is complex.
#
# Cron: */10 * * * * /path/to/dark-factory/factory/factory-poll.sh
#
# Peek:  cat /tmp/factory-status
# Log:   tail -f /path/to/dark-factory/factory/factory.log

source "$(dirname "$0")/../lib/env.sh"

LOGFILE="${FACTORY_ROOT}/factory/factory.log"
STATUSFILE="/tmp/factory-status"
LOCKFILE="/tmp/factory-poll.lock"
PROMPT_FILE="${FACTORY_ROOT}/factory/PROMPT.md"

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

flog() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

status() {
  printf '[%s] factory: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" > "$STATUSFILE"
  flog "$*"
}

# ── Check for escalation replies from Matrix ──────────────────────────────
ESCALATION_REPLY=""
if [ -s /tmp/factory-escalation-reply ]; then
  ESCALATION_REPLY=$(cat /tmp/factory-escalation-reply)
  rm -f /tmp/factory-escalation-reply
  flog "Got escalation reply: $(echo "$ESCALATION_REPLY" | head -1)"
fi

# Alerts by priority
P0_ALERTS=""
P1_ALERTS=""
P2_ALERTS=""
P3_ALERTS=""
P4_ALERTS=""

p0() { P0_ALERTS="${P0_ALERTS}• [P0] $*\n"; flog "P0: $*"; }
p1() { P1_ALERTS="${P1_ALERTS}• [P1] $*\n"; flog "P1: $*"; }
p2() { P2_ALERTS="${P2_ALERTS}• [P2] $*\n"; flog "P2: $*"; }
p3() { P3_ALERTS="${P3_ALERTS}• [P3] $*\n"; flog "P3: $*"; }
p4() { P4_ALERTS="${P4_ALERTS}• [P4] $*\n"; flog "P4: $*"; }

FIXES=""
fixed() { FIXES="${FIXES}• ✅ $*\n"; flog "FIXED: $*"; }

# =============================================================================
# P0: MEMORY — check first, fix first
# =============================================================================
status "P0: checking memory"

AVAIL_MB=$(free -m | awk '/Mem:/{print $7}')
SWAP_USED_MB=$(free -m | awk '/Swap:/{print $3}')

if [ "${AVAIL_MB:-9999}" -lt 500 ] || { [ "${SWAP_USED_MB:-0}" -gt 3000 ] && [ "${AVAIL_MB:-9999}" -lt 2000 ]; }; then
  flog "MEMORY CRISIS: avail=${AVAIL_MB}MB swap_used=${SWAP_USED_MB}MB — auto-fixing"

  # Kill stale claude processes (>3h old)
  STALE_CLAUDES=$(pgrep -f "claude" --older 10800 2>/dev/null || true)
  if [ -n "$STALE_CLAUDES" ]; then
    echo "$STALE_CLAUDES" | xargs kill 2>/dev/null || true
    fixed "Killed stale claude processes: ${STALE_CLAUDES}"
  fi

  # Drop filesystem caches
  sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
  fixed "Dropped filesystem caches"

  # Restart Anvil if it's bloated (>1GB RSS)
  ANVIL_CONTAINER="${ANVIL_CONTAINER:-${PROJECT_NAME}-anvil-1}"
  ANVIL_RSS=$(sudo docker stats "$ANVIL_CONTAINER" --no-stream --format '{{.MemUsage}}' 2>/dev/null | grep -oP '^\S+' | head -1 || echo "0")
  if echo "$ANVIL_RSS" | grep -qP '\dGiB'; then
    sudo docker restart "$ANVIL_CONTAINER" >/dev/null 2>&1 && fixed "Restarted bloated Anvil (${ANVIL_RSS})"
  fi

  # Re-check after fixes
  AVAIL_MB_AFTER=$(free -m | awk '/Mem:/{print $7}')
  SWAP_AFTER=$(free -m | awk '/Swap:/{print $3}')

  if [ "${AVAIL_MB_AFTER:-0}" -lt 500 ] || [ "${SWAP_AFTER:-0}" -gt 3000 ]; then
    p0 "Memory still critical after auto-fix: avail=${AVAIL_MB_AFTER}MB swap=${SWAP_AFTER}MB"
  else
    flog "Memory recovered: avail=${AVAIL_MB_AFTER}MB swap=${SWAP_AFTER}MB"
  fi
fi

# =============================================================================
# P1: DISK
# =============================================================================
status "P1: checking disk"

DISK_PERCENT=$(df -h / | awk 'NR==2{print $5}' | tr -d '%')

if [ "${DISK_PERCENT:-0}" -gt 80 ]; then
  flog "DISK PRESSURE: ${DISK_PERCENT}% — auto-cleaning"

  # Docker cleanup (safe — keeps images)
  sudo docker system prune -f >/dev/null 2>&1 && fixed "Docker prune"

  # Truncate factory logs >10MB
  for logfile in "${FACTORY_ROOT}"/{dev,review,factory}/*.log; do
    if [ -f "$logfile" ]; then
      SIZE_KB=$(du -k "$logfile" 2>/dev/null | cut -f1)
      if [ "${SIZE_KB:-0}" -gt 10240 ]; then
        truncate -s 0 "$logfile"
        fixed "Truncated $(basename "$logfile") (was ${SIZE_KB}KB)"
      fi
    fi
  done

  # Clean old worktrees
  IDLE_WORKTREES=$(find /tmp/${PROJECT_NAME}-worktree-* -maxdepth 0 -mmin +360 2>/dev/null || true)
  if [ -n "$IDLE_WORKTREES" ]; then
    cd "${PROJECT_REPO_ROOT}" && git worktree prune 2>/dev/null
    for wt in $IDLE_WORKTREES; do
      # Only remove if dev-agent is not running on it
      ISSUE_NUM=$(basename "$wt" | sed "s/${PROJECT_NAME}-worktree-//")
      if ! pgrep -f "dev-agent.sh ${ISSUE_NUM}" >/dev/null 2>&1; then
        rm -rf "$wt" && fixed "Removed stale worktree: $wt"
      fi
    done
  fi

  # Woodpecker log_entries cleanup
  LOG_ENTRIES_MB=$(wpdb -c "SELECT pg_size_pretty(pg_total_relation_size('log_entries'));" 2>/dev/null | xargs)
  if echo "$LOG_ENTRIES_MB" | grep -qP '\d+\s*(GB|MB)'; then
    SIZE_NUM=$(echo "$LOG_ENTRIES_MB" | grep -oP '\d+')
    SIZE_UNIT=$(echo "$LOG_ENTRIES_MB" | grep -oP '(GB|MB)')
    if [ "$SIZE_UNIT" = "GB" ] || { [ "$SIZE_UNIT" = "MB" ] && [ "$SIZE_NUM" -gt 500 ]; }; then
      wpdb -c "DELETE FROM log_entries WHERE id < (SELECT max(id) - 100000 FROM log_entries);" 2>/dev/null
      fixed "Trimmed Woodpecker log_entries (was ${LOG_ENTRIES_MB})"
    fi
  fi

  DISK_AFTER=$(df -h / | awk 'NR==2{print $5}' | tr -d '%')
  if [ "${DISK_AFTER:-0}" -gt 80 ]; then
    p1 "Disk still ${DISK_AFTER}% after auto-clean"
  else
    flog "Disk recovered: ${DISK_AFTER}%"
  fi
fi

# =============================================================================
# P2: FACTORY STOPPED — CI, dev-agent, git
# =============================================================================
status "P2: checking factory"

# CI stuck
STUCK_CI=$(wpdb -c "SELECT count(*) FROM pipelines WHERE repo_id=${WOODPECKER_REPO_ID} AND status='running' AND EXTRACT(EPOCH FROM now() - to_timestamp(started)) > 1200;" 2>/dev/null | xargs || true)
[ "${STUCK_CI:-0}" -gt 0 ] 2>/dev/null && p2 "CI: ${STUCK_CI} pipeline(s) running >20min"

PENDING_CI=$(wpdb -c "SELECT count(*) FROM pipelines WHERE repo_id=${WOODPECKER_REPO_ID} AND status='pending' AND EXTRACT(EPOCH FROM now() - to_timestamp(created)) > 1800;" 2>/dev/null | xargs || true)
[ "${PENDING_CI:-0}" -gt 0 ] && p2 "CI: ${PENDING_CI} pipeline(s) pending >30min"

# Dev-agent health
DEV_LOCK="/tmp/dev-agent.lock"
if [ -f "$DEV_LOCK" ]; then
  DEV_PID=$(cat "$DEV_LOCK" 2>/dev/null)
  if ! kill -0 "$DEV_PID" 2>/dev/null; then
    rm -f "$DEV_LOCK"
    fixed "Removed stale dev-agent lock (PID ${DEV_PID} dead)"
  else
    DEV_STATUS_AGE=$(stat -c %Y /tmp/dev-agent-status 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    STATUS_AGE_MIN=$(( (NOW_EPOCH - DEV_STATUS_AGE) / 60 ))
    if [ "$STATUS_AGE_MIN" -gt 30 ]; then
      p2 "Dev-agent: status unchanged for ${STATUS_AGE_MIN}min"
    fi
  fi
fi

# Git repo health
cd "${PROJECT_REPO_ROOT}" 2>/dev/null || true
GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
GIT_REBASE=$([ -d .git/rebase-merge ] || [ -d .git/rebase-apply ] && echo "yes" || echo "no")

if [ "$GIT_REBASE" = "yes" ]; then
  git rebase --abort 2>/dev/null && git checkout "${PRIMARY_BRANCH}" 2>/dev/null && \
    fixed "Aborted stale rebase, switched to ${PRIMARY_BRANCH}" || \
    p2 "Git: stale rebase, auto-abort failed"
fi
if [ "$GIT_BRANCH" != "${PRIMARY_BRANCH}" ] && [ "$GIT_BRANCH" != "unknown" ]; then
  git checkout "${PRIMARY_BRANCH}" 2>/dev/null && \
    fixed "Switched main repo from '${GIT_BRANCH}' to ${PRIMARY_BRANCH}" || \
    p2 "Git: on '${GIT_BRANCH}' instead of ${PRIMARY_BRANCH}"
fi

# =============================================================================
# P2b: FACTORY STALLED — backlog exists but no agent running
# =============================================================================
status "P2: checking factory stall"

BACKLOG_COUNT=$(codeberg_api GET "/issues?state=open&labels=backlog&type=issues&limit=1" 2>/dev/null | jq -r 'length' 2>/dev/null || echo "0")
IN_PROGRESS=$(codeberg_api GET "/issues?state=open&labels=in-progress&type=issues&limit=1" 2>/dev/null | jq -r 'length' 2>/dev/null || echo "0")

if [ "${BACKLOG_COUNT:-0}" -gt 0 ] && [ "${IN_PROGRESS:-0}" -eq 0 ]; then
  # Backlog exists but nothing in progress — check if dev-agent ran recently
  DEV_LOG="${FACTORY_ROOT}/dev/dev-agent.log"
  if [ -f "$DEV_LOG" ]; then
    LAST_LOG_EPOCH=$(stat -c %Y "$DEV_LOG" 2>/dev/null || echo 0)
  else
    LAST_LOG_EPOCH=0
  fi
  NOW_EPOCH=$(date +%s)
  IDLE_MIN=$(( (NOW_EPOCH - LAST_LOG_EPOCH) / 60 ))

  if [ "$IDLE_MIN" -gt 20 ]; then
    p2 "Factory stalled: ${BACKLOG_COUNT} backlog issue(s), no agent ran for ${IDLE_MIN}min"
  fi
fi

# =============================================================================
# P3: FACTORY DEGRADED — derailed PRs, unreviewed PRs
# =============================================================================
status "P3: checking PRs"

OPEN_PRS=$(codeberg_api GET "/pulls?state=open&limit=10" 2>/dev/null | jq -r '.[].number' 2>/dev/null || true)
for pr in $OPEN_PRS; do
  PR_JSON=$(codeberg_api GET "/pulls/${pr}" 2>/dev/null || true)
  [ -z "$PR_JSON" ] && continue
  PR_SHA=$(echo "$PR_JSON" | jq -r '.head.sha // ""')
  [ -z "$PR_SHA" ] && continue

  CI_STATE=$(codeberg_api GET "/commits/${PR_SHA}/status" 2>/dev/null | jq -r '.state // "unknown"' 2>/dev/null || true)

  # Check for merge conflicts first (approved + CI pass but unmergeable)
  MERGEABLE=$(echo "$PR_JSON" | jq -r '.mergeable // true')
  if [ "$MERGEABLE" = "false" ] && [ "$CI_STATE" = "success" ]; then
    p3 "PR #${pr}: CI pass but merge conflict — needs rebase"
  elif [ "$CI_STATE" = "failure" ] || [ "$CI_STATE" = "error" ]; then
    UPDATED=$(echo "$PR_JSON" | jq -r '.updated_at // ""')
    if [ -n "$UPDATED" ]; then
      UPDATED_EPOCH=$(date -d "$UPDATED" +%s 2>/dev/null || echo 0)
      NOW_EPOCH=$(date +%s)
      AGE_MIN=$(( (NOW_EPOCH - UPDATED_EPOCH) / 60 ))
      [ "$AGE_MIN" -gt 30 ] && p3 "PR #${pr}: CI=${CI_STATE}, stale ${AGE_MIN}min"
    fi
  elif [ "$CI_STATE" = "success" ]; then
    # Check if reviewed at this SHA
    HAS_REVIEW=$(codeberg_api GET "/issues/${pr}/comments?limit=50" 2>/dev/null | \
      jq -r --arg sha "$PR_SHA" '[.[] | select(.body | contains("<!-- reviewed: " + $sha))] | length' 2>/dev/null || echo "0")

    if [ "${HAS_REVIEW:-0}" -eq 0 ]; then
      UPDATED=$(echo "$PR_JSON" | jq -r '.updated_at // ""')
      if [ -n "$UPDATED" ]; then
        UPDATED_EPOCH=$(date -d "$UPDATED" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        AGE_MIN=$(( (NOW_EPOCH - UPDATED_EPOCH) / 60 ))
        if [ "$AGE_MIN" -gt 60 ]; then
          p3 "PR #${pr}: CI passed, no review for ${AGE_MIN}min"
          # Auto-trigger review
          bash "${FACTORY_ROOT}/review/review-pr.sh" "$pr" >> "${FACTORY_ROOT}/review/review.log" 2>&1 &
          fixed "Auto-triggered review for PR #${pr}"
        fi
      fi
    fi
  fi
done

# =============================================================================
# P4: HOUSEKEEPING — stale processes
# =============================================================================
# Check for dev-agent escalations
ESCALATION_FILE="${FACTORY_ROOT}/factory/escalations.jsonl"
if [ -s "$ESCALATION_FILE" ]; then
  ESCALATION_COUNT=$(wc -l < "$ESCALATION_FILE")
  p3 "Dev-agent escalated ${ESCALATION_COUNT} issue(s) — see ${ESCALATION_FILE}"
fi

status "P4: housekeeping"

# Stale claude processes (>3h, not caught by P0)
STALE_CLAUDES=$(pgrep -f "claude" --older 10800 2>/dev/null || true)
if [ -n "$STALE_CLAUDES" ]; then
  echo "$STALE_CLAUDES" | xargs kill 2>/dev/null || true
  fixed "Killed stale claude processes: $(echo $STALE_CLAUDES | wc -w) procs"
fi

# Rotate factory log if >5MB
for logfile in "${FACTORY_ROOT}"/{dev,review,factory}/*.log; do
  if [ -f "$logfile" ]; then
    SIZE_KB=$(du -k "$logfile" 2>/dev/null | cut -f1)
    if [ "${SIZE_KB:-0}" -gt 5120 ]; then
      mv "$logfile" "${logfile}.old" 2>/dev/null
      fixed "Rotated $(basename "$logfile")"
    fi
  fi
done

# =============================================================================
# RESULT
# =============================================================================

ALL_ALERTS="${P0_ALERTS}${P1_ALERTS}${P2_ALERTS}${P3_ALERTS}${P4_ALERTS}"

if [ -n "$ALL_ALERTS" ]; then
  ALERT_TEXT=$(echo -e "$ALL_ALERTS")

  # Notify Matrix
  matrix_send "supervisor" "⚠️ Factory alerts:
${ALERT_TEXT}" 2>/dev/null || true

  flog "Invoking claude -p for alerts"

  CLAUDE_PROMPT="$(cat "$PROMPT_FILE" 2>/dev/null || echo "You are a factory supervisor. Fix the issue below.")

## Current Alerts
${ALERT_TEXT}

## Auto-fixes already applied by bash
$(echo -e "${FIXES:-None}")

## System State
RAM: $(free -m | awk '/Mem:/{printf "avail=%sMB", $7}') $(free -m | awk '/Swap:/{printf "swap=%sMB", $3}')
Disk: $(df -h / | awk 'NR==2{printf "%s used of %s (%s)", $3, $2, $5}')
Docker: $(sudo docker ps --format '{{.Names}}' 2>/dev/null | wc -l) containers running
Claude procs: $(pgrep -f "claude" 2>/dev/null | wc -l)

$(if [ -n "$ESCALATION_REPLY" ]; then echo "
## Human Response to Previous Escalation
${ESCALATION_REPLY}

Act on this response."; fi)

Fix what you can. Escalate what you can't. Read the relevant best-practices file first."

  CLAUDE_OUTPUT=$(timeout 300 claude -p --model sonnet --dangerously-skip-permissions \
    "$CLAUDE_PROMPT" 2>&1) || true
  flog "claude output: $(echo "$CLAUDE_OUTPUT" | tail -20)"
  status "claude responded"
else
  [ -n "$FIXES" ] && flog "Housekeeping: $(echo -e "$FIXES")"
  status "all clear"
fi
