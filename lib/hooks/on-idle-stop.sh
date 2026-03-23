#!/usr/bin/env bash
# on-idle-stop.sh — Stop hook for dark-factory agent sessions.
#
# Called by Claude Code when it finishes a response. Writes a timestamp
# to a marker file so monitor_phase_loop can detect idle sessions
# without fragile tmux pane scraping.
#
# When a phase file is provided and exists but is empty, Claude likely
# returned to the prompt without following the phase protocol. Instead
# of marking idle, inject a nudge into the tmux session (up to 2 times).
#
# Usage (in .claude/settings.json):
#   {"type": "command", "command": "this-script /tmp/claude-idle-SESSION.ts [PHASE_FILE SESSION_NAME]"}
#
# Args: $1 = marker file path
#       $2 = phase file path (optional)
#       $3 = tmux session name (optional)

cat > /dev/null  # consume hook JSON from stdin

MARKER="${1:-}"
[ -z "$MARKER" ] && exit 0

PHASE_FILE="${2:-}"
SESSION_NAME="${3:-}"

# If phase file is provided, exists, and is empty — Claude forgot to signal.
# Nudge via tmux instead of marking idle (up to 2 attempts).
if [ -n "$PHASE_FILE" ] && [ -n "$SESSION_NAME" ] && [ -f "$PHASE_FILE" ] && [ ! -s "$PHASE_FILE" ]; then
  NUDGE_FILE="/tmp/claude-nudge-${SESSION_NAME}.count"
  NUDGE_COUNT=$(cat "$NUDGE_FILE" 2>/dev/null || echo 0)
  if [ "$NUDGE_COUNT" -lt 2 ]; then
    echo $(( NUDGE_COUNT + 1 )) > "$NUDGE_FILE"
    tmux send-keys -t "$SESSION_NAME" \
      "You returned to the prompt without writing to the PHASE file. Checklist: (1) Did you complete the commit-and-pr step? (2) Did you write PHASE:done or PHASE:awaiting_ci to ${PHASE_FILE}? If no file changes were needed, write PHASE:done now." Enter
    exit 0
  fi
fi

# Normal idle mark — either no phase file, phase already has content,
# or nudge limit reached.
date +%s > "$MARKER"
