#!/usr/bin/env bash
# =============================================================================
# prediction-poll.sh — Cron wrapper for prediction-agent (per-project)
#
# Runs hourly. Guards against concurrent runs and low memory.
# Iterates over all registered projects and runs prediction-agent.sh for each.
#
# Cron: 0 * * * * /path/to/disinto/planner/prediction-poll.sh
# Log:  tail -f /path/to/disinto/planner/prediction.log
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"

LOG_FILE="$SCRIPT_DIR/prediction.log"
# Global lock — projects are processed serially. If a single run takes longer
# than the cron interval (1h), the next cron invocation will find the lock held
# and exit silently. That is acceptable: LLM calls are cheap to skip.
LOCK_FILE="/tmp/prediction-poll.lock"
PROJECTS_DIR="$FACTORY_ROOT/projects"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Lock ──────────────────────────────────────────────────────────────────
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || true)
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "poll: prediction running (PID $LOCK_PID)"
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

log "--- Prediction poll start ---"

# ── Iterate over projects ─────────────────────────────────────────────────
PROJECT_COUNT=0
if [ -d "$PROJECTS_DIR" ]; then
  for project_toml in "$PROJECTS_DIR"/*.toml; do
    [ -f "$project_toml" ] || continue
    PROJECT_COUNT=$((PROJECT_COUNT + 1))
    log "starting prediction-agent for $(basename "$project_toml")"
    if ! "$SCRIPT_DIR/prediction-agent.sh" "$project_toml"; then
      log "prediction-agent exited non-zero for $(basename "$project_toml")"
    fi
  done
fi

if [ "$PROJECT_COUNT" -eq 0 ]; then
  log "No projects/*.toml found — running prediction-agent with .env defaults"
  if ! "$SCRIPT_DIR/prediction-agent.sh"; then
    log "prediction-agent exited non-zero"
  fi
fi

log "--- Prediction poll done ---"
