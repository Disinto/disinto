#!/usr/bin/env bash
# =============================================================================
# preflight.sh — Collect system and project metrics for the supervisor formula
#
# Outputs structured text to stdout. Called by supervisor-run.sh before
# launching the Claude session. The output is injected into the prompt.
#
# Usage:
#   bash supervisor/preflight.sh [projects/disinto.toml]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# shellcheck source=../lib/ci-helpers.sh
source "$FACTORY_ROOT/lib/ci-helpers.sh"

# ── System Resources ─────────────────────────────────────────────────────

echo "## System Resources"

_avail_mb=$(free -m | awk '/Mem:/{print $7}')
_total_mb=$(free -m | awk '/Mem:/{print $2}')
_swap_used=$(free -m | awk '/Swap:/{print $3}')
_disk_pct=$(df -h / | awk 'NR==2{print $5}' | tr -d '%')
_disk_used=$(df -h / | awk 'NR==2{print $3}')
_disk_total=$(df -h / | awk 'NR==2{print $2}')
_load=$(cat /proc/loadavg 2>/dev/null || echo "unknown")

echo "RAM: ${_avail_mb}MB available / ${_total_mb}MB total, Swap: ${_swap_used}MB used"
echo "Disk: ${_disk_pct}% used (${_disk_used}/${_disk_total} on /)"
echo "Load: ${_load}"
echo ""

# ── Docker ────────────────────────────────────────────────────────────────

echo "## Docker"
if command -v docker &>/dev/null; then
  docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || echo "Docker query failed"
else
  echo "Docker not available"
fi
echo ""

# ── Docker Allocs ─────────────────────────────────────────────────────────

echo "## Docker Allocs"
if command -v docker &>/dev/null; then
  # Single docker stats call — one snapshot, no streaming.
  _stats_json=$(docker stats --no-stream --format '{{json .}}' 2>/dev/null || echo "")
  if [ -n "$_stats_json" ]; then
    # Header
    printf "%-28s %-10s %-7s %-11s %-22s %-9s %s\n" "NAME" "STATUS" "CPU%" "RSS(MB)" "IMAGE" "RESTARTS" "MOUNTS"

    # Collect per-container data as lines: name|status|cpu|rss_mb|image|restarts|mounts
    _alloc_lines=""
    while IFS= read -r _line; do
      [ -n "$_line" ] || continue
      _name=$(printf '%s' "$_line" | jq -r '.Name // empty' 2>/dev/null)
      [ -n "$_name" ] || continue
      # Only include containers with Nomad alloc label
      _has_nomad=$(printf '%s' "$_line" | jq -r '
        (.Labels // "") |
        if (. | type) == "string" then .
        else (. | to_entries | map(.value | tostring) | join(","))
        end |
        split(",") | map(select(test("com\\.hashicorp\\.nomad"; "i"))) | length' 2>/dev/null)
      [ "$_has_nomad" -gt 0 ] 2>/dev/null || continue

      _status=$(printf '%s' "$_line" | jq -r '.State // "unknown"' 2>/dev/null)
      _cpu_raw=$(printf '%s' "$_line" | jq -r '.CPU // "0"' 2>/dev/null)
      _cpu=$(printf '%s' "$_cpu_raw" | sed 's/%//;s/[^0-9.]//g')
      [ -n "$_cpu" ] || _cpu="0"
      _mem_raw=$(printf '%s' "$_line" | jq -r '.MemUsage // ""' 2>/dev/null)
      _rss_mb=$(printf '%s' "$_mem_raw" | awk -F'/' '{gsub(/[^0-9.]/,"",$1); print $1}' 2>/dev/null)
      [ -n "$_rss_mb" ] || _rss_mb="0"
      # Use inspect for image, restart count, mounts (not in stats output)
      _inspect=$(docker inspect "$_name" --format '{{.RestartCount}}\t{{.Config.Image}}\t{{range .Mounts}}{{.Name}},{{end}}' 2>/dev/null || echo $'\t\t')
      _restarts=$(printf '%s' "$_inspect" | cut -f1)
      _image=$(printf '%s' "$_inspect" | cut -f2)
      _mounts=$(printf '%s' "$_inspect" | cut -f3 | sed 's/,$//')
      [ -n "$_image" ] || _image="-"
      [ -n "$_restarts" ] || _restarts="0"
      [ -n "$_mounts" ] || _mounts="-"
      _alloc_lines="${_alloc_lines}${_name}|${_status}|${_cpu}|${_rss_mb}|${_image}|${_restarts}|${_mounts}"$'\n'
    done <<< "$_stats_json"

    # Print sorted by RSS desc
    printf '%s' "$_alloc_lines" | sort -t'|' -k4 -rn | head -50 | while IFS='|' read -r _n _s _c _r _i _rs _m; do
      [ -n "$_n" ] || continue
      printf "%-28s %-10s %-7s %-11s %-22s %-9s %s\n" "$_n" "$_s" "$_c" "$_r" "$_i" "$_rs" "$_m"
    done

    # Top-3 RSS summary
    _top_rss=$(printf '%s' "$_alloc_lines" | sort -t'|' -k4 -rn | head -3 | while IFS='|' read -r _n _s _c _r _i _rs _m; do
      [ -n "$_n" ] || continue
      printf "%s %sMB, " "$_n" "$_r"
    done)
    _top_rss=$(printf '%s' "$_top_rss" | sed 's/, $//')
    [ -n "${_top_rss:-}" ] && echo "Top-3 RSS: ${_top_rss}"

    # Top-3 CPU summary
    _top_cpu=$(printf '%s' "$_alloc_lines" | sort -t'|' -k3 -rn | head -3 | while IFS='|' read -r _n _s _c _r _i _rs _m; do
      [ -n "$_n" ] || continue
      printf "%s %s%%, " "$_n" "$_c"
    done)
    _top_cpu=$(printf '%s' "$_top_cpu" | sed 's/, $//')
    [ -n "${_top_cpu:-}" ] && echo "Top-3 CPU: ${_top_cpu}"
  else
    echo "(no containers or docker unavailable)"
  fi
else
  echo "Docker not available"
fi
echo ""

# ── Host Volumes ──────────────────────────────────────────────────────────

echo "## Host Volumes"
if [ -d /srv/disinto ]; then
  du -sh /srv/disinto/* 2>/dev/null | while IFS=$'\t' read -r _sz _p; do
    printf "%-32s %s\n" "$_p" "$_sz"
  done
else
  echo "/srv/disinto not found"
fi
echo ""

# ── Active Sessions + Phase Files ─────────────────────────────────────────

echo "## Active Sessions"
if tmux list-sessions 2>/dev/null; then
  :
else
  echo "No tmux sessions"
fi
echo ""

echo "## Phase Files"
_found_phase=false
for _pf in /tmp/*-session-*.phase; do
  [ -f "$_pf" ] || continue
  _found_phase=true
  _phase_content=$(head -1 "$_pf" 2>/dev/null || echo "unreadable")
  _phase_age_min=$(( ($(date +%s) - $(stat -c %Y "$_pf" 2>/dev/null || echo 0)) / 60 ))
  echo "  $(basename "$_pf"): ${_phase_content} (${_phase_age_min}min ago)"
done
[ "$_found_phase" = false ] && echo "  None"
echo ""

# ── Stale Phase Cleanup ─────────────────────────────────────────────────
# Auto-remove PHASE:escalate files whose parent issue/PR is confirmed closed.
# Grace period: 24h after issue closure to avoid race conditions.

echo "## Stale Phase Cleanup"
_found_stale=false
for _pf in /tmp/*-session-*.phase; do
  [ -f "$_pf" ] || continue
  _phase_line=$(head -1 "$_pf" 2>/dev/null || echo "")
  # Only target PHASE:escalate files
  case "$_phase_line" in
    PHASE:escalate*) ;;
    *) continue ;;
  esac
  # Extract issue number: *-session-{PROJECT_NAME}-{number}.phase
  _base=$(basename "$_pf" .phase)
  if [[ "$_base" =~ -session-${PROJECT_NAME}-([0-9]+)$ ]]; then
    _issue_num="${BASH_REMATCH[1]}"
  else
    continue
  fi
  # Query Forge for issue/PR state
  _issue_json=$(forge_api GET "/issues/${_issue_num}" 2>/dev/null || echo "")
  [ -n "$_issue_json" ] || continue
  _state=$(printf '%s' "$_issue_json" | jq -r '.state // empty' 2>/dev/null)
  [ "$_state" = "closed" ] || continue
  _found_stale=true
  # Enforce 24h grace period after closure
  _closed_at=$(printf '%s' "$_issue_json" | jq -r '.closed_at // empty' 2>/dev/null)
  [ -n "$_closed_at" ] || continue
  _closed_epoch=$(date -d "$_closed_at" +%s 2>/dev/null || echo 0)
  _now=$(date +%s)
  _elapsed=$(( _now - _closed_epoch ))
  if [ "$_elapsed" -gt 86400 ]; then
    rm -f "$_pf"
    echo "  Cleaned: $(basename "$_pf") — issue #${_issue_num} closed at ${_closed_at}"
  else
    _remaining_h=$(( (86400 - _elapsed) / 3600 ))
    echo "  Grace: $(basename "$_pf") — issue #${_issue_num} closed, ${_remaining_h}h remaining"
  fi
done
[ "$_found_stale" = false ] && echo "  None"
echo ""

# ── Lock Files ────────────────────────────────────────────────────────────

echo "## Lock Files"
_found_lock=false
for _lf in /tmp/*-poll.lock /tmp/*-run.lock /tmp/dev-agent-*.lock; do
  [ -f "$_lf" ] || continue
  _found_lock=true
  _pid=$(cat "$_lf" 2>/dev/null || true)
  _age_min=$(( ($(date +%s) - $(stat -c %Y "$_lf" 2>/dev/null || echo 0)) / 60 ))
  _alive="dead"
  [ -n "${_pid:-}" ] && kill -0 "$_pid" 2>/dev/null && _alive="alive"
  echo "  $(basename "$_lf"): PID=${_pid:-?} ${_alive} age=${_age_min}min"
done
[ "$_found_lock" = false ] && echo "  None"
echo ""

# ── Agent Logs (last 15 lines each) ──────────────────────────────────────

echo "## Recent Agent Logs"
for _log in supervisor/supervisor.log dev/dev-agent.log review/review.log \
            gardener/gardener.log planner/planner.log predictor/predictor.log; do
  _logpath="${FACTORY_ROOT}/${_log}"
  if [ -f "$_logpath" ]; then
    _log_age_min=$(( ($(date +%s) - $(stat -c %Y "$_logpath" 2>/dev/null || echo 0)) / 60 ))
    echo "### ${_log} (last modified ${_log_age_min}min ago)"
    tail -15 "$_logpath" 2>/dev/null || echo "(read failed)"
    echo ""
  fi
done

# ── CI Pipelines ──────────────────────────────────────────────────────────

echo "## CI Pipelines (${PROJECT_NAME})"

# Fetch pipelines via Woodpecker REST API (database-driver-agnostic)
_pipelines=$(woodpecker_api "/repos/${WOODPECKER_REPO_ID}/pipelines?perPage=50" 2>/dev/null || echo '[]')
_now=$(date +%s)

# Recent pipelines (finished in last 24h = 86400s), sorted by number DESC
_recent_ci=$(echo "$_pipelines" | jq -r --argjson now "$_now" '
  [.[] | select(.finished > 0) | select(($now - .finished) < 86400)]
  | sort_by(-.number) | .[0:10]
  | .[] | "\(.number)\t\(.status)\t\(.branch)\t\((.finished - .started) / 60 | floor)"' 2>/dev/null || echo "CI query failed")
echo "$_recent_ci"

# Stuck: running pipelines older than 20min (1200s)
_stuck=$(echo "$_pipelines" | jq --argjson now "$_now" '
  [.[] | select(.status == "running") | select(($now - .started) > 1200)] | length' 2>/dev/null || echo "?")

# Pending: pending pipelines older than 30min (1800s)
_pending=$(echo "$_pipelines" | jq --argjson now "$_now" '
  [.[] | select(.status == "pending") | select(($now - .created) > 1800)] | length' 2>/dev/null || echo "?")

echo "Stuck (>20min): ${_stuck}"
echo "Pending (>30min): ${_pending}"
echo ""

# ── Open PRs ──────────────────────────────────────────────────────────────

echo "## Open PRs (${PROJECT_NAME})"
_open_prs=$(forge_api GET "/pulls?state=open&limit=10" 2>/dev/null || echo "[]")
echo "$_open_prs" | jq -r '.[] | "#\(.number) [\(.head.ref)] \(.title) — updated \(.updated_at)"' 2>/dev/null || echo "No open PRs or query failed"
echo ""

# ── Backlog + In-Progress ─────────────────────────────────────────────────

echo "## Issue Status (${PROJECT_NAME})"
_backlog_count=$(forge_api GET "/issues?state=open&labels=backlog&type=issues&limit=50" 2>/dev/null | jq 'length' 2>/dev/null || echo "?")
_in_progress_count=$(forge_api GET "/issues?state=open&labels=in-progress&type=issues&limit=50" 2>/dev/null | jq 'length' 2>/dev/null || echo "?")
_blocked_count=$(forge_api GET "/issues?state=open&labels=blocked&type=issues&limit=50" 2>/dev/null | jq 'length' 2>/dev/null || echo "?")
echo "Backlog: ${_backlog_count}, In-progress: ${_in_progress_count}, Blocked: ${_blocked_count}"
echo ""

# ── Stale Worktrees ───────────────────────────────────────────────────────

echo "## Stale Worktrees"
_found_wt=false
for _wt in /tmp/*-worktree-* /tmp/*-review-*; do
  [ -d "$_wt" ] || continue
  _found_wt=true
  _wt_age_min=$(( ($(date +%s) - $(stat -c %Y "$_wt" 2>/dev/null || echo 0)) / 60 ))
  echo "  $(basename "$_wt"): ${_wt_age_min}min old"
done
[ "$_found_wt" = false ] && echo "  None"
echo ""

# ── Blocked Issues ────────────────────────────────────────────────────────

echo "## Blocked Issues"
_blocked_issues=$(forge_api GET "/issues?state=open&labels=blocked&type=issues&limit=50" 2>/dev/null || echo "[]")
_blocked_n=$(echo "$_blocked_issues" | jq 'length' 2>/dev/null || echo 0)
if [ "${_blocked_n:-0}" -gt 0 ]; then
  echo "$_blocked_issues" | jq -r '.[] | "  #\(.number): \(.title)"' 2>/dev/null || echo "  (query failed)"
else
  echo "  None"
fi
echo ""

# ── Pending Vault Items ───────────────────────────────────────────────────

echo "## Pending Vault Items"
_found_vault=false
# Use OPS_VAULT_ROOT if set (from supervisor-run.sh degraded mode detection), otherwise default to OPS_REPO_ROOT
_va_root="${OPS_VAULT_ROOT:-${OPS_REPO_ROOT}/vault/pending}"
for _vf in "${_va_root}"/*.md; do
  [ -f "$_vf" ] || continue
  _found_vault=true
  _vtitle=$(grep -m1 '^# ' "$_vf" | sed 's/^# //' || basename "$_vf")
  echo "  $(basename "$_vf"): ${_vtitle}"
done
[ "$_found_vault" = false ] && echo "  None"
echo ""

# ── Woodpecker Agent Health ────────────────────────────────────────────────

echo "## Woodpecker Agent Health"

# Check WP agent container health status
_wp_container="disinto-woodpecker-agent"
_wp_health_status="unknown"
_wp_health_start=""

if command -v docker &>/dev/null; then
  # Get health status via docker inspect
  _wp_health_status=$(docker inspect "$_wp_container" --format '{{.State.Health.Status}}' 2>/dev/null || echo "not_found")
  if [ "$_wp_health_status" = "not_found" ] || [ -z "$_wp_health_status" ]; then
    # Container may not exist or not have health check configured
    _wp_health_status=$(docker inspect "$_wp_container" --format '{{.State.Status}}' 2>/dev/null || echo "not_found")
  fi

  # Get container start time for age calculation
  _wp_start_time=$(docker inspect "$_wp_container" --format '{{.State.StartedAt}}' 2>/dev/null || echo "")
  if [ -n "$_wp_start_time" ] && [ "$_wp_start_time" != "0001-01-01T00:00:00Z" ]; then
    _wp_health_start=$(date -d "$_wp_start_time" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$_wp_start_time")
  fi
fi

echo "Container: $_wp_container"
echo "Status: $_wp_health_status"
[ -n "$_wp_health_start" ] && echo "Started: $_wp_health_start"

# Check for gRPC errors in agent logs (last 20 minutes)
_wp_grpc_errors=0
if [ "$_wp_health_status" != "not_found" ] && [ -n "$_wp_health_status" ]; then
  _wp_grpc_errors=$(docker logs --since 20m "$_wp_container" 2>&1 | grep -c 'grpc error' || echo "0")
  echo "gRPC errors (last 20m): $_wp_grpc_errors"
fi

# Fast-failure heuristic: check for pipelines completing in <60s
_wp_fast_failures=0
_wp_recent_failures=""
if [ -n "${WOODPECKER_REPO_ID:-}" ] && [ "${WOODPECKER_REPO_ID}" != "0" ]; then
  _now=$(date +%s)
  _pipelines=$(woodpecker_api "/repos/${WOODPECKER_REPO_ID}/pipelines?perPage=100" 2>/dev/null || echo '[]')

  # Count failures with duration < 60s in last 15 minutes
  _wp_fast_failures=$(echo "$_pipelines" | jq --argjson now "$_now" '
    [.[] | select(.status == "failure") | select((.finished - .started) < 60) | select(($now - .finished) < 900)]
    | length' 2>/dev/null || echo "0")

  if [ "$_wp_fast_failures" -gt 0 ]; then
    _wp_recent_failures=$(echo "$_pipelines" | jq -r --argjson now "$_now" '
      [.[] | select(.status == "failure") | select((.finished - .started) < 60) | select(($now - .finished) < 900)]
      | .[] | "\(.number)\t\((.finished - .started))s"' 2>/dev/null || echo "")
  fi
fi

echo "Fast-fail pipelines (<60s, last 15m): $_wp_fast_failures"
if [ -n "$_wp_recent_failures" ] && [ "$_wp_fast_failures" -gt 0 ]; then
  echo "Recent failures:"
  echo "$_wp_recent_failures" | while IFS=$'\t' read -r _num _dur; do
    echo "  #$_num: ${_dur}"
  done
fi

# Determine overall WP agent health
_wp_agent_healthy=true
_wp_health_reason=""

if [ "$_wp_health_status" = "not_found" ]; then
  _wp_agent_healthy=false
  _wp_health_reason="Container not running"
elif [ "$_wp_health_status" = "unhealthy" ]; then
  _wp_agent_healthy=false
  _wp_health_reason="Container health check failed"
elif [ "$_wp_health_status" != "running" ]; then
  _wp_agent_healthy=false
  _wp_health_reason="Container not in running state: $_wp_health_status"
elif [ "$_wp_grpc_errors" -ge 3 ]; then
  _wp_agent_healthy=false
  _wp_health_reason="High gRPC error count (>=3 in 20m)"
elif [ "$_wp_fast_failures" -ge 3 ]; then
  _wp_agent_healthy=false
  _wp_health_reason="High fast-failure count (>=3 in 15m)"
fi

echo ""
echo "WP Agent Health: $([ "$_wp_agent_healthy" = true ] && echo "healthy" || echo "UNHEALTHY")"
[ -n "$_wp_health_reason" ] && echo "Reason: $_wp_health_reason"
echo ""

# ── WP Agent Health History (for idempotency) ──────────────────────────────

echo "## WP Agent Health History"
# Track last restart timestamp to avoid duplicate restarts in same run
_WP_HEALTH_HISTORY_FILE="${DISINTO_LOG_DIR}/supervisor/wp-agent-health.history"
_wp_last_restart="never"
_wp_last_restart_ts=0

if [ -f "$_WP_HEALTH_HISTORY_FILE" ]; then
  _wp_last_restart_ts=$(grep -m1 '^LAST_RESTART_TS=' "$_WP_HEALTH_HISTORY_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
  if [ -n "$_wp_last_restart_ts" ] && [ "$_wp_last_restart_ts" -gt 0 ] 2>/dev/null; then
    _wp_last_restart=$(date -d "@$_wp_last_restart_ts" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$_wp_last_restart_ts")
  fi
fi
echo "Last restart: $_wp_last_restart"
echo ""
