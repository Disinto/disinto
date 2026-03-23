#!/usr/bin/env bash
# on-idle-stop.sh — Stop hook for dark-factory agent sessions.
#
# Called by Claude Code when it finishes a response. Writes a timestamp
# to a marker file so monitor_phase_loop can detect idle sessions
# without fragile tmux pane scraping.
#
# Usage (in .claude/settings.json):
#   {"type": "command", "command": "this-script /tmp/claude-idle-SESSION.ts"}
#
# Args: $1 = marker file path

cat > /dev/null  # consume hook JSON from stdin
[ -n "${1:-}" ] && date +%s > "$1"
