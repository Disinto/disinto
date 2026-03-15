#!/usr/bin/env bash
# =============================================================================
# planner-poll.sh — Cron wrapper for planner-agent
#
# Runs weekly (or on-demand). Guards against concurrent runs and low memory.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"

LOG_FILE="$SCRIPT_DIR/planner.log"
LOCK_FILE="/tmp/planner-poll.lock"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Lock ──────────────────────────────────────────────────────────────────
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || true)
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "poll: planner running (PID $LOCK_PID)"
    exit 0
  fi
  rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# ── Memory guard ──────────────────────────────────────────────────────────
AVAIL_MB=$(free -m | awk '/Mem:/{print $7}')
if [ "${AVAIL_MB:-0}" -lt 2000 ]; then
  log "poll: skipping — only ${AVAIL_MB}MB available (need 2000)"
  exit 0
fi

log "--- Planner poll start ---"

# ── Run planner agent ─────────────────────────────────────────────────────
"$SCRIPT_DIR/planner-agent.sh" 2>&1 | while IFS= read -r line; do
  log "  $line"
done

EXIT_CODE=${PIPESTATUS[0]}
if [ "$EXIT_CODE" -ne 0 ]; then
  log "poll: planner-agent exited with code $EXIT_CODE"
fi

log "--- Planner poll done ---"
