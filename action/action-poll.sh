#!/usr/bin/env bash
# action-poll.sh — Cron scheduler: find open 'action' issues, spawn action-agent
#
# An issue is ready for action if:
#   - It is open and labeled 'action'
#   - No tmux session named action-{issue_num} is already active
#
# Usage:
#   cron every 10min
#   action-poll.sh [projects/foo.toml]   # optional project config

set -euo pipefail

export PROJECT_TOML="${1:-}"
source "$(dirname "$0")/../lib/env.sh"

LOGFILE="${FACTORY_ROOT}/action/action-poll-${PROJECT_NAME:-harb}.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
  printf '[%s] poll: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

# --- Memory guard ---
AVAIL_MB=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
if [ "$AVAIL_MB" -lt 2000 ]; then
  log "SKIP: only ${AVAIL_MB}MB available (need 2000MB)"
  matrix_send "action" "⚠️ Low memory (${AVAIL_MB}MB) — skipping action-poll" 2>/dev/null || true
  exit 0
fi

# --- Find open 'action' issues ---
log "scanning for open action issues"
ACTION_ISSUES=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${CODEBERG_API}/issues?state=open&labels=action&limit=50&type=issues") || true

if [ -z "$ACTION_ISSUES" ] || [ "$ACTION_ISSUES" = "null" ]; then
  log "no action issues found"
  exit 0
fi

COUNT=$(printf '%s' "$ACTION_ISSUES" | jq 'length')
if [ "$COUNT" -eq 0 ]; then
  log "no action issues found"
  exit 0
fi

log "found ${COUNT} open action issue(s)"

# Spawn action-agent for each issue that has no active tmux session.
# Only one agent is spawned per poll to avoid memory pressure; the next
# poll picks up remaining issues.
for i in $(seq 0 $((COUNT - 1))); do
  ISSUE_NUM=$(printf '%s' "$ACTION_ISSUES" | jq -r ".[$i].number")
  SESSION="action-${ISSUE_NUM}"

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    log "issue #${ISSUE_NUM}: session ${SESSION} already active, skipping"
    continue
  fi

  LOCKFILE="/tmp/action-agent-${ISSUE_NUM}.lock"
  if [ -f "$LOCKFILE" ]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
      log "issue #${ISSUE_NUM}: agent starting (PID ${LOCK_PID}), skipping"
      continue
    fi
  fi

  log "spawning action-agent for issue #${ISSUE_NUM}"
  nohup "${SCRIPT_DIR}/action-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
  log "started action-agent PID $! for issue #${ISSUE_NUM}"
  break
done
