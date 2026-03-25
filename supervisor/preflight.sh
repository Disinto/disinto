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
            gardener/gardener.log planner/planner.log predictor/predictor.log \
            action/action.log; do
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

_recent_ci=$(wpdb -A -c "
  SELECT number, status, branch,
         ROUND(EXTRACT(EPOCH FROM (to_timestamp(finished) - to_timestamp(started)))/60)::int as dur_min
  FROM pipelines
  WHERE repo_id = ${WOODPECKER_REPO_ID}
    AND finished > 0
    AND to_timestamp(finished) > now() - interval '24 hours'
  ORDER BY number DESC LIMIT 10;" 2>/dev/null || echo "CI database query failed")
echo "$_recent_ci"

_stuck=$(wpdb -c "
  SELECT count(*) FROM pipelines
  WHERE repo_id=${WOODPECKER_REPO_ID}
    AND status='running'
    AND EXTRACT(EPOCH FROM now() - to_timestamp(started)) > 1200;" 2>/dev/null | xargs || echo "?")

_pending=$(wpdb -c "
  SELECT count(*) FROM pipelines
  WHERE repo_id=${WOODPECKER_REPO_ID}
    AND status='pending'
    AND EXTRACT(EPOCH FROM now() - to_timestamp(created)) > 1800;" 2>/dev/null | xargs || echo "?")

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

# ── Escalation Replies from Matrix ────────────────────────────────────────

echo "## Escalation Replies (from Matrix)"
if [ -s /tmp/supervisor-escalation-reply ]; then
  cat /tmp/supervisor-escalation-reply
  echo ""
  echo "(Reply already consumed by supervisor-run.sh before this session)"
else
  echo "  None"
fi
echo ""
