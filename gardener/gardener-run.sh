#!/usr/bin/env bash
# =============================================================================
# gardener-run.sh — Cron wrapper: files action issue for run-gardener formula
#
# Runs 2x/day (or on-demand). Guards against concurrent runs and low memory.
# Files an action issue referencing formulas/run-gardener.toml; the action-agent
# picks it up and executes the gardener steps in an interactive Claude session.
# =============================================================================
set -euo pipefail

FACTORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Load shared environment (with optional project TOML override)
# Usage: gardener-run.sh [projects/harb.toml]
export PROJECT_TOML="${1:-}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# shellcheck source=../lib/file-action-issue.sh
source "$FACTORY_ROOT/lib/file-action-issue.sh"

LOG_FILE="$FACTORY_ROOT/gardener/gardener.log"
LOCK_FILE="/tmp/gardener-run.lock"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Lock ──────────────────────────────────────────────────────────────────
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || true)
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "poll: gardener-run running (PID $LOCK_PID)"
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

log "--- Gardener run start ---"

# ── File action issue for run-gardener formula ────────────────────────────
ISSUE_BODY="---
formula: run-gardener
model: opus
---

Periodic gardener housekeeping run. The action-agent reads \`formulas/run-gardener.toml\`
and executes the steps: preflight, grooming, blocked-review, CI escalation recipes,
AGENTS.md update, and commit-and-pr.

Filed automatically by \`gardener-run.sh\`."

_rc=0
file_action_issue "run-gardener" "action: run-gardener — periodic housekeeping" "$ISSUE_BODY" || _rc=$?
case "$_rc" in
  0) ;;
  1) log "poll: open run-gardener action issue already exists — skipping"
     log "--- Gardener run done ---"
     exit 0 ;;
  2) log "ERROR: 'action' label not found — cannot file gardener issue"
     exit 1 ;;
  *) log "ERROR: failed to create action issue for run-gardener"
     exit 1 ;;
esac

log "Filed action issue #${FILED_ISSUE_NUM} for run-gardener formula"
matrix_send "gardener" "Filed action #${FILED_ISSUE_NUM}: run-gardener — periodic housekeeping" 2>/dev/null || true

log "--- Gardener run done ---"
