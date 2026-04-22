#!/usr/bin/env bash
# supervisor/actions/cleanup-phase-files.sh — P4 stale phase file cleanup
#
# Auto-removes PHASE:escalate files whose parent issue/PR is confirmed closed.
# Grace period: 24h after issue closure to avoid race conditions.
#
# Sources: supervisor/preflight.sh Stale Phase Cleanup block (lines 155-197).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept project config from argument; default to disinto
export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
export FORGE_TOKEN_OVERRIDE="${FORGE_SUPERVISOR_TOKEN:-}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"

LOG_FILE="${DISINTO_LOG_DIR}/supervisor/supervisor.log"

# Override log() to append to supervisor-specific log file
log() {
  local agent="${LOG_AGENT:-supervisor}"
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$agent" "$*" >> "$LOG_FILE"
}

LOG_AGENT="supervisor"

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
    log "Cleaned phase file $(basename "$_pf") — issue #${_issue_num} closed at ${_closed_at}"
  else
    _remaining_h=$(( (86400 - _elapsed) / 3600 ))
    log "Grace: $(basename "$_pf") — issue #${_issue_num} closed, ${_remaining_h}h remaining"
  fi
done

if [ "$_found_stale" = false ]; then
  log "No stale PHASE:escalate files to clean"
fi
