#!/usr/bin/env bash
# =============================================================================
# exec-briefing.sh — Daily morning briefing via the executive assistant
#
# Cron entry: 0 7 * * * /path/to/disinto/exec/exec-briefing.sh [project.toml]
#
# Sends a briefing prompt to exec-inject.sh, which handles session management,
# response capture, and Matrix posting. No duplication of compass/context logic.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# shellcheck source=../lib/guard.sh
source "$FACTORY_ROOT/lib/guard.sh"

LOG_FILE="$SCRIPT_DIR/exec.log"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Guards ────────────────────────────────────────────────────────────────
check_active exec

# Memory guard
AVAIL_MB=$(free -m 2>/dev/null | awk '/Mem:/{print $7}' || echo 9999)
if [ "${AVAIL_MB:-0}" -lt 2000 ]; then
  log "SKIP: low memory (${AVAIL_MB}MB available)"
  exit 0
fi

log "--- Exec briefing start ---"

BRIEFING_PROMPT="Daily briefing request (automated, $(date -u '+%Y-%m-%d')):

Produce a concise morning briefing covering:
1. Pipeline status — blocked issues, failing CI, stale PRs?
2. Recent activity — what merged/closed in the last 24h?
3. Backlog health — depth, underspecified issues?
4. Predictions — any unreviewed from the predictor?
5. Concerns — anything needing human attention today?

Check the forge API, git log, agent journals, and issue tracker.
Under 500 words. Lead with what needs action."

bash "$SCRIPT_DIR/exec-inject.sh" \
  "briefing-cron" \
  "$BRIEFING_PROMPT" \
  "" \
  "$PROJECT_TOML" || {
    log "briefing injection failed"
    exit 1
  }

log "--- Exec briefing done ---"
