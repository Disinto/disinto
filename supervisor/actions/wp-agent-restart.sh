#!/usr/bin/env bash
# supervisor/actions/wp-agent-restart.sh — P2 Woodpecker agent recovery
#
# Detects unhealthy WP agent, restarts container (5-min cooldown), then scans
# for ci_exhausted issues updated in the last 30 minutes and recovers them.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared setup (header, env, log, OPS)
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh" "$@"

# WP agent container name (configurable via env var)
export WP_AGENT_CONTAINER_NAME="${WP_AGENT_CONTAINER_NAME:-disinto-woodpecker-agent}"

# Health reason passed as $1 by the dispatch loop in supervisor-run.sh
_WP_HEALTH_REASON="${1:-}"

if [ -n "$_WP_HEALTH_REASON" ]; then
  log "WP agent detected as UNHEALTHY: $_WP_HEALTH_REASON"

  # ── Idempotency guard: 5-minute cooldown ────────────────────────────
  _WP_HEALTH_HISTORY_FILE="${DISINTO_LOG_DIR}/supervisor/wp-agent-health.history"
  _wp_last_restart_ts=0
  _wp_last_restart="never"
  if [ -f "$_WP_HEALTH_HISTORY_FILE" ]; then
    _wp_last_restart_ts=$(grep -m1 '^LAST_RESTART_TS=' "$_WP_HEALTH_HISTORY_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
    if [ -n "$_wp_last_restart_ts" ] && [ "$_wp_last_restart_ts" != "0" ] 2>/dev/null; then
      _wp_last_restart=$(date -d "@$_wp_last_restart_ts" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$_wp_last_restart_ts")
    fi
  fi

  _current_ts=$(date +%s)
  _restart_threshold=300  # 5 minutes between restarts

  if [ -z "$_wp_last_restart_ts" ] || [ "$_wp_last_restart_ts" = "0" ] || [ $((_current_ts - _wp_last_restart_ts)) -gt $_restart_threshold ]; then
    log "Triggering WP agent restart..."

    # Restart the WP agent container
    if docker restart "$WP_AGENT_CONTAINER_NAME" >/dev/null 2>&1; then
      _restart_time=$(date -u '+%Y-%m-%d %H:%M UTC')
      log "Successfully restarted WP agent container: $WP_AGENT_CONTAINER_NAME"

      # Update history file
      echo "LAST_RESTART_TS=$_current_ts" > "$_WP_HEALTH_HISTORY_FILE"
      echo "LAST_RESTART_TIME=$_restart_time" >> "$_WP_HEALTH_HISTORY_FILE"

      # Post recovery notice to journal
      _journal_file="${OPS_JOURNAL_ROOT}/$(date -u +%Y-%m-%d).md"
      if [ -f "$_journal_file" ]; then
        {
          echo ""
          echo "### WP Agent Recovery - $_restart_time"
          echo ""
          echo "WP agent was unhealthy: $_WP_HEALTH_REASON"
          echo "Container restarted automatically."
        } >> "$_journal_file"
      fi

      # ── ci_exhausted issue recovery (delegated to action script) ────
      log "Scanning for ci_exhausted issues updated in last 30 minutes..."
      bash "$SCRIPT_DIR/sweep-ci-exhausted.sh" "${PROJECT_TOML:-}"

      log "WP agent restart and issue recovery complete"
    else
      log "ERROR: Failed to restart WP agent container"
    fi
  else
    log "WP agent restart already performed in this run (since $_wp_last_restart), skipping"
  fi
fi
