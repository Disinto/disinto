#!/usr/bin/env bash
# supervisor-poll.sh — Supervisor agent: bash checks + claude -p for fixes
#
# Two-layer architecture:
#   1. Factory infrastructure (project-agnostic): RAM, disk, swap, docker, stale processes
#   2. Per-project checks (config-driven): CI, PRs, dev-agent, deps — iterated over projects/*.toml
#
# Runs every 10min via cron.
#
# Cron: */10 * * * * /path/to/disinto/supervisor/supervisor-poll.sh
#
# Peek:  cat /tmp/supervisor-status
# Log:   tail -f /path/to/disinto/supervisor/supervisor.log

source "$(dirname "$0")/../lib/env.sh"
source "$(dirname "$0")/../lib/ci-helpers.sh"

LOGFILE="${FACTORY_ROOT}/supervisor/supervisor.log"
STATUSFILE="/tmp/supervisor-status"
LOCKFILE="/tmp/supervisor-poll.lock"
PROMPT_FILE="${FACTORY_ROOT}/supervisor/PROMPT.md"
PROJECTS_DIR="${FACTORY_ROOT}/projects"

METRICS_FILE="${FACTORY_ROOT}/metrics/supervisor-metrics.jsonl"

emit_metric() {
  printf '%s\n' "$1" >> "$METRICS_FILE"
}

# Count all matching items from a paginated Codeberg API endpoint.
# Usage: codeberg_count_paginated "/issues?state=open&labels=backlog&type=issues"
# Returns total count across all pages (max 20 pages = 1000 items).
codeberg_count_paginated() {
  local endpoint="$1" total=0 page=1 count
  while true; do
    count=$(codeberg_api GET "${endpoint}&limit=50&page=${page}" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    total=$((total + ${count:-0}))
    [ "${count:-0}" -lt 50 ] && break
    page=$((page + 1))
    [ "$page" -gt 20 ] && break
  done
  echo "$total"
}

rotate_metrics() {
  [ -f "$METRICS_FILE" ] || return 0
  local cutoff tmpfile
  cutoff=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M)
  tmpfile="${METRICS_FILE}.tmp"
  jq -c --arg cutoff "$cutoff" 'select(.ts >= $cutoff)' \
    "$METRICS_FILE" > "$tmpfile" 2>/dev/null
  # Only replace if jq produced output, or the source is already empty
  if [ -s "$tmpfile" ] || [ ! -s "$METRICS_FILE" ]; then
    mv "$tmpfile" "$METRICS_FILE"
  else
    rm -f "$tmpfile"
  fi
}

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
mkdir -p "$(dirname "$METRICS_FILE")"
rotate_metrics

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

# #############################################################################
#                     LAYER 1: FACTORY INFRASTRUCTURE
#                      (project-agnostic, runs once)
# #############################################################################

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

  # Re-check after fixes
  AVAIL_MB_AFTER=$(free -m | awk '/Mem:/{print $7}')
  SWAP_AFTER=$(free -m | awk '/Swap:/{print $3}')

  if [ "${AVAIL_MB_AFTER:-0}" -lt 500 ] || [ "${SWAP_AFTER:-0}" -gt 3000 ]; then
    p0 "Memory still critical after auto-fix: avail=${AVAIL_MB_AFTER}MB swap=${SWAP_AFTER}MB"
  else
    flog "Memory recovered: avail=${AVAIL_MB_AFTER}MB swap=${SWAP_AFTER}MB"
  fi
fi

# P0 is urgent — send immediately before per-project checks can crash the script
if [ -n "$P0_ALERTS" ]; then
  matrix_send "supervisor" "🚨 Supervisor P0 alerts:
$(printf '%b' "$P0_ALERTS")" 2>/dev/null || true
  P0_ALERTS=""  # clear so it is not duplicated in the final consolidated send
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

  # Truncate logs >10MB
  for logfile in "${FACTORY_ROOT}"/{dev,review,supervisor}/*.log; do
    if [ -f "$logfile" ]; then
      SIZE_KB=$(du -k "$logfile" 2>/dev/null | cut -f1)
      if [ "${SIZE_KB:-0}" -gt 10240 ]; then
        truncate -s 0 "$logfile"
        fixed "Truncated $(basename "$logfile") (was ${SIZE_KB}KB)"
      fi
    fi
  done

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

# P1 is urgent — send immediately before per-project checks can crash the script
if [ -n "$P1_ALERTS" ]; then
  matrix_send "supervisor" "⚠️ Supervisor P1 alerts:
$(printf '%b' "$P1_ALERTS")" 2>/dev/null || true
  P1_ALERTS=""  # clear so it is not duplicated in the final consolidated send
fi

# Emit infra metric
_RAM_TOTAL_MB=$(free -m | awk '/Mem:/{print $2}')
_RAM_USED_PCT=$(( ${_RAM_TOTAL_MB:-0} > 0 ? (${_RAM_TOTAL_MB:-0} - ${AVAIL_MB:-0}) * 100 / ${_RAM_TOTAL_MB:-1} : 0 ))
emit_metric "$(jq -nc \
  --arg ts "$(date -u +%Y-%m-%dT%H:%MZ)" \
  --argjson ram "${_RAM_USED_PCT:-0}" \
  --argjson disk "${DISK_PERCENT:-0}" \
  --argjson swap "${SWAP_USED_MB:-0}" \
  '{ts:$ts,type:"infra",ram_used_pct:$ram,disk_used_pct:$disk,swap_mb:$swap}' 2>/dev/null)" 2>/dev/null || true

# =============================================================================
# P4-INFRA: HOUSEKEEPING — stale processes, log rotation (project-agnostic)
# =============================================================================
status "P4: infra housekeeping"

# Stale agent-spawned claude processes (>3h) — skip interactive sessions
STALE_CLAUDES=$(pgrep -f "claude -p" --older 10800 2>/dev/null || true)
if [ -n "$STALE_CLAUDES" ]; then
  echo "$STALE_CLAUDES" | xargs kill 2>/dev/null || true
  fixed "Killed stale claude processes: $(echo $STALE_CLAUDES | wc -w) procs"
fi

# Rotate logs >5MB
for logfile in "${FACTORY_ROOT}"/{dev,review,supervisor}/*.log; do
  if [ -f "$logfile" ]; then
    SIZE_KB=$(du -k "$logfile" 2>/dev/null | cut -f1)
    if [ "${SIZE_KB:-0}" -gt 5120 ]; then
      mv "$logfile" "${logfile}.old" 2>/dev/null
      fixed "Rotated $(basename "$logfile")"
    fi
  fi
done

# #############################################################################
#                      LAYER 2: PER-PROJECT CHECKS
#               (iterated over projects/*.toml, config-driven)
# #############################################################################

# Infra retry tracking (shared across projects, created once)
_RETRY_DIR="/tmp/supervisor-infra-retries"
mkdir -p "$_RETRY_DIR"

# Function: run all per-project checks for the currently loaded project config
check_project() {
  local proj_name="${PROJECT_NAME:-unknown}"
  flog "── checking project: ${proj_name} (${CODEBERG_REPO}) ──"

  # ===========================================================================
  # P2: FACTORY STOPPED — CI, dev-agent, git
  # ===========================================================================
  status "P2: ${proj_name}: checking pipeline"

  # CI stuck
  STUCK_CI=$(wpdb -c "SELECT count(*) FROM pipelines WHERE repo_id=${WOODPECKER_REPO_ID} AND status='running' AND EXTRACT(EPOCH FROM now() - to_timestamp(started)) > 1200;" 2>/dev/null | xargs || true)
  [ "${STUCK_CI:-0}" -gt 0 ] 2>/dev/null && p2 "${proj_name}: CI: ${STUCK_CI} pipeline(s) running >20min"

  PENDING_CI=$(wpdb -c "SELECT count(*) FROM pipelines WHERE repo_id=${WOODPECKER_REPO_ID} AND status='pending' AND EXTRACT(EPOCH FROM now() - to_timestamp(created)) > 1800;" 2>/dev/null | xargs || true)
  [ "${PENDING_CI:-0}" -gt 0 ] && p2 "${proj_name}: CI: ${PENDING_CI} pipeline(s) pending >30min"

  # Emit CI metric (last completed pipeline within 24h — skip if project has no recent CI)
  _CI_ROW=$(wpdb -A -F ',' -c "SELECT id, COALESCE(ROUND(EXTRACT(EPOCH FROM (to_timestamp(finished) - to_timestamp(started)))/60)::int, 0), status FROM pipelines WHERE repo_id=${WOODPECKER_REPO_ID} AND status IN ('success','failure','error') AND finished > 0 AND to_timestamp(finished) > now() - interval '24 hours' ORDER BY id DESC LIMIT 1;" 2>/dev/null | grep -E '^[0-9]' | head -1 || true)
  if [ -n "$_CI_ROW" ]; then
    _CI_ID=$(echo "$_CI_ROW" | cut -d',' -f1 | tr -d ' ')
    _CI_DUR=$(echo "$_CI_ROW" | cut -d',' -f2 | tr -d ' ')
    _CI_STAT=$(echo "$_CI_ROW" | cut -d',' -f3 | tr -d ' ')
    emit_metric "$(jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%MZ)" \
      --arg proj "$proj_name" \
      --argjson pipeline "${_CI_ID:-0}" \
      --argjson duration "${_CI_DUR:-0}" \
      --arg status "${_CI_STAT:-unknown}" \
      '{ts:$ts,type:"ci",project:$proj,pipeline:$pipeline,duration_min:$duration,status:$status}' 2>/dev/null)" 2>/dev/null || true
  fi

  # ===========================================================================
  # P2e: INFRA FAILURES — auto-retrigger pipelines with infra failures
  # ===========================================================================
  if [ "${CHECK_INFRA_RETRY:-true}" = "true" ]; then
    status "P2e: ${proj_name}: checking infra failures"

    # Recent failed pipelines (last 6h)
    _failed_nums=$(wpdb -A -c "
      SELECT number FROM pipelines
      WHERE repo_id = ${WOODPECKER_REPO_ID}
        AND status IN ('failure', 'error')
        AND finished > 0
        AND to_timestamp(finished) > now() - interval '6 hours'
      ORDER BY number DESC LIMIT 5;" 2>/dev/null \
      | tr -d ' ' | grep -E '^[0-9]+$' || true)

    # shellcheck disable=SC2086
    for _pip_num in $_failed_nums; do
      [ -z "$_pip_num" ] && continue

      # Check retry count; alert if retries exhausted
      _retry_file="${_RETRY_DIR}/${WOODPECKER_REPO_ID}-${_pip_num}"
      _retries=0
      [ -f "$_retry_file" ] && _retries=$(cat "$_retry_file" 2>/dev/null || echo 0)
      if [ "${_retries:-0}" -ge 2 ]; then
        p2 "${proj_name}: Pipeline #${_pip_num}: infra retries exhausted (2/2), needs manual investigation"
        continue
      fi

      # Classify failure type via shared helper
      _classification=$(classify_pipeline_failure "${WOODPECKER_REPO_ID}" "$_pip_num" 2>/dev/null || echo "code")

      if [[ "$_classification" == infra* ]]; then
        _infra_reason="${_classification#infra }"
        _new_retries=$(( _retries + 1 ))
        if woodpecker_api "/repos/${WOODPECKER_REPO_ID}/pipelines/${_pip_num}" \
             -X POST >/dev/null 2>&1; then
          echo "$_new_retries" > "$_retry_file"
          fixed "${proj_name}: Retriggered pipeline #${_pip_num} (${_infra_reason}, retry ${_new_retries}/2)"
        else
          p2 "${proj_name}: Pipeline #${_pip_num}: infra failure (${_infra_reason}) but retrigger API call failed"
          flog "${proj_name}: Failed to retrigger pipeline #${_pip_num}: API error"
        fi
      fi
    done

    # Clean up stale retry tracking files (>24h)
    find "$_RETRY_DIR" -type f -mmin +1440 -delete 2>/dev/null || true
  fi

  # Dev-agent health (only if monitoring enabled)
  if [ "${CHECK_DEV_AGENT:-true}" = "true" ]; then
    DEV_LOCK="/tmp/dev-agent-${PROJECT_NAME}.lock"
    if [ -f "$DEV_LOCK" ]; then
      DEV_PID=$(cat "$DEV_LOCK" 2>/dev/null)
      if ! kill -0 "$DEV_PID" 2>/dev/null; then
        rm -f "$DEV_LOCK"
        fixed "${proj_name}: Removed stale dev-agent lock (PID ${DEV_PID} dead)"
      else
        DEV_STATUS_AGE=$(stat -c %Y "/tmp/dev-agent-status-${PROJECT_NAME:-default}" 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        STATUS_AGE_MIN=$(( (NOW_EPOCH - DEV_STATUS_AGE) / 60 ))
        if [ "$STATUS_AGE_MIN" -gt 30 ]; then
          p2 "${proj_name}: Dev-agent: status unchanged for ${STATUS_AGE_MIN}min"
        fi
      fi
    fi
  fi

  # Git repo health
  if [ -d "${PROJECT_REPO_ROOT}" ]; then
    cd "${PROJECT_REPO_ROOT}" 2>/dev/null || true
    GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
    GIT_REBASE=$([ -d .git/rebase-merge ] || [ -d .git/rebase-apply ] && echo "yes" || echo "no")

    if [ "$GIT_REBASE" = "yes" ]; then
      git rebase --abort 2>/dev/null && git checkout "${PRIMARY_BRANCH}" 2>/dev/null && \
        fixed "${proj_name}: Aborted stale rebase, switched to ${PRIMARY_BRANCH}" || \
        p2 "${proj_name}: Git: stale rebase, auto-abort failed"
    fi
    if [ "$GIT_BRANCH" != "${PRIMARY_BRANCH}" ] && [ "$GIT_BRANCH" != "unknown" ]; then
      git checkout "${PRIMARY_BRANCH}" 2>/dev/null && \
        fixed "${proj_name}: Switched repo from '${GIT_BRANCH}' to ${PRIMARY_BRANCH}" || \
        p2 "${proj_name}: Git: on '${GIT_BRANCH}' instead of ${PRIMARY_BRANCH}"
    fi
  fi

  # ===========================================================================
  # P2b: FACTORY STALLED — backlog exists but no agent running
  # ===========================================================================
  if [ "${CHECK_PIPELINE_STALL:-true}" = "true" ]; then
    status "P2: ${proj_name}: checking pipeline stall"

    BACKLOG_COUNT=$(codeberg_api GET "/issues?state=open&labels=backlog&type=issues&limit=1" 2>/dev/null | jq -r 'length' 2>/dev/null || echo "0")
    IN_PROGRESS=$(codeberg_api GET "/issues?state=open&labels=in-progress&type=issues&limit=1" 2>/dev/null | jq -r 'length' 2>/dev/null || echo "0")

    if [ "${BACKLOG_COUNT:-0}" -gt 0 ] && [ "${IN_PROGRESS:-0}" -eq 0 ]; then
      DEV_LOG="${FACTORY_ROOT}/dev/dev-agent.log"
      if [ -f "$DEV_LOG" ]; then
        LAST_LOG_EPOCH=$(stat -c %Y "$DEV_LOG" 2>/dev/null || echo 0)
      else
        LAST_LOG_EPOCH=0
      fi
      NOW_EPOCH=$(date +%s)
      IDLE_MIN=$(( (NOW_EPOCH - LAST_LOG_EPOCH) / 60 ))

      if [ "$IDLE_MIN" -gt 20 ]; then
        p2 "${proj_name}: Pipeline stalled: ${BACKLOG_COUNT} backlog issue(s), no agent ran for ${IDLE_MIN}min"
      fi
    fi
  fi

  # ===========================================================================
  # P2c: DEV-AGENT PRODUCTIVITY — all backlog blocked for too long
  # ===========================================================================
  if [ "${CHECK_DEV_AGENT:-true}" = "true" ]; then
    status "P2: ${proj_name}: checking dev-agent productivity"

    DEV_LOG_FILE="${FACTORY_ROOT}/dev/dev-agent.log"
    if [ -f "$DEV_LOG_FILE" ]; then
      RECENT_POLLS=$(tail -100 "$DEV_LOG_FILE" | grep "poll:" | tail -6)
      TOTAL_RECENT=$(echo "$RECENT_POLLS" | grep -c "." || true)
      BLOCKED_IN_RECENT=$(echo "$RECENT_POLLS" | grep -c "no ready issues" || true)
      if [ "$TOTAL_RECENT" -ge 6 ] && [ "$BLOCKED_IN_RECENT" -eq "$TOTAL_RECENT" ]; then
        p2 "${proj_name}: Dev-agent blocked: last ${BLOCKED_IN_RECENT} polls all report 'no ready issues'"
      fi
    fi
  fi

  # ===========================================================================
  # P3: FACTORY DEGRADED — derailed PRs, unreviewed PRs
  # ===========================================================================
  if [ "${CHECK_PRS:-true}" = "true" ]; then
    status "P3: ${proj_name}: checking PRs"

    OPEN_PRS=$(codeberg_api GET "/pulls?state=open&limit=10" 2>/dev/null | jq -r '.[].number' 2>/dev/null || true)
    for pr in $OPEN_PRS; do
      PR_JSON=$(codeberg_api GET "/pulls/${pr}" 2>/dev/null || true)
      [ -z "$PR_JSON" ] && continue
      PR_SHA=$(echo "$PR_JSON" | jq -r '.head.sha // ""')
      [ -z "$PR_SHA" ] && continue

      CI_STATE=$(codeberg_api GET "/commits/${PR_SHA}/status" 2>/dev/null | jq -r '.state // "unknown"' 2>/dev/null || true)

      MERGEABLE=$(echo "$PR_JSON" | jq -r '.mergeable // true')
      if [ "$MERGEABLE" = "false" ] && ci_passed "$CI_STATE"; then
        p3 "${proj_name}: PR #${pr}: CI pass but merge conflict — needs rebase"
      elif [ "$CI_STATE" = "failure" ] || [ "$CI_STATE" = "error" ]; then
        UPDATED=$(echo "$PR_JSON" | jq -r '.updated_at // ""')
        if [ -n "$UPDATED" ]; then
          UPDATED_EPOCH=$(date -d "$UPDATED" +%s 2>/dev/null || echo 0)
          NOW_EPOCH=$(date +%s)
          AGE_MIN=$(( (NOW_EPOCH - UPDATED_EPOCH) / 60 ))
          [ "$AGE_MIN" -gt 30 ] && p3 "${proj_name}: PR #${pr}: CI=${CI_STATE}, stale ${AGE_MIN}min"
        fi
      elif ci_passed "$CI_STATE"; then
        HAS_REVIEW=$(codeberg_api GET "/issues/${pr}/comments?limit=50" 2>/dev/null | \
          jq -r --arg sha "$PR_SHA" '[.[] | select(.body | contains("<!-- reviewed: " + $sha))] | length' 2>/dev/null || echo "0")

        if [ "${HAS_REVIEW:-0}" -eq 0 ]; then
          UPDATED=$(echo "$PR_JSON" | jq -r '.updated_at // ""')
          if [ -n "$UPDATED" ]; then
            UPDATED_EPOCH=$(date -d "$UPDATED" +%s 2>/dev/null || echo 0)
            NOW_EPOCH=$(date +%s)
            AGE_MIN=$(( (NOW_EPOCH - UPDATED_EPOCH) / 60 ))
            if [ "$AGE_MIN" -gt 60 ]; then
              p3 "${proj_name}: PR #${pr}: CI passed, no review for ${AGE_MIN}min"
              bash "${FACTORY_ROOT}/review/review-pr.sh" "$pr" >> "${FACTORY_ROOT}/review/review.log" 2>&1 &
              fixed "${proj_name}: Auto-triggered review for PR #${pr}"
            fi
          fi
        fi
      fi
    done
  fi

  # ===========================================================================
  # P3b: CIRCULAR DEPENDENCIES — deadlock detection
  # ===========================================================================
  status "P3: ${proj_name}: checking for circular dependencies"

  BACKLOG_FOR_DEPS=$(codeberg_api GET "/issues?state=open&labels=backlog&type=issues&limit=50" 2>/dev/null || true)
  if [ -n "$BACKLOG_FOR_DEPS" ] && [ "$BACKLOG_FOR_DEPS" != "null" ] && [ "$(echo "$BACKLOG_FOR_DEPS" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then

    PARSE_DEPS="${FACTORY_ROOT}/lib/parse-deps.sh"
    ISSUE_COUNT=$(echo "$BACKLOG_FOR_DEPS" | jq 'length')

    declare -A DEPS_OF
    declare -A BACKLOG_NUMS
    for i in $(seq 0 $((ISSUE_COUNT - 1))); do
      NUM=$(echo "$BACKLOG_FOR_DEPS" | jq -r ".[$i].number")
      BODY=$(echo "$BACKLOG_FOR_DEPS" | jq -r ".[$i].body // \"\"")
      ISSUE_DEPS=$(echo "$BODY" | bash "$PARSE_DEPS" | grep -v "^${NUM}$" || true)
      [ -n "$ISSUE_DEPS" ] && DEPS_OF[$NUM]="$ISSUE_DEPS"
      # shellcheck disable=SC2034
      BACKLOG_NUMS[$NUM]=1
    done

    declare -A NODE_COLOR
    for node in "${!DEPS_OF[@]}"; do NODE_COLOR[$node]=0; done

    FOUND_CYCLES=""
    declare -A SEEN_CYCLES

    dfs_detect_cycle() {
      local node="$1" path="$2"
      NODE_COLOR[$node]=1
      for dep in ${DEPS_OF[$node]:-}; do
        [ -z "${NODE_COLOR[$dep]+x}" ] && continue
        if [ "${NODE_COLOR[$dep]}" = "1" ]; then
          local cycle_key
              cycle_key=$(echo "$path $dep" | tr ' ' '\n' | sort -n | tr '\n' ' ')
          if [ -z "${SEEN_CYCLES[$cycle_key]+x}" ]; then
            SEEN_CYCLES[$cycle_key]=1
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
        p3 "${proj_name}: Circular dependency deadlock: ${cycle}"
      done
    fi

    # =========================================================================
    # P3c: STALE DEPENDENCIES — blocked by old open issues (>30 days)
    # =========================================================================
    status "P3: ${proj_name}: checking for stale dependencies"

    NOW_EPOCH=$(date +%s)
    declare -A DEP_CACHE

    for issue_num in "${!DEPS_OF[@]}"; do
      for dep in ${DEPS_OF[$issue_num]}; do
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
          p3 "${proj_name}: Stale dependency: #${issue_num} blocked by #${dep} \"${DEP_TITLE}\" (open ${AGE_DAYS} days)"
        fi
      done
    done

    unset DEPS_OF BACKLOG_NUMS NODE_COLOR SEEN_CYCLES DEP_CACHE
  fi

  # Emit dev metric (paginated to avoid silent cap at 50)
  _BACKLOG_COUNT=$(codeberg_count_paginated "/issues?state=open&labels=backlog&type=issues")
  _BLOCKED_COUNT=$(codeberg_count_paginated "/issues?state=open&labels=blocked&type=issues")
  _PR_COUNT=$(codeberg_count_paginated "/pulls?state=open")
  emit_metric "$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%MZ)" \
    --arg proj "$proj_name" \
    --argjson backlog "${_BACKLOG_COUNT:-0}" \
    --argjson blocked "${_BLOCKED_COUNT:-0}" \
    --argjson prs "${_PR_COUNT:-0}" \
    '{ts:$ts,type:"dev",project:$proj,issues_in_backlog:$backlog,issues_blocked:$blocked,pr_open:$prs}' 2>/dev/null)" 2>/dev/null || true

  # ===========================================================================
  # P2d: ESCALATE — inject human replies into escalated dev sessions
  # ===========================================================================
  status "P2: ${proj_name}: checking escalate sessions"

  HUMAN_REPLY_FILE="/tmp/dev-escalation-reply"

  for _nh_phase_file in /tmp/dev-session-"${proj_name}"-*.phase; do
    [ -f "$_nh_phase_file" ] || continue
    _nh_phase=$(head -1 "$_nh_phase_file" 2>/dev/null | tr -d '[:space:]' || true)
    [ "$_nh_phase" = "PHASE:escalate" ] || continue

    _nh_issue=$(basename "$_nh_phase_file" .phase)
    _nh_issue="${_nh_issue#dev-session-${proj_name}-}"
    [ -z "$_nh_issue" ] && continue
    _nh_session="dev-${proj_name}-${_nh_issue}"

    # Check tmux session is alive
    if ! tmux has-session -t "$_nh_session" 2>/dev/null; then
      flog "${proj_name}: #${_nh_issue} phase=escalate but tmux session gone"
      continue
    fi

    # Inject human reply if available (atomic mv to prevent double-injection with gardener)
    _nh_claimed="/tmp/dev-escalation-reply.supervisor.$$"
    if [ -s "$HUMAN_REPLY_FILE" ] && mv "$HUMAN_REPLY_FILE" "$_nh_claimed" 2>/dev/null; then
      _nh_reply=$(cat "$_nh_claimed")
      _nh_inject_msg="Human reply received for issue #${_nh_issue}:

${_nh_reply}

Instructions:
1. Read the human's guidance carefully.
2. Continue your work based on their input.
3. When done, push your changes and write the appropriate phase."

      _nh_tmpfile=$(mktemp /tmp/human-inject-XXXXXX)
      printf '%s' "$_nh_inject_msg" > "$_nh_tmpfile"
      # All tmux calls guarded: session may die between has-session and here
      tmux load-buffer -b "human-inject-${_nh_issue}" "$_nh_tmpfile" || true
      tmux paste-buffer -t "$_nh_session" -b "human-inject-${_nh_issue}" || true
      sleep 0.5
      tmux send-keys -t "$_nh_session" "" Enter || true
      tmux delete-buffer -b "human-inject-${_nh_issue}" 2>/dev/null || true
      rm -f "$_nh_tmpfile" "$_nh_claimed"

      rm -f "/tmp/dev-renotify-${proj_name}-${_nh_issue}"
      flog "${proj_name}: #${_nh_issue} human reply injected into session ${_nh_session}"
      fixed "${proj_name}: Injected human reply into dev session #${_nh_issue}"
      break  # one reply to deliver
    else
      # No reply yet — check for timeout (re-notify at 6h, alert at 24h)
      _nh_mtime=$(stat -c %Y "$_nh_phase_file" 2>/dev/null || echo 0)
      _nh_now=$(date +%s)
      _nh_age=$(( _nh_now - _nh_mtime ))

      if [ "$_nh_age" -gt 86400 ]; then
        p2 "${proj_name}: Dev session #${_nh_issue} stuck in escalate for >24h"
      elif [ "$_nh_age" -gt 21600 ]; then
        _nh_renotify="/tmp/dev-renotify-${proj_name}-${_nh_issue}"
        if [ ! -f "$_nh_renotify" ]; then
          _nh_age_h=$(( _nh_age / 3600 ))
          matrix_send "dev" "⏰ Reminder: Issue #${_nh_issue} still needs human input (waiting ${_nh_age_h}h)" 2>/dev/null || true
          touch "$_nh_renotify"
          flog "${proj_name}: #${_nh_issue} re-notified (escalate for ${_nh_age_h}h)"
        fi
      fi
    fi
  done

  # ===========================================================================
  # P4-PROJECT: Orphaned tmux sessions — PR/issue closed externally
  # ===========================================================================
  status "P4: ${proj_name}: sweeping orphaned dev sessions"

  while IFS= read -r _sess; do
    [ -z "$_sess" ] && continue

    # Extract issue number from dev-{project}-{issue}
    _sess_issue="${_sess#dev-"${proj_name}"-}"
    [[ "$_sess_issue" =~ ^[0-9]+$ ]] || continue

    # Check Codeberg: is the issue still open?
    _issue_state=$(codeberg_api GET "/issues/${_sess_issue}" 2>/dev/null \
      | jq -r '.state // "open"' 2>/dev/null || echo "open")

    _should_cleanup=false
    _cleanup_reason=""

    if [ "$_issue_state" = "closed" ]; then
      _should_cleanup=true
      _cleanup_reason="issue #${_sess_issue} closed externally"
    else
      # Issue still open — skip cleanup during active-wait phases (no PR yet is normal)
      _phase_file="/tmp/dev-session-${proj_name}-${_sess_issue}.phase"
      _curr_phase=$(head -1 "$_phase_file" 2>/dev/null | tr -d '[:space:]' || true)
      case "${_curr_phase:-}" in
        PHASE:escalate|PHASE:awaiting_ci|PHASE:awaiting_review)
          continue  # session has legitimate pending work
          ;;
      esac

      # Check if associated PR is open (paginated)
      _pr_branch="fix/issue-${_sess_issue}"
      _has_open_pr=0
      _pr_page=1
      while true; do
        _pr_page_json=$(codeberg_api GET "/pulls?state=open&limit=50&page=${_pr_page}" \
          2>/dev/null || echo "[]")
        _pr_page_len=$(printf '%s' "$_pr_page_json" | jq 'length' 2>/dev/null || echo 0)
        _pr_match=$(printf '%s' "$_pr_page_json" | \
          jq --arg b "$_pr_branch" '[.[] | select(.head.ref == $b)] | length' \
          2>/dev/null || echo 0)
        _has_open_pr=$(( _has_open_pr + ${_pr_match:-0} ))
        [ "${_has_open_pr:-0}" -gt 0 ] && break
        [ "${_pr_page_len:-0}" -lt 50 ] && break
        _pr_page=$(( _pr_page + 1 ))
        [ "$_pr_page" -gt 20 ] && break
      done

      if [ "$_has_open_pr" -eq 0 ]; then
        # No open PR — check for a closed/merged PR with this branch (paginated)
        _has_closed_pr=0
        _pr_page=1
        while true; do
          _pr_page_json=$(codeberg_api GET "/pulls?state=closed&limit=50&page=${_pr_page}" \
            2>/dev/null || echo "[]")
          _pr_page_len=$(printf '%s' "$_pr_page_json" | jq 'length' 2>/dev/null || echo 0)
          _pr_match=$(printf '%s' "$_pr_page_json" | \
            jq --arg b "$_pr_branch" '[.[] | select(.head.ref == $b)] | length' \
            2>/dev/null || echo 0)
          _has_closed_pr=$(( _has_closed_pr + ${_pr_match:-0} ))
          [ "${_has_closed_pr:-0}" -gt 0 ] && break
          [ "${_pr_page_len:-0}" -lt 50 ] && break
          _pr_page=$(( _pr_page + 1 ))
          [ "$_pr_page" -gt 20 ] && break
        done

        if [ "$_has_closed_pr" -gt 0 ]; then
          _should_cleanup=true
          _cleanup_reason="PR for issue #${_sess_issue} is closed/merged"
        else
          # No PR at all — clean up if session idle >30min
          # On query failure, skip rather than defaulting to epoch 0
          if ! _sess_activity=$(tmux display-message -t "$_sess" \
              -p '#{session_activity}' 2>/dev/null); then
            flog "${proj_name}: Could not query activity for session ${_sess}, skipping"
            continue
          fi
          _now_ts=$(date +%s)
          _idle_min=$(( (_now_ts - _sess_activity) / 60 ))
          if [ "$_idle_min" -gt 30 ]; then
            _should_cleanup=true
            _cleanup_reason="no PR found, session idle ${_idle_min}min"
          fi
        fi
      fi
    fi

    if [ "$_should_cleanup" = true ]; then
      tmux kill-session -t "$_sess" 2>/dev/null || true
      _wt="/tmp/${proj_name}-worktree-${_sess_issue}"
      if [ -d "$_wt" ]; then
        git -C "$PROJECT_REPO_ROOT" worktree remove --force "$_wt" 2>/dev/null || true
      fi
      # Remove lock only if its recorded PID is no longer alive
      _lock="/tmp/dev-agent-${proj_name}.lock"
      if [ -f "$_lock" ]; then
        _lock_pid=$(cat "$_lock" 2>/dev/null || true)
        if [ -n "${_lock_pid:-}" ] && ! kill -0 "$_lock_pid" 2>/dev/null; then
          rm -f "$_lock"
        fi
      fi
      rm -f "/tmp/dev-session-${proj_name}-${_sess_issue}.phase"
      fixed "${proj_name}: Cleaned orphaned session ${_sess} (${_cleanup_reason})"
    fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^dev-${proj_name}-" || true)

  # ===========================================================================
  # P4-PROJECT: Clean stale worktrees for this project
  # ===========================================================================
  NOW_TS=$(date +%s)
  for wt in /tmp/${PROJECT_NAME}-worktree-* /tmp/${PROJECT_NAME}-review-* /tmp/${PROJECT_NAME}-sup-retry-*; do
    [ -d "$wt" ] || continue
    WT_AGE_MIN=$(( (NOW_TS - $(stat -c %Y "$wt")) / 60 ))
    if [ "$WT_AGE_MIN" -gt 120 ]; then
      WT_BASE=$(basename "$wt")
      if ! pgrep -f "$WT_BASE" >/dev/null 2>&1; then
        git -C "$PROJECT_REPO_ROOT" worktree remove --force "$wt" 2>/dev/null && \
          fixed "${proj_name}: Removed stale worktree: $wt (${WT_AGE_MIN}min old)" || true
      fi
    fi
  done
  git -C "$PROJECT_REPO_ROOT" worktree prune 2>/dev/null || true
}

# =============================================================================
# Iterate over all registered projects
# =============================================================================
status "checking projects"

PROJECT_COUNT=0
if [ -d "$PROJECTS_DIR" ]; then
  for project_toml in "${PROJECTS_DIR}"/*.toml; do
    [ -f "$project_toml" ] || continue
    PROJECT_COUNT=$((PROJECT_COUNT + 1))

    # Load project config (overrides CODEBERG_REPO, PROJECT_REPO_ROOT, etc.)
    source "${FACTORY_ROOT}/lib/load-project.sh" "$project_toml"

    check_project || flog "check_project failed for ${project_toml} (per-project checks incomplete)"
  done
fi

if [ "$PROJECT_COUNT" -eq 0 ]; then
  # Fallback: no project TOML files, use .env config (backwards compatible)
  flog "No projects/*.toml found, using .env defaults"
  check_project || flog "check_project failed with .env defaults (per-project checks incomplete)"
fi

# #############################################################################
#                              RESULT
# #############################################################################

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
