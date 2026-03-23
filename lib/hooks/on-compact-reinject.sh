#!/usr/bin/env bash
# on-compact-reinject.sh — SessionStart (compact) hook for dark-factory agent sessions.
#
# Called by Claude Code after context compaction. Reads a context file and
# outputs its content to stdout, which Claude Code injects as system context.
# No-op if the context file doesn't exist.
#
# Usage (in .claude/settings.json):
#   {"type": "command", "command": "this-script /tmp/dev-session-PROJECT-ISSUE.context"}
#
# Args: $1 = context file path

cat > /dev/null  # consume hook JSON from stdin
[ -n "${1:-}" ] && [ -f "$1" ] && cat "$1"
exit 0
