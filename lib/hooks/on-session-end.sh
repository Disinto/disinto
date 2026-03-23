#!/usr/bin/env bash
# on-session-end.sh — SessionEnd hook for dark-factory agent sessions.
#
# Called by Claude Code when a session terminates (clean exit, logout,
# crash, OOM, etc.). Writes a termination marker so monitor_phase_loop
# can detect session death faster than tmux has-session polling alone.
#
# Usage (in .claude/settings.json):
#   {"type": "command", "command": "this-script /tmp/claude-exited-SESSION.ts"}
#
# Args: $1 = marker file path

input=$(cat)  # consume hook JSON from stdin

reason=$(printf '%s' "$input" | jq -r '
  .matched_hook // .reason // .type // "unknown"
' 2>/dev/null)
[ -z "$reason" ] && reason="unknown"

if [ -n "${1:-}" ]; then
  printf '%s %s\n' "$(date +%s)" "$reason" > "$1"
fi
