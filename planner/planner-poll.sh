#!/usr/bin/env bash
# =============================================================================
# planner-poll.sh — Cron wrapper: files action issue for run-planner formula
#
# Runs weekly (or on-demand). Guards against concurrent runs and low memory.
# Files an action issue referencing formulas/run-planner.toml; the action-agent
# picks it up and executes the planning steps in an interactive Claude session.
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

# ── Dedup: skip if an open run-planner action issue already exists ────────
OPEN_ACTIONS=$(codeberg_api GET "/issues?state=open&type=issues&labels=action&limit=50" 2>/dev/null || true)
if [ -n "$OPEN_ACTIONS" ] && [ "$OPEN_ACTIONS" != "null" ]; then
  EXISTING=$(printf '%s' "$OPEN_ACTIONS" | \
    jq '[.[] | select(.title | test("run-planner"))] | length' 2>/dev/null || echo 0)
  if [ "${EXISTING:-0}" -gt 0 ]; then
    log "poll: open run-planner action issue already exists — skipping"
    log "--- Planner poll done ---"
    exit 0
  fi
fi

# ── Fetch 'action' label ID ──────────────────────────────────────────────
ACTION_LABEL_ID=$(codeberg_api GET "/labels" 2>/dev/null | \
  jq -r '.[] | select(.name == "action") | .id' 2>/dev/null || true)

if [ -z "$ACTION_LABEL_ID" ]; then
  log "ERROR: 'action' label not found — cannot file planner issue"
  exit 1
fi

# ── File action issue ─────────────────────────────────────────────────────
ISSUE_BODY="---
formula: run-planner
model: opus
---

Periodic strategic planning run. The action-agent reads \`formulas/run-planner.toml\`
and executes the five phases: preflight, AGENTS.md update, prediction triage,
strategic planning (resource+leverage gap analysis), and memory update.

Filed automatically by \`planner-poll.sh\`."

PAYLOAD=$(jq -nc \
  --arg title "action: run-planner — periodic strategic planning" \
  --arg body "$ISSUE_BODY" \
  --argjson labels "[$ACTION_LABEL_ID]" \
  '{title: $title, body: $body, labels: $labels}')

RESULT=$(codeberg_api POST "/issues" -d "$PAYLOAD" 2>/dev/null || true)
ISSUE_NUM=$(printf '%s' "$RESULT" | jq -r '.number // empty' 2>/dev/null || true)

if [ -z "$ISSUE_NUM" ]; then
  log "ERROR: failed to create action issue for run-planner"
  exit 1
fi

log "Filed action issue #${ISSUE_NUM} for run-planner formula"
matrix_send "planner" "Filed action #${ISSUE_NUM}: run-planner — periodic strategic planning" 2>/dev/null || true

log "--- Planner poll done ---"
