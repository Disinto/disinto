#!/bin/bash
# on-phase-change.sh — PostToolUse hook for phase file write detection.
#
# Called by Claude Code after every Bash|Write tool execution.
# Detects writes (not reads) to the phase file and writes a timestamp
# marker so monitor_phase_loop can react immediately instead of waiting
# for the next mtime-based poll.
#
# Usage (in .claude/settings.json):
#   {"type": "command", "command": "this-script /path/to/phase-file /path/to/marker"}
#
# Args: $1 = phase file path, $2 = marker file path

phase_file="${1:-}"
marker_file="${2:-}"

[ -z "$phase_file" ] && exit 0
[ -z "$marker_file" ] && exit 0

input=$(cat)  # consume hook JSON from stdin

# Fast path: skip if phase file not referenced at all
printf '%s' "$input" | grep -qF "$phase_file" || exit 0

# Parse tool type and detect writes only (ignore reads like cat/head)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)

case "$tool_name" in
  Write)
    # Write tool: check if file_path targets the phase file
    file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    [ "$file_path" = "$phase_file" ] && date +%s > "$marker_file"
    ;;
  Bash)
    # Bash tool: check if the decoded command contains a redirect (>)
    # targeting the phase file — distinguishes writes from reads
    command_str=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
    if printf '%s' "$command_str" | grep -qF "$phase_file" \
       && printf '%s' "$command_str" | grep -q '>'; then
      date +%s > "$marker_file"
    fi
    ;;
esac
