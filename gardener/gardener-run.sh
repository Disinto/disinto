#!/usr/bin/env bash
# =============================================================================
# gardener-run.sh — Cron wrapper: files action issue for run-gardener formula
#
# Runs 2x/day (or on-demand). Guards against concurrent runs and low memory.
# Files an action issue referencing formulas/run-gardener.toml; the action-agent
# picks it up and executes the gardener steps in an interactive Claude session.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Load shared environment (with optional project TOML override)
# Usage: gardener-run.sh [projects/harb.toml]
export PROJECT_TOML="${1:-}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"

LOG_FILE="$SCRIPT_DIR/gardener.log"
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

# ── Dedup: skip if an open run-gardener action issue already exists ───────
OPEN_ACTIONS=$(codeberg_api GET "/issues?state=open&type=issues&labels=action&limit=50" 2>/dev/null || true)
if [ -n "$OPEN_ACTIONS" ] && [ "$OPEN_ACTIONS" != "null" ]; then
  EXISTING=$(printf '%s' "$OPEN_ACTIONS" | \
    jq '[.[] | select(.title | test("run-gardener"))] | length' 2>/dev/null || echo 0)
  if [ "${EXISTING:-0}" -gt 0 ]; then
    log "poll: open run-gardener action issue already exists — skipping"
    log "--- Gardener run done ---"
    exit 0
  fi
fi

# ── Fetch 'action' label ID ──────────────────────────────────────────────
ACTION_LABEL_ID=$(codeberg_api GET "/labels" 2>/dev/null | \
  jq -r '.[] | select(.name == "action") | .id' 2>/dev/null || true)

if [ -z "$ACTION_LABEL_ID" ]; then
  log "ERROR: 'action' label not found — cannot file gardener issue"
  exit 1
fi

# ── File action issue ─────────────────────────────────────────────────────
ISSUE_BODY="---
formula: run-gardener
model: opus
---

Periodic gardener housekeeping run. The action-agent reads \`formulas/run-gardener.toml\`
and executes the steps: preflight, grooming, blocked-review, CI escalation recipes,
AGENTS.md update, and commit-and-pr.

Filed automatically by \`gardener-run.sh\`."

PAYLOAD=$(jq -nc \
  --arg title "action: run-gardener — periodic housekeeping" \
  --arg body "$ISSUE_BODY" \
  --argjson labels "[$ACTION_LABEL_ID]" \
  '{title: $title, body: $body, labels: $labels}')

RESULT=$(codeberg_api POST "/issues" -d "$PAYLOAD" 2>/dev/null || true)
ISSUE_NUM=$(printf '%s' "$RESULT" | jq -r '.number // empty' 2>/dev/null || true)

if [ -z "$ISSUE_NUM" ]; then
  log "ERROR: failed to create action issue for run-gardener"
  exit 1
fi

log "Filed action issue #${ISSUE_NUM} for run-gardener formula"
matrix_send "gardener" "Filed action #${ISSUE_NUM}: run-gardener — periodic housekeeping" 2>/dev/null || true

log "--- Gardener run done ---"
