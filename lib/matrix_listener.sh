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
# shellcheck disable=SC2034
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
    # shellcheck disable=SC2034
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
      dev)
        # Route reply into the dev tmux session using context_tag (issue number)
        DEV_ISSUE=$(awk -F'\t' -v id="$THREAD_ROOT" '$1 == id {print $4}' "$THREAD_MAP" 2>/dev/null || true)
        DEV_INJECTED=false
        if [ -n "$DEV_ISSUE" ]; then
          DEV_SESSION="dev-${PROJECT_NAME}-${DEV_ISSUE}"
          DEV_PHASE_FILE="/tmp/dev-session-${PROJECT_NAME}-${DEV_ISSUE}.phase"
          if tmux has-session -t "$DEV_SESSION" 2>/dev/null; then
            DEV_CUR_PHASE=$(head -1 "$DEV_PHASE_FILE" 2>/dev/null | tr -d '[:space:]' || true)
            if [ "$DEV_CUR_PHASE" = "PHASE:needs_human" ] || [ "$DEV_CUR_PHASE" = "PHASE:awaiting_review" ]; then
              DEV_INJECT_MSG="Human guidance from ${SENDER} in Matrix:

${BODY}

Consider this guidance for your current work."
              DEV_INJECT_TMP=$(mktemp /tmp/dev-q-inject-XXXXXX)
              printf '%s' "$DEV_INJECT_MSG" > "$DEV_INJECT_TMP"
              tmux load-buffer -b "dev-q-${DEV_ISSUE}" "$DEV_INJECT_TMP" || true
              tmux paste-buffer -t "$DEV_SESSION" -b "dev-q-${DEV_ISSUE}" || true
              sleep 0.5
              tmux send-keys -t "$DEV_SESSION" "" Enter || true
              tmux delete-buffer -b "dev-q-${DEV_ISSUE}" 2>/dev/null || true
              rm -f "$DEV_INJECT_TMP"
              DEV_INJECTED=true
              log "human guidance from ${SENDER} injected into ${DEV_SESSION}"
              matrix_send "dev" "✓ guidance forwarded to dev session for issue #${DEV_ISSUE}" "$THREAD_ROOT" >/dev/null 2>&1 || true
            else
              log "dev session ${DEV_SESSION} is busy (phase: ${DEV_CUR_PHASE:-active}), queuing"
              matrix_send "dev" "✓ received — session is busy, will be available when dev pauses" "$THREAD_ROOT" >/dev/null 2>&1 || true
            fi
          else
            log "dev session ${DEV_SESSION} not found for issue #${DEV_ISSUE}"
            matrix_send "dev" "dev session not active for issue #${DEV_ISSUE}" "$THREAD_ROOT" >/dev/null 2>&1 || true
          fi
        else
          log "dev thread ${THREAD_ROOT:0:20} has no issue mapping"
          matrix_send "dev" "✓ received, will act on next poll" "$THREAD_ROOT" >/dev/null 2>&1 || true
        fi
        # Only write to flat file when direct injection didn't happen,
        # to avoid supervisor/gardener poll re-injecting the same message.
        if [ "$DEV_INJECTED" = false ]; then
          printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SENDER" "$BODY" >> /tmp/dev-escalation-reply
        fi
        ;;
      review)
        # Route human questions to persistent review tmux session
        REVIEW_PR_NUM=$(awk -F'\t' -v id="$THREAD_ROOT" '$1 == id {print $4}' "$THREAD_MAP" 2>/dev/null || true)
        if [ -n "$REVIEW_PR_NUM" ]; then
          REVIEW_SESSION="review-${PROJECT_NAME}-${REVIEW_PR_NUM}"
          REVIEW_PHASE_FILE="/tmp/review-session-${PROJECT_NAME}-${REVIEW_PR_NUM}.phase"
          if tmux has-session -t "$REVIEW_SESSION" 2>/dev/null; then
            # Skip injection if Claude is mid-review (phase file absent = actively writing)
            REVIEW_CUR_PHASE=$(head -1 "$REVIEW_PHASE_FILE" 2>/dev/null | tr -d '[:space:]' || true)
            if [ -z "$REVIEW_CUR_PHASE" ]; then
              log "review session ${REVIEW_SESSION} is mid-review, deferring question"
              matrix_send "review" "reviewer is busy — question queued, try again shortly" "$THREAD_ROOT" >/dev/null 2>&1 || true
            else
              REVIEW_INJECT_MSG="Human question from ${SENDER} in Matrix:

${BODY}

Please answer this question about your review. Explain your reasoning."
              REVIEW_INJECT_TMP=$(mktemp /tmp/review-q-inject-XXXXXX)
              printf '%s' "$REVIEW_INJECT_MSG" > "$REVIEW_INJECT_TMP"
              tmux load-buffer -b "review-q-${REVIEW_PR_NUM}" "$REVIEW_INJECT_TMP" || true
              tmux paste-buffer -t "$REVIEW_SESSION" -b "review-q-${REVIEW_PR_NUM}" || true
              sleep 0.5
              tmux send-keys -t "$REVIEW_SESSION" "" Enter || true
              tmux delete-buffer -b "review-q-${REVIEW_PR_NUM}" 2>/dev/null || true
              rm -f "$REVIEW_INJECT_TMP"
              log "review question from ${SENDER} injected into ${REVIEW_SESSION}"
              matrix_send "review" "✓ question forwarded to reviewer session" "$THREAD_ROOT" >/dev/null 2>&1 || true
            fi
          else
            log "review session ${REVIEW_SESSION} not found for PR #${REVIEW_PR_NUM}"
            matrix_send "review" "review session not active for PR #${REVIEW_PR_NUM}" "$THREAD_ROOT" >/dev/null 2>&1 || true
          fi
        else
          log "review thread ${THREAD_ROOT:0:20} has no PR mapping"
          matrix_send "review" "review session not available" "$THREAD_ROOT" >/dev/null 2>&1 || true
        fi
        ;;
      action)
        # Route reply into the action tmux session using context_tag (issue number)
        ACTION_ISSUE=$(awk -F'\t' -v id="$THREAD_ROOT" '$1 == id {print $4}' "$THREAD_MAP" 2>/dev/null || true)
        if [ -n "$ACTION_ISSUE" ]; then
          ACTION_SESSION="action-${ACTION_ISSUE}"
          if tmux has-session -t "$ACTION_SESSION" 2>/dev/null; then
            ACTION_INJECT_MSG="Human reply from ${SENDER} in Matrix:

${BODY}

Continue with the action formula based on this response."
            ACTION_INJECT_TMP=$(mktemp /tmp/action-q-inject-XXXXXX)
            printf '%s' "$ACTION_INJECT_MSG" > "$ACTION_INJECT_TMP"
            tmux load-buffer -b "action-q-${ACTION_ISSUE}" "$ACTION_INJECT_TMP" || true
            tmux paste-buffer -t "$ACTION_SESSION" -b "action-q-${ACTION_ISSUE}" || true
            sleep 0.5
            tmux send-keys -t "$ACTION_SESSION" "" Enter || true
            tmux delete-buffer -b "action-q-${ACTION_ISSUE}" 2>/dev/null || true
            rm -f "$ACTION_INJECT_TMP"
            log "human reply from ${SENDER} injected into ${ACTION_SESSION}"
            matrix_send "action" "✓ reply forwarded to action session for issue #${ACTION_ISSUE}" "$THREAD_ROOT" >/dev/null 2>&1 || true
          else
            log "action session ${ACTION_SESSION} not found for issue #${ACTION_ISSUE}"
            matrix_send "action" "action session not active for issue #${ACTION_ISSUE}" "$THREAD_ROOT" >/dev/null 2>&1 || true
          fi
        else
          log "action thread ${THREAD_ROOT:0:20} has no issue mapping"
          matrix_send "action" "✓ received, no active session found" "$THREAD_ROOT" >/dev/null 2>&1 || true
        fi
        ;;
      vault)
        # Parse APPROVE <id> or REJECT <id> from reply
        VAULT_CMD=$(echo "$BODY" | tr '[:lower:]' '[:upper:]' | grep -oP '^\s*(APPROVE|REJECT)\s+\S+' | head -1 || true)
        if [ -n "$VAULT_CMD" ]; then
          VAULT_ACTION=$(echo "$VAULT_CMD" | awk '{print $1}')
          VAULT_ID=$(echo "$BODY" | awk '{print $2}')  # preserve original case for ID
          log "vault dispatch: $VAULT_ACTION $VAULT_ID"
          VAULT_DIR="${FACTORY_ROOT}/vault"
          if [ "$VAULT_ACTION" = "APPROVE" ]; then
            if bash "${VAULT_DIR}/vault-fire.sh" "$VAULT_ID" >> "${VAULT_DIR}/vault.log" 2>&1; then
              matrix_send "vault" "✓ approved and fired: ${VAULT_ID}" "$THREAD_ROOT" >/dev/null 2>&1 || true
            else
              matrix_send "vault" "✓ approved but fire failed — will retry: ${VAULT_ID}" "$THREAD_ROOT" >/dev/null 2>&1 || true
            fi
          else
            bash "${VAULT_DIR}/vault-reject.sh" "$VAULT_ID" "rejected by ${SENDER}" >> "${VAULT_DIR}/vault.log" 2>&1 || true
            matrix_send "vault" "✓ rejected: ${VAULT_ID}" "$THREAD_ROOT" >/dev/null 2>&1 || true
          fi
        else
          log "vault: unrecognized reply format: ${BODY:0:100}"
          matrix_send "vault" "⚠️ Reply with APPROVE <id> or REJECT <id>" "$THREAD_ROOT" >/dev/null 2>&1 || true
        fi
        ;;
      *)
        log "no handler for agent '${AGENT}'"
        ;;
    esac

  done <<< "$EVENTS"
done
