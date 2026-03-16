#!/usr/bin/env bash
# supervisor-poll.sh — Supervisor agent: bash checks + claude -p for fixes
#
# Runs every 10min via cron. Does all health checks in bash (zero tokens).
# Only invokes claude -p when auto-fix fails or issue is complex.
#
# Cron: */10 * * * * /path/to/disinto/supervisor/supervisor-poll.sh
#
# Peek:  cat /tmp/supervisor-status
# Log:   tail -f /path/to/disinto/supervisor/supervisor.log

source "$(dirname "$0")/../lib/env.sh"

LOGFILE="${FACTORY_ROOT}/supervisor/supervisor.log"
STATUSFILE="/tmp/supervisor-status"
LOCKFILE="/tmp/supervisor-poll.lock"
PROMPT_FILE="${FACTORY_ROOT}/supervisor/PROMPT.md"

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
  printf '[%s] supervisor: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" > "$STATUSFILE"
  flog "$*"
}

# ── Check for escalation replies from Matrix ──────────────────────────────
ESCALATION_REPLY=""
if [ -s /tmp/supervisor-escalation-reply ]; then
  ESCALATION_REPLY=$(cat /tmp/supervisor-escalation-reply)
  rm -f /tmp/supervisor-escalation-reply
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

  # Kill stale agent-spawned claude processes (>3h old) — skip interactive sessions
  STALE_CLAUDES=$(pgrep -f "claude -p" --older 10800 2>/dev/null || true)
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

  # Truncate supervisor logs >10MB
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
status "P2: checking pipeline"

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
status "P2: checking pipeline stall"

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
    p2 "Pipeline stalled: ${BACKLOG_COUNT} backlog issue(s), no agent ran for ${IDLE_MIN}min"
  fi
fi

# =============================================================================
# P2c: DEV-AGENT PRODUCTIVITY — all backlog blocked for too long
# =============================================================================
status "P2: checking dev-agent productivity"

DEV_LOG_FILE="${FACTORY_ROOT}/dev/dev-agent.log"
if [ -f "$DEV_LOG_FILE" ]; then
  # Check if last 6 poll entries all report "no ready issues" (~1 hour at 10min intervals)
  RECENT_POLLS=$(tail -100 "$DEV_LOG_FILE" | grep "poll:" | tail -6)
  TOTAL_RECENT=$(echo "$RECENT_POLLS" | grep -c "." || true)
  BLOCKED_IN_RECENT=$(echo "$RECENT_POLLS" | grep -c "no ready issues" || true)
  if [ "$TOTAL_RECENT" -ge 6 ] && [ "$BLOCKED_IN_RECENT" -eq "$TOTAL_RECENT" ]; then
    p2 "Dev-agent blocked: last ${BLOCKED_IN_RECENT} polls all report 'no ready issues' — all backlog issues may be dep-blocked or have circular deps"
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
# P3b: CIRCULAR DEPENDENCIES — deadlock detection
# =============================================================================
status "P3: checking for circular dependencies"

BACKLOG_FOR_DEPS=$(codeberg_api GET "/issues?state=open&labels=backlog&type=issues&limit=50" 2>/dev/null || true)
if [ -n "$BACKLOG_FOR_DEPS" ] && [ "$BACKLOG_FOR_DEPS" != "null" ] && [ "$(echo "$BACKLOG_FOR_DEPS" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then

  PARSE_DEPS="${FACTORY_ROOT}/lib/parse-deps.sh"
  ISSUE_COUNT=$(echo "$BACKLOG_FOR_DEPS" | jq 'length')

  # Build dep graph: DEPS_OF[issue_num]="dep1 dep2 ..."
  declare -A DEPS_OF
  declare -A BACKLOG_NUMS
  for i in $(seq 0 $((ISSUE_COUNT - 1))); do
    NUM=$(echo "$BACKLOG_FOR_DEPS" | jq -r ".[$i].number")
    BODY=$(echo "$BACKLOG_FOR_DEPS" | jq -r ".[$i].body // \"\"")
    ISSUE_DEPS=$(echo "$BODY" | bash "$PARSE_DEPS" | grep -v "^${NUM}$" || true)
    [ -n "$ISSUE_DEPS" ] && DEPS_OF[$NUM]="$ISSUE_DEPS"
    BACKLOG_NUMS[$NUM]=1
  done

  # DFS cycle detection using color marking (0=white, 1=gray, 2=black)
  declare -A NODE_COLOR
  for node in "${!DEPS_OF[@]}"; do NODE_COLOR[$node]=0; done

  FOUND_CYCLES=""
  declare -A SEEN_CYCLES

  dfs_detect_cycle() {
    local node="$1" path="$2"
    NODE_COLOR[$node]=1
    for dep in ${DEPS_OF[$node]:-}; do
      [ -z "${NODE_COLOR[$dep]+x}" ] && continue  # not in graph
      if [ "${NODE_COLOR[$dep]}" = "1" ]; then
        # Cycle found — normalize for dedup
        local cycle_key=$(echo "$path $dep" | tr ' ' '\n' | sort -n | tr '\n' ' ')
        if [ -z "${SEEN_CYCLES[$cycle_key]+x}" ]; then
          SEEN_CYCLES[$cycle_key]=1
          # Extract cycle portion from path (from $dep onward)
          local in_cycle=0 cycle_str=""
          for p in $path $dep; do
            [ "$p" = "$dep" ] && in_cycle=1
            [ "$in_cycle" = "1" ] && cycle_str="${cycle_str:+$cycle_str -> }#${p}"
          done
          FOUND_CYCLES="${FOUND_CYCLES}${cycle_str}\n"
        fi
      elif [ "${NODE_COLOR[$dep]}" = "0" ]; then
        dfs_detect_cycle "$dep" "$path $dep"
      fi
    done
    NODE_COLOR[$node]=2
  }

  for node in "${!DEPS_OF[@]}"; do
    [ "${NODE_COLOR[$node]:-2}" = "0" ] && dfs_detect_cycle "$node" "$node"
  done

  if [ -n "$FOUND_CYCLES" ]; then
    echo -e "$FOUND_CYCLES" | while IFS= read -r cycle; do
      [ -z "$cycle" ] && continue
      p3 "Circular dependency deadlock: ${cycle}"
    done
  fi

  # ===========================================================================
  # P3c: STALE DEPENDENCIES — blocked by old open issues (>30 days)
  # ===========================================================================
  status "P3: checking for stale dependencies"

  NOW_EPOCH=$(date +%s)
  THIRTY_DAYS=$((30 * 86400))
  declare -A DEP_CACHE

  for issue_num in "${!DEPS_OF[@]}"; do
    for dep in ${DEPS_OF[$issue_num]}; do
      # Check cache first
      if [ -n "${DEP_CACHE[$dep]+x}" ]; then
        DEP_INFO="${DEP_CACHE[$dep]}"
      else
        DEP_JSON=$(codeberg_api GET "/issues/${dep}" 2>/dev/null || true)
        [ -z "$DEP_JSON" ] && continue
        DEP_STATE=$(echo "$DEP_JSON" | jq -r '.state // "unknown"')
        DEP_CREATED=$(echo "$DEP_JSON" | jq -r '.created_at // ""')
        DEP_TITLE=$(echo "$DEP_JSON" | jq -r '.title // ""' | head -c 50)
        DEP_INFO="${DEP_STATE}|${DEP_CREATED}|${DEP_TITLE}"
        DEP_CACHE[$dep]="$DEP_INFO"
      fi

      DEP_STATE="${DEP_INFO%%|*}"
      [ "$DEP_STATE" != "open" ] && continue

      DEP_REST="${DEP_INFO#*|}"
      DEP_CREATED="${DEP_REST%%|*}"
      DEP_TITLE="${DEP_REST#*|}"

      [ -z "$DEP_CREATED" ] && continue
      CREATED_EPOCH=$(date -d "$DEP_CREATED" +%s 2>/dev/null || echo 0)
      AGE_DAYS=$(( (NOW_EPOCH - CREATED_EPOCH) / 86400 ))
      if [ "$AGE_DAYS" -gt 30 ]; then
        p3 "Stale dependency: #${issue_num} blocked by #${dep} \"${DEP_TITLE}\" (open ${AGE_DAYS} days)"
      fi
    done
  done

  unset DEPS_OF BACKLOG_NUMS NODE_COLOR SEEN_CYCLES DEP_CACHE
fi

# =============================================================================
# P4: HOUSEKEEPING — stale processes
# =============================================================================
# Check for dev-agent escalations
ESCALATION_FILE="${FACTORY_ROOT}/supervisor/escalations.jsonl"
if [ -s "$ESCALATION_FILE" ]; then
  ESCALATION_COUNT=$(wc -l < "$ESCALATION_FILE")
  p3 "Dev-agent escalated ${ESCALATION_COUNT} issue(s) — see ${ESCALATION_FILE}"
fi

status "P4: housekeeping"

# Stale agent-spawned claude processes (>3h, not caught by P0) — skip interactive sessions
STALE_CLAUDES=$(pgrep -f "claude -p" --older 10800 2>/dev/null || true)
if [ -n "$STALE_CLAUDES" ]; then
  echo "$STALE_CLAUDES" | xargs kill 2>/dev/null || true
  fixed "Killed stale claude processes: $(echo $STALE_CLAUDES | wc -w) procs"
fi

# Clean stale git worktrees (>2h, no active agent)
NOW_TS=$(date +%s)
for wt in /tmp/${PROJECT_NAME}-worktree-* /tmp/${PROJECT_NAME}-review-*; do
  [ -d "$wt" ] || continue
  WT_AGE_MIN=$(( (NOW_TS - $(stat -c %Y "$wt")) / 60 ))
  if [ "$WT_AGE_MIN" -gt 120 ]; then
    # Skip if an agent is still using it
    WT_BASE=$(basename "$wt")
    if ! pgrep -f "$WT_BASE" >/dev/null 2>&1; then
      git -C "$PROJECT_REPO_ROOT" worktree remove --force "$wt" 2>/dev/null && \
        fixed "Removed stale worktree: $wt (${WT_AGE_MIN}min old)" || true
    fi
  fi
done
git -C "$PROJECT_REPO_ROOT" worktree prune 2>/dev/null || true

# Rotate supervisor log if >5MB
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
  matrix_send "supervisor" "⚠️ Supervisor alerts:
${ALERT_TEXT}" 2>/dev/null || true

  flog "Invoking claude -p for alerts"

  CLAUDE_PROMPT="$(cat "$PROMPT_FILE" 2>/dev/null || echo "You are a supervisor agent. Fix the issue below.")

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
