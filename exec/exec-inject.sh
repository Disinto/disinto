#!/usr/bin/env bash
# =============================================================================
# exec-inject.sh — Inject a message into the exec session and capture response
#
# Called by the matrix listener when a message arrives for the exec agent.
# Handles session lifecycle: spawn if needed, inject, capture, post to Matrix.
#
# Usage:
#   exec-inject.sh <sender> <message_body> [thread_id] [project_toml]
#
# Response capture uses the idle marker from lib/agent-session.sh — no
# special output format required from Claude.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

SENDER="${1:?Usage: exec-inject.sh <sender> <message> [thread_id] [project.toml]}"
MESSAGE="${2:?}"
THREAD_ID="${3:-}"
export PROJECT_TOML="${4:-$FACTORY_ROOT/projects/disinto.toml}"

# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# shellcheck source=../lib/agent-session.sh
source "$FACTORY_ROOT/lib/agent-session.sh"

LOG_FILE="$SCRIPT_DIR/exec.log"
SESSION_NAME="exec-${PROJECT_NAME}"
RESPONSE_TIMEOUT="${EXEC_RESPONSE_TIMEOUT:-300}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Ensure session exists ───────────────────────────────────────────────
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  log "no active exec session — spawning"
  bash "$SCRIPT_DIR/exec-session.sh" "$PROJECT_TOML" 2>>"$LOG_FILE" || {
    log "ERROR: failed to start exec session"
    [ -n "$THREAD_ID" ] && matrix_send "exec" "❌ Could not start executive assistant session" "$THREAD_ID" >/dev/null 2>&1 || true
    exit 1
  }
  # Wait for Claude to process the initial prompt
  agent_wait_for_claude_ready "$SESSION_NAME" 120 || {
    log "ERROR: session not ready after spawn"
    exit 1
  }
fi

# ── Snapshot pane before injection ──────────────────────────────────────
BEFORE_LINES=$(tmux capture-pane -t "$SESSION_NAME" -p 2>/dev/null | wc -l)
IDLE_MARKER="/tmp/claude-idle-${SESSION_NAME}.ts"
rm -f "$IDLE_MARKER"

# ── Inject message ──────────────────────────────────────────────────────
INJECT_MSG="Message from ${SENDER}:

${MESSAGE}"

log "injecting message from ${SENDER}: ${MESSAGE:0:100}"
agent_inject_into_session "$SESSION_NAME" "$INJECT_MSG"

# ── Wait for Claude to finish responding ────────────────────────────────
ELAPSED=0
POLL=5
while [ "$ELAPSED" -lt "$RESPONSE_TIMEOUT" ]; do
  sleep "$POLL"
  ELAPSED=$((ELAPSED + POLL))

  if [ -f "$IDLE_MARKER" ]; then
    log "response complete after ${ELAPSED}s"
    break
  fi

  if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    log "ERROR: exec session died while waiting for response"
    [ -n "$THREAD_ID" ] && matrix_send "exec" "❌ Executive assistant session ended unexpectedly" "$THREAD_ID" >/dev/null 2>&1 || true
    exit 1
  fi
done

if [ "$ELAPSED" -ge "$RESPONSE_TIMEOUT" ]; then
  log "WARN: response timeout after ${RESPONSE_TIMEOUT}s"
  [ -n "$THREAD_ID" ] && matrix_send "exec" "⚠️ Still thinking... (response not ready within ${RESPONSE_TIMEOUT}s)" "$THREAD_ID" >/dev/null 2>&1 || true
  exit 0
fi

# ── Capture response (pane diff) ────────────────────────────────────────
RESPONSE=$(tmux capture-pane -t "$SESSION_NAME" -p -S -500 2>/dev/null \
  | tail -n +"$((BEFORE_LINES + 1))" \
  | grep -v '^❯' | grep -v '^$' \
  | head -100)

if [ -z "$RESPONSE" ]; then
  log "WARN: empty response captured"
  RESPONSE="(processed your message but produced no visible output)"
fi

# ── Post response to Matrix ────────────────────────────────────────────
if [ ${#RESPONSE} -gt 3500 ]; then
  RESPONSE="${RESPONSE:0:3500}

(truncated — full response in exec journal)"
fi

if [ -n "$THREAD_ID" ]; then
  matrix_send "exec" "$RESPONSE" "$THREAD_ID" >/dev/null 2>&1 || true
else
  matrix_send "exec" "$RESPONSE" "" "exec" >/dev/null 2>&1 || true
fi
log "response posted to Matrix"

# ── Journal the exchange ───────────────────────────────────────────────
JOURNAL_DIR="$PROJECT_REPO_ROOT/exec/journal"
mkdir -p "$JOURNAL_DIR"
{
  echo ""
  echo "## $(date -u +%H:%M) UTC — ${SENDER}"
  echo ""
  echo "**Q:** ${MESSAGE}"
  echo ""
  echo "**A:** ${RESPONSE}"
  echo ""
  echo "---"
} >> "$JOURNAL_DIR/$(date -u +%Y-%m-%d).md"
log "exchange logged to journal"
