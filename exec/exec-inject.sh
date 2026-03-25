#!/usr/bin/env bash
# =============================================================================
# exec-inject.sh — Inject a message into the exec session and capture response
#
# Called by the matrix listener when a message arrives for the exec agent.
# Handles session lifecycle: spawn if needed, inject, capture, post to Matrix.
#
# Usage:
#   exec-inject.sh <sender> <message_body> <thread_id> [project_toml]
#
# Flow:
#   1. Check for active exec tmux session → spawn via exec-session.sh if needed
#   2. Inject the executive's message into the Claude session
#   3. Monitor tmux output for ---EXEC-RESPONSE-START/END--- markers
#   4. Post captured response back to Matrix thread
#   5. Log the exchange to journal
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

SENDER="${1:?Usage: exec-inject.sh <sender> <message> <thread_id> [project.toml]}"
MESSAGE="${2:?}"
THREAD_ID="${3:?}"
PROJECT_TOML="${4:-$FACTORY_ROOT/projects/disinto.toml}"

export PROJECT_TOML
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# shellcheck source=../lib/agent-session.sh
source "$FACTORY_ROOT/lib/agent-session.sh"

LOG_FILE="$SCRIPT_DIR/exec.log"
SESSION_NAME="exec-${PROJECT_NAME}"
PHASE_FILE="/tmp/exec-session-${PROJECT_NAME}.phase"
RESPONSE_FILE="/tmp/exec-response-${PROJECT_NAME}.txt"
CAPTURE_TIMEOUT="${EXEC_CAPTURE_TIMEOUT:-300}"  # 5 min max wait for response

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Ensure session exists ───────────────────────────────────────────────
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  log "no active exec session — spawning"
  RESULT=$(bash "$SCRIPT_DIR/exec-session.sh" "$PROJECT_TOML" 2>>"$LOG_FILE")
  if [ "$RESULT" != "STARTED" ] && [ "$RESULT" != "ACTIVE" ]; then
    log "ERROR: failed to start exec session (got: ${RESULT})"
    matrix_send "exec" "❌ Could not start executive assistant session" "$THREAD_ID" >/dev/null 2>&1 || true
    exit 1
  fi
  # Give Claude a moment to process the initial prompt
  sleep 3
fi

# ── Inject message ──────────────────────────────────────────────────────
INJECT_MSG="Message from ${SENDER}:

${MESSAGE}"

log "injecting message from ${SENDER}: ${MESSAGE:0:100}"

INJECT_TMP=$(mktemp /tmp/exec-inject-XXXXXX)
printf '%s' "$INJECT_MSG" > "$INJECT_TMP"
tmux load-buffer -b "exec-msg" "$INJECT_TMP" || true
tmux paste-buffer -t "$SESSION_NAME" -b "exec-msg" || true
sleep 0.5
tmux send-keys -t "$SESSION_NAME" "" Enter || true
tmux delete-buffer -b "exec-msg" 2>/dev/null || true
rm -f "$INJECT_TMP"

# ── Capture response ───────────────────────────────────────────────────
# Poll tmux pane content for the response markers
log "waiting for response (timeout: ${CAPTURE_TIMEOUT}s)"
rm -f "$RESPONSE_FILE"

ELAPSED=0
POLL_INTERVAL=3
while [ "$ELAPSED" -lt "$CAPTURE_TIMEOUT" ]; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))

  # Capture recent pane content (last 200 lines)
  PANE_CONTENT=$(tmux capture-pane -t "$SESSION_NAME" -p -S -200 2>/dev/null || true)

  if echo "$PANE_CONTENT" | grep -q "EXEC-RESPONSE-END"; then
    # Extract response between markers
    RESPONSE=$(echo "$PANE_CONTENT" | sed -n '/---EXEC-RESPONSE-START---/,/---EXEC-RESPONSE-END---/p' \
      | grep -v "EXEC-RESPONSE-START\|EXEC-RESPONSE-END" \
      | tail -n +1)

    if [ -n "$RESPONSE" ]; then
      printf '%s' "$RESPONSE" > "$RESPONSE_FILE"
      log "response captured (${#RESPONSE} chars)"
      break
    fi
  fi

  # Check if session died
  if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    log "ERROR: exec session died while waiting for response"
    matrix_send "exec" "❌ Executive assistant session ended unexpectedly" "$THREAD_ID" >/dev/null 2>&1 || true
    exit 1
  fi
done

# ── Post response to Matrix ────────────────────────────────────────────
if [ -f "$RESPONSE_FILE" ] && [ -s "$RESPONSE_FILE" ]; then
  RESPONSE=$(cat "$RESPONSE_FILE")
  # Truncate if too long for Matrix (64KB limit, keep under 4KB for readability)
  if [ ${#RESPONSE} -gt 4000 ]; then
    RESPONSE="${RESPONSE:0:3950}

(truncated — full response in exec journal)"
  fi
  matrix_send "exec" "$RESPONSE" "$THREAD_ID" >/dev/null 2>&1 || true
  log "response posted to Matrix thread"

  # Journal the exchange
  JOURNAL_DIR="$PROJECT_REPO_ROOT/exec/journal"
  mkdir -p "$JOURNAL_DIR"
  JOURNAL_FILE="$JOURNAL_DIR/$(date -u +%Y-%m-%d).md"
  {
    echo ""
    echo "## $(date -u +%H:%M) UTC — ${SENDER}"
    echo ""
    echo "**Q:** ${MESSAGE}"
    echo ""
    echo "**A:** ${RESPONSE}"
    echo ""
    echo "---"
  } >> "$JOURNAL_FILE"
  log "exchange logged to $(basename "$JOURNAL_FILE")"
else
  log "WARNING: no response captured within ${CAPTURE_TIMEOUT}s"
  matrix_send "exec" "⚠️ Still thinking... (response not ready within ${CAPTURE_TIMEOUT}s, session is still active)" "$THREAD_ID" >/dev/null 2>&1 || true
fi

rm -f "$RESPONSE_FILE"
