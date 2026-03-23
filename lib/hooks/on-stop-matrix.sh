#!/usr/bin/env bash
# on-stop-matrix.sh — Stop hook: post Claude response to Matrix thread.
#
# Called by Claude Code after each assistant turn. Reads the response from
# the hook JSON and posts it to the Matrix thread for this action session.
#
# Requires env vars: MATRIX_THREAD_ID, MATRIX_TOKEN, MATRIX_HOMESERVER, MATRIX_ROOM_ID
#
# Usage (in .claude/settings.json):
#   {"type": "command", "command": "/path/to/on-stop-matrix.sh"}

# Exit early if Matrix thread not configured
if [ -z "${MATRIX_THREAD_ID:-}" ] || [ -z "${MATRIX_TOKEN:-}" ] \
   || [ -z "${MATRIX_HOMESERVER:-}" ] || [ -z "${MATRIX_ROOM_ID:-}" ]; then
  cat > /dev/null
  exit 0
fi

input=$(cat)

# Extract response text from hook JSON
response=$(printf '%s' "$input" | jq -r '.last_assistant_message // empty' 2>/dev/null)
[ -z "$response" ] && exit 0

# Truncate long output for readability (keep to ~4000 chars)
MAX_LEN=4000
if [ "${#response}" -gt "$MAX_LEN" ]; then
  response="${response:0:$MAX_LEN}
... [truncated]"
fi

# Post to Matrix thread
room_encoded="${MATRIX_ROOM_ID//!/%21}"
txn="$(date +%s%N)$$"

body=$(jq -nc \
  --arg m "$response" \
  --arg t "$MATRIX_THREAD_ID" \
  '{msgtype:"m.text",body:$m,"m.relates_to":{rel_type:"m.thread",event_id:$t}}')

curl -s -X PUT \
  -H "Authorization: Bearer ${MATRIX_TOKEN}" \
  -H "Content-Type: application/json" \
  "${MATRIX_HOMESERVER}/_matrix/client/v3/rooms/${room_encoded}/send/m.room.message/${txn}" \
  -d "$body" > /dev/null 2>&1 || true
