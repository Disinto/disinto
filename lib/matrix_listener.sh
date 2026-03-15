#!/usr/bin/env bash
# matrix_listener.sh — Long-poll Matrix sync daemon
#
# Listens for replies in the Matrix coordination room and dispatches them
# to the appropriate agent via well-known files.
#
# Dispatch:
#   Thread reply to [supervisor] message → /tmp/supervisor-escalation-reply
#   Thread reply to [gardener] message   → /tmp/gardener-escalation-reply
#
# Run as systemd service (see matrix_listener.service) or manually:
#   ./matrix_listener.sh

set -euo pipefail

# Load shared environment
source "$(dirname "$0")/../lib/env.sh"

SINCE_FILE="/tmp/matrix-listener-since"
THREAD_MAP="${MATRIX_THREAD_MAP:-/tmp/matrix-thread-map}"
LOGFILE="${FACTORY_ROOT}/supervisor/matrix-listener.log"
SYNC_TIMEOUT=30000  # 30s long-poll
BACKOFF=5
MAX_BACKOFF=60

log() {
  printf '[%s] listener: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

# Validate Matrix config
if [ -z "${MATRIX_TOKEN:-}" ] || [ -z "${MATRIX_ROOM_ID:-}" ]; then
  echo "MATRIX_TOKEN and MATRIX_ROOM_ID must be set in .env" >&2
  exit 1
fi

# URL-encode room ID
ROOM_ENCODED="${MATRIX_ROOM_ID//!/%21}"

# Build sync filter — only our room, only messages
FILTER=$(jq -nc --arg room "$MATRIX_ROOM_ID" '{
  room: {
    rooms: [$room],
    timeline: {types: ["m.room.message"], limit: 20},
    state: {types: []},
    ephemeral: {types: []}
  },
  presence: {types: []}
}')

# Load previous sync token
SINCE=""
if [ -f "$SINCE_FILE" ]; then
  SINCE=$(cat "$SINCE_FILE" 2>/dev/null || true)
fi

log "started (since=${SINCE:-initial})"

# Do an initial sync without timeout to catch up, then switch to long-poll
INITIAL=true

while true; do
  # Build sync URL
  SYNC_URL="${MATRIX_HOMESERVER}/_matrix/client/v3/sync?filter=$(jq -rn --arg f "$FILTER" '$f | @uri')&timeout=${SYNC_TIMEOUT}"
  if [ -n "$SINCE" ]; then
    SYNC_URL="${SYNC_URL}&since=${SINCE}"
  fi
  if [ "$INITIAL" = true ]; then
    # First sync: no timeout, just catch up
    SYNC_URL="${MATRIX_HOMESERVER}/_matrix/client/v3/sync?filter=$(jq -rn --arg f "$FILTER" '$f | @uri')"
    [ -n "$SINCE" ] && SYNC_URL="${SYNC_URL}&since=${SINCE}"
    INITIAL=false
  fi

  # Long-poll
  RESPONSE=$(curl -s --max-time $((SYNC_TIMEOUT / 1000 + 30)) \
    -H "Authorization: Bearer ${MATRIX_TOKEN}" \
    "$SYNC_URL" 2>/dev/null) || {
    log "sync failed, backing off ${BACKOFF}s"
    sleep "$BACKOFF"
    BACKOFF=$((BACKOFF * 2 > MAX_BACKOFF ? MAX_BACKOFF : BACKOFF * 2))
    continue
  }

  # Reset backoff on success
  BACKOFF=5

  # Extract next_batch
  NEXT_BATCH=$(printf '%s' "$RESPONSE" | jq -r '.next_batch // empty' 2>/dev/null)
  if [ -z "$NEXT_BATCH" ]; then
    log "no next_batch in response"
    sleep 5
    continue
  fi

  # Save cursor
  printf '%s' "$NEXT_BATCH" > "$SINCE_FILE"
  SINCE="$NEXT_BATCH"

  # Extract timeline events from our room
  EVENTS=$(printf '%s' "$RESPONSE" | jq -c --arg room "$MATRIX_ROOM_ID" '
    .rooms.join[$room].timeline.events[]? |
    select(.type == "m.room.message") |
    select(.sender != "'"${MATRIX_BOT_USER}"'")
  ' 2>/dev/null) || continue

  [ -z "$EVENTS" ] && continue

  while IFS= read -r event; do
    SENDER=$(printf '%s' "$event" | jq -r '.sender')
    BODY=$(printf '%s' "$event" | jq -r '.content.body // ""')
    EVENT_ID=$(printf '%s' "$event" | jq -r '.event_id')

    # Check if this is a thread reply
    THREAD_ROOT=$(printf '%s' "$event" | jq -r '.content."m.relates_to" | select(.rel_type == "m.thread") | .event_id // empty' 2>/dev/null)

    if [ -z "$THREAD_ROOT" ] || [ -z "$BODY" ]; then
      continue
    fi

    # Look up thread root in our mapping
    if [ ! -f "$THREAD_MAP" ]; then
      continue
    fi

    AGENT=$(awk -F'\t' -v id="$THREAD_ROOT" '$1 == id {print $2}' "$THREAD_MAP" 2>/dev/null)

    if [ -z "$AGENT" ]; then
      log "reply to unknown thread ${THREAD_ROOT:0:20} from ${SENDER}"
      continue
    fi

    log "reply from ${SENDER} to [${AGENT}] thread: ${BODY:0:100}"

    case "$AGENT" in
      supervisor)
        printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SENDER" "$BODY" >> /tmp/supervisor-escalation-reply
        # Acknowledge
        matrix_send "supervisor" "✓ received, will act on next poll" "$THREAD_ROOT" >/dev/null 2>&1 || true
        ;;
      gardener)
        printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SENDER" "$BODY" >> /tmp/gardener-escalation-reply
        matrix_send "gardener" "✓ received, will act on next poll" "$THREAD_ROOT" >/dev/null 2>&1 || true
        ;;
      *)
        log "no handler for agent '${AGENT}'"
        ;;
    esac

  done <<< "$EVENTS"
done
