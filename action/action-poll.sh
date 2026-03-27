#!/usr/bin/env bash
# action-poll.sh — Cron scheduler: find open 'action' issues, spawn action-agent
#
# An issue is ready for action if:
#   - It is open and labeled 'action'
#   - No tmux session named action-{project}-{issue_num} is already active
#
# Usage:
#   cron every 10min
#   action-poll.sh [projects/foo.toml]   # optional project config

set -euo pipefail

export PROJECT_TOML="${1:-}"
source "$(dirname "$0")/../lib/env.sh"
# Use action-bot's own Forgejo identity (#747)
FORGE_TOKEN="${FORGE_ACTION_TOKEN:-${FORGE_TOKEN}}"
# shellcheck source=../lib/guard.sh
source "$(dirname "$0")/../lib/guard.sh"
check_active action

LOGFILE="${DISINTO_LOG_DIR}/action/action-poll-${PROJECT_NAME:-default}.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
  printf '[%s] poll: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

# --- Memory guard ---
memory_guard 2000

# --- Find open 'action' issues ---
log "scanning for open action issues"
ACTION_ISSUES=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_API}/issues?state=open&labels=action&limit=50&type=issues") || true

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
  SESSION="action-${PROJECT_NAME}-${ISSUE_NUM}"

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
  nohup "${SCRIPT_DIR}/action-agent.sh" "$ISSUE_NUM" "$PROJECT_TOML" >> "$LOGFILE" 2>&1 &
  log "started action-agent PID $! for issue #${ISSUE_NUM}"
  break
done
