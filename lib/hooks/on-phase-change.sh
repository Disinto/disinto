#!/bin/bash
# on-phase-change.sh — PostToolUse hook for phase file write detection.
#
# Called by Claude Code after every Bash|Write tool execution.
# Checks if the tool input references the phase file path and, if so,
# writes a "phase-changed" timestamp marker so monitor_phase_loop can
# react immediately instead of waiting for the next mtime-based poll.
#
# Usage (in .claude/settings.json):
#   {"type": "command", "command": "this-script /path/to/phase-file /path/to/marker"}
#
# Args: $1 = phase file path, $2 = marker file path

phase_file="${1:-}"
marker_file="${2:-}"

input=$(cat)  # consume hook JSON from stdin

[ -z "$phase_file" ] || [ -z "$marker_file" ] && exit 0

# Check if the tool input references the phase file path
if printf '%s' "$input" | grep -qF "$phase_file"; then
  date +%s > "$marker_file"
fi
