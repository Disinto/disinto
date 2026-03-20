#!/bin/bash
# on-stop-failure.sh — StopFailure hook for immediate phase file update on API error.
#
# Called by Claude Code when a turn ends due to an API error (rate limit,
# server error, billing error, authentication failure). Writes PHASE:failed
# to the phase file and touches the phase-changed marker so the orchestrator
# picks up the failure within one poll cycle instead of waiting for idle
# timeout (up to 2 hours).
#
# Usage (in .claude/settings.json):
#   {"type": "command", "command": "this-script /path/to/phase-file /path/to/marker"}
#
# Args: $1 = phase file path, $2 = phase-changed marker path

phase_file="${1:-}"
marker_file="${2:-}"

[ -z "$phase_file" ] && exit 0

input=$(cat)  # consume hook JSON from stdin

# Extract the stop reason from the hook payload
reason=$(printf '%s' "$input" | jq -r '
  .stop_reason // .matched_hook // .reason // .type // "unknown"
' 2>/dev/null)
[ -z "$reason" ] && reason="unknown"

# Write phase file immediately — orchestrator reads first line as phase sentinel
printf 'PHASE:failed\nReason: api_error: %s\n' "$reason" > "$phase_file"

# Touch marker so monitor_phase_loop picks this up on the next poll cycle
if [ -n "$marker_file" ]; then
  date +%s > "$marker_file"
fi
