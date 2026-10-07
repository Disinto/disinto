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
# shellcheck source=../lib/wp-agent-health.sh
source "$FACTORY_ROOT/lib/wp-agent-health.sh"

# ── Stale Phase Cleanup Function ──────────────────────────────────────────
# Auto-remove PHASE:escalate files whose parent issue/PR is confirmed closed.
# Grace period: 24h after issue closure to avoid race conditions.
#
# Named function for reuse by cleanup-phase-files.sh action script.
# Usage: __preflight_cleanup_stale_phases <fn>  where <fn> is echo|log|:
__preflight_cleanup_stale_phases() {
  local _out_fn="${1:-echo}"
  local _found_stale=false
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
      "$_out_fn" "  Cleaned: $(basename "$_pf") — issue #${_issue_num} closed at ${_closed_at}"
    else
      _remaining_h=$(( (86400 - _elapsed) / 3600 ))
      "$_out_fn" "  Grace: $(basename "$_pf") — issue #${_issue_num} closed, ${_remaining_h}h remaining"
    fi
  done
  [ "$_found_stale" = false ] && "$_out_fn" "  None"
}

# ── Research Runs Section ───────────────────────────────────────────────────
# Emits the "## Research Runs" section (run-ledger metrics, #1297) when
# ${OPS_REPO_ROOT}/runs exists; prints NOTHING otherwise — an absent ledger is
# not a failure. Reports:
#   - In-flight count: ledger rows with no `ended` or an empty `exit`
#   - per-run age ("Nmin old") for each in-flight row (heartbeat)
#   - Artifacts Disk usage % when ${OPS_REPO_ROOT}/artifacts exists
#   - Oldest open `judgment`-labeled issue age in hours, or `none`
#
# Named function so the acceptance test (tests/acceptance/issue-1322.sh) can
# extract and drive it hermetically (stubbed forge_api/date).
#
# Usage: __preflight_research_runs
__preflight_research_runs() {
  local _ops_root="${OPS_REPO_ROOT:-}"
  [ -n "$_ops_root" ] || return 0
  [ -d "${_ops_root}/runs" ] || return 0

  local _now
  _now=$(date +%s)

  # In-flight: ledger rows with no `ended` or an empty `exit`
  local _inflight=0
  local _inflight_lines=""
  local _run _rec_open _started_iso _started_epoch _run_age_min
  for _run in "${_ops_root}"/runs/*.json; do
    [ -f "$_run" ] || continue
    _rec_open=$(jq -r '
      ( ( has("ended") | not ) or (.ended == null) or (.ended == "") )
      or ( ( has("exit") | not ) or (.exit == null) or (.exit == "") )
    ' "$_run" 2>/dev/null || echo "false")
    [ "$_rec_open" = "true" ] || continue
    _inflight=$(( _inflight + 1 ))
    _started_iso=$(jq -r '.started // empty' "$_run" 2>/dev/null || echo "")
    _started_epoch=$(date -d "$_started_iso" +%s 2>/dev/null || echo "$_now")
    _run_age_min=$(( (_now - _started_epoch) / 60 ))
    [ "$_run_age_min" -gt 0 ] 2>/dev/null || _run_age_min=0
    _inflight_lines="${_inflight_lines}  $(basename "$_run" .json): ${_run_age_min}min old"$'\n'
  done

  echo "## Research Runs"
  echo "In-flight: ${_inflight}"
  if [ -n "$_inflight_lines" ]; then
    printf '%s' "$_inflight_lines"
  fi

  # Artifacts disk pressure (research-run payloads live under runs/artifacts/)
  local _artifacts_dir="${_ops_root}/artifacts"
  if [ -d "$_artifacts_dir" ]; then
    local _artifacts_pct
    _artifacts_pct=$(df -P "$_artifacts_dir" 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')
    case "${_artifacts_pct:-}" in
      '' | *[!0-9]*) _artifacts_pct=0 ;;
    esac
    echo "Artifacts Disk: ${_artifacts_pct}% used"
  else
    echo "Artifacts Disk: n/a"
  fi

  # Oldest open issue carrying the `judgment` label (a research run awaiting a
  # human verdict) — age in hours, or `none`
  local _judgment_json
  _judgment_json=$(forge_api GET "/issues?state=open&labels=judgment&type=issues&limit=50" 2>/dev/null || echo "[]")
  local _judg_ages
  _judg_ages=$(printf '%s' "$_judgment_json" | jq -r '.[] | "\(.number)\t\(.created_at // "")"' 2>/dev/null || echo "")
  local _judg_oldest_h="" _judg_oldest_num="" _num _created _ep _age_h
  while IFS=$'\t' read -r _num _created; do
    [ -n "${_created:-}" ] || continue
    _ep=$(date -d "$_created" +%s 2>/dev/null || echo 0)
    [ "${_ep:-0}" -gt 0 ] 2>/dev/null || continue
    _age_h=$(( (_now - _ep) / 3600 ))
    [ "$_age_h" -ge 0 ] 2>/dev/null || _age_h=0
    if [ -z "$_judg_oldest_h" ] || [ "$_age_h" -gt "$_judg_oldest_h" ]; then
      _judg_oldest_h="$_age_h"
      _judg_oldest_num="$_num"
    fi
  done <<< "$_judg_ages"
  if [ -n "$_judg_oldest_h" ]; then
    echo "Oldest judgment: ${_judg_oldest_h}h (#${_judg_oldest_num})"
  else
    echo "Oldest judgment: none"
  fi
  echo ""
  return 0
}

# wp_agent_health_verdict AGE FAST_FAILURES — healthy | UNHEALTHY | unknown.
# UNHEALTHY when AGE is above WP_AGENT_CONTACT_MAX_S (default 300) or
# FAST_FAILURES is 3 or more. unknown when AGE is empty and fast failures
# are below 3. Otherwise healthy. (#1698)
wp_agent_health_verdict() {
  local age="${1-}"
  local fast="${2:-0}"
  local max="${WP_AGENT_CONTACT_MAX_S:-300}"
  if [ -z "$fast" ]; then
    fast=0
  fi
  if [ -n "$age" ] && [ "$age" -gt "$max" ]; then
    printf '%s\n' UNHEALTHY
    return 0
  fi
  if [ "$fast" -ge 3 ]; then
    printf '%s\n' UNHEALTHY
    return 0
  fi
  if [ -z "$age" ]; then
    printf '%s\n' unknown
    return 0
  fi
  printf '%s\n' healthy
}

# public_endpoints_section — probe PUBLIC_URLS from outside the factory (#1923).
#
# Space-separated URLs in PUBLIC_URLS. Unset or empty: print only
# "Public Endpoints: unconfigured" (no section header, no state change).
# Otherwise print "## Public Endpoints", one "<url>: <code> (failing ticks: <n>)"
# line per URL, then "Public Endpoints: DOWN" if any URL has failed on 2 or
# more consecutive ticks, else "Public Endpoints: OK".
#
# A URL is up on 2xx or 3xx (curl -s -o /dev/null -w '%{http_code}' -m 10).
# Consecutive failing ticks live in
# ${SUPERVISOR_STATE_DIR:-/home/agent/data/supervisor}/public-endpoints.state
# as "<count> <url>" lines. A failure increments; an up resets to 0.
# Monitor only: the recipe files an incident and attempts no remedy.
public_endpoints_section() {
  local urls="${PUBLIC_URLS-}"
  if [ -z "$urls" ]; then
    echo "Public Endpoints: unconfigured"
    return 0
  fi

  local state_dir="${SUPERVISOR_STATE_DIR:-/home/agent/data/supervisor}"
  local state_file="${state_dir}/public-endpoints.state"
  mkdir -p "$state_dir"

  echo "## Public Endpoints"

  local -a url_list=()
  local url code old n line count rest new_state="" tmp_file
  local any_down=0
  read -r -a url_list <<< "$urls"

  for url in "${url_list[@]}"; do
    code=""
    # Network errors print 000 (or nothing) and exit non-zero; that is a failure,
    # not a reason to abort the rest of preflight.
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$url" 2>/dev/null)" || code="${code:-000}"
    case "$code" in
      ''|*[!0-9]*) code=000 ;;
    esac

    old=0
    if [ -f "$state_file" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        count="${line%% *}"
        rest="${line#* }"
        if [ "$rest" = "$url" ]; then
          case "$count" in
            ''|*[!0-9]*) old=0 ;;
            *) old="$count" ;;
          esac
          break
        fi
      done < "$state_file"
    fi

    case "$code" in
      2[0-9][0-9]|3[0-9][0-9]) n=0 ;;
      *) n=$((old + 1)) ;;
    esac
    if [ "$n" -ge 2 ]; then
      any_down=1
    fi
    printf '%s: %s (failing ticks: %s)\n' "$url" "$code" "$n"
    new_state="${new_state}${n} ${url}"$'\n'
  done

  tmp_file="${state_file}.tmp"
  printf '%s' "$new_state" > "$tmp_file"
  mv -f "$tmp_file" "$state_file"

  if [ "$any_down" -eq 1 ]; then
    echo "Public Endpoints: DOWN"
  else
    echo "Public Endpoints: OK"
  fi
}

# ── Side-effect: preflight output (only when executed directly) ──────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

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

# ── Stale Phase Cleanup (inline section header) ──────────────────────────

echo "## Stale Phase Cleanup"
__preflight_cleanup_stale_phases echo
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

# ── Research Runs (run-ledger, #1297) ─────────────────────────────────────
# Emitted only when ${OPS_REPO_ROOT}/runs exists (function prints nothing
# otherwise — absence is not a failure, see __preflight_research_runs).

__preflight_research_runs

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

# The supervisor image has no docker CLI, and under Nomad the agent
# container is not named disinto-woodpecker-agent. The server's agent
# list is the health signal (#1698).
age="$(wp_agent_last_contact_age)" || age=""
if [ -n "$age" ]; then
  echo "Last contact: ${age}s ago"
else
  echo "Last contact: unknown"
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

# UNHEALTHY when the newest contact is stale or fast failures pile up;
# unknown when the API gave no age and fast failures are below 3 (#1698).
_wp_verdict="$(wp_agent_health_verdict "$age" "$_wp_fast_failures")"
_wp_health_reason=""
if [ "$_wp_verdict" = "UNHEALTHY" ]; then
  if [ -n "$age" ] && [ "$age" -gt "${WP_AGENT_CONTACT_MAX_S:-300}" ]; then
    _wp_health_reason="Last contact ${age}s ago (max ${WP_AGENT_CONTACT_MAX_S:-300}s)"
  fi
  if [ "${_wp_fast_failures:-0}" -ge 3 ]; then
    if [ -n "$_wp_health_reason" ]; then
      _wp_health_reason="${_wp_health_reason}; high fast-failure count (>=3 in 15m)"
    else
      _wp_health_reason="High fast-failure count (>=3 in 15m)"
    fi
  fi
fi

echo ""
echo "WP Agent Health: $_wp_verdict"
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

# ── Public Endpoints (#1923) ──────────────────────────────────────────────
# The function prints "## Public Endpoints" when PUBLIC_URLS is set. When it
# is unset or empty the function prints only the unconfigured line — open the
# section here so that line is not folded into the previous section.

if [ -z "${PUBLIC_URLS-}" ]; then
  echo "## Public Endpoints"
fi
public_endpoints_section
echo ""

fi
