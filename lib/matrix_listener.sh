#!/usr/bin/env bash
# matrix_listener.sh — Long-poll Matrix sync daemon
#
# Listens for replies in the Matrix coordination room and dispatches them
# to the appropriate agent via well-known files.
#
# Dispatch:
#   Thread reply to [supervisor] message → /tmp/supervisor-escalation-reply
#   Thread reply to [gardener] message   → /tmp/gardener-escalation-reply
#   Thread reply to [dev] message        → injected into dev tmux session (or /tmp/dev-escalation-reply)
#   Thread reply to [review] message     → injected into review tmux session
#   Thread reply to [vault] message      → APPROVE/REJECT dispatched via vault-fire/vault-reject
#   Thread reply to [action] message     → injected into action tmux session
#
# Run as systemd service (see matrix_listener.service) or manually:
#   ./matrix_listener.sh

set -euo pipefail

# Load shared environment
source "$(dirname "$0")/../lib/env.sh"

# Pidfile guard — prevent duplicate listener processes
PIDFILE="/tmp/matrix-listener.pid"
if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Listener already running (PID $OLD_PID)" >&2
    exit 0
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

SINCE_FILE="/tmp/matrix-listener-since"
THREAD_MAP="${MATRIX_THREAD_MAP:-/tmp/matrix-thread-map}"
ACKED_FILE="/tmp/matrix-listener-acked"
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
        # Thread map columns: 1=thread_id, 2=agent, 3=timestamp, 4=issue, 5=project
        DEV_ISSUE=$(awk -F'\t' -v id="$THREAD_ROOT" '$1 == id {print $4}' "$THREAD_MAP" 2>/dev/null || true)
        DEV_PROJECT=$(awk -F'\t' -v id="$THREAD_ROOT" '$1 == id {print $5}' "$THREAD_MAP" 2>/dev/null || true)
        DEV_INJECTED=false
        if [ -n "$DEV_ISSUE" ]; then
          DEV_SESSION="dev-${DEV_PROJECT}-${DEV_ISSUE}"
          DEV_PHASE_FILE="/tmp/dev-session-${DEV_PROJECT}-${DEV_ISSUE}.phase"
          if tmux has-session -t "$DEV_SESSION" 2>/dev/null; then
            DEV_CUR_PHASE=$(head -1 "$DEV_PHASE_FILE" 2>/dev/null | tr -d '[:space:]' || true)
            if [ "$DEV_CUR_PHASE" = "PHASE:escalate" ] || [ "$DEV_CUR_PHASE" = "PHASE:awaiting_review" ]; then
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
              # Reply on first successful injection only — no reply on subsequent ones
              if ! grep -qF "$THREAD_ROOT" "$ACKED_FILE" 2>/dev/null; then
                matrix_send "dev" "✓ Guidance forwarded to dev session for #${DEV_ISSUE}" "$THREAD_ROOT" >/dev/null 2>&1 || true
                printf '%s\n' "$THREAD_ROOT" >> "$ACKED_FILE"
              fi
            else
              log "WARN: dev session '${DEV_SESSION}' busy (phase: ${DEV_CUR_PHASE:-active}), queuing message for issue #${DEV_ISSUE}"
              matrix_send "dev" "❌ Could not inject: dev session for #${DEV_ISSUE} is busy (phase: ${DEV_CUR_PHASE:-active}), message queued" "$THREAD_ROOT" >/dev/null 2>&1 || true
            fi
          else
            log "WARN: tmux session '${DEV_SESSION}' not found for issue #${DEV_ISSUE} (project: ${DEV_PROJECT:-UNSET})"
            matrix_send "dev" "❌ Could not inject: tmux session '${DEV_SESSION}' not found (project: ${DEV_PROJECT:-UNSET})" "$THREAD_ROOT" >/dev/null 2>&1 || true
          fi
        else
          log "dev thread ${THREAD_ROOT:0:20} has no issue mapping"
          matrix_send "dev" "❌ Could not inject: no issue mapping for this thread" "$THREAD_ROOT" >/dev/null 2>&1 || true
        fi
        # Only write to flat file when direct injection didn't happen,
        # to avoid supervisor/gardener poll re-injecting the same message.
        if [ "$DEV_INJECTED" = false ]; then
          printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SENDER" "$BODY" >> /tmp/dev-escalation-reply
        fi
        ;;
      review)
        # Route human questions to persistent review tmux session
        # Thread map columns: 1=thread_id, 2=agent, 3=timestamp, 4=pr_num, 5=project
        REVIEW_PR_NUM=$(awk -F'\t' -v id="$THREAD_ROOT" '$1 == id {print $4}' "$THREAD_MAP" 2>/dev/null || true)
        REVIEW_PROJECT=$(awk -F'\t' -v id="$THREAD_ROOT" '$1 == id {print $5}' "$THREAD_MAP" 2>/dev/null || true)
        if [ -n "$REVIEW_PR_NUM" ]; then
          REVIEW_SESSION="review-${REVIEW_PROJECT}-${REVIEW_PR_NUM}"
          REVIEW_PHASE_FILE="/tmp/review-session-${REVIEW_PROJECT}-${REVIEW_PR_NUM}.phase"
          if tmux has-session -t "$REVIEW_SESSION" 2>/dev/null; then
            # Skip injection if Claude is mid-review (phase file absent = actively writing)
            REVIEW_CUR_PHASE=$(head -1 "$REVIEW_PHASE_FILE" 2>/dev/null | tr -d '[:space:]' || true)
            if [ -z "$REVIEW_CUR_PHASE" ]; then
              log "WARN: review session '${REVIEW_SESSION}' is mid-review, deferring question for PR #${REVIEW_PR_NUM}"
              matrix_send "review" "❌ Could not inject: reviewer is mid-review for PR #${REVIEW_PR_NUM}, try again shortly" "$THREAD_ROOT" >/dev/null 2>&1 || true
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
              # Reply on first successful injection only
              if ! grep -qF "$THREAD_ROOT" "$ACKED_FILE" 2>/dev/null; then
                matrix_send "review" "✓ Question forwarded to reviewer session for PR #${REVIEW_PR_NUM}" "$THREAD_ROOT" >/dev/null 2>&1 || true
                printf '%s\n' "$THREAD_ROOT" >> "$ACKED_FILE"
              fi
            fi
          else
            log "WARN: tmux session '${REVIEW_SESSION}' not found for PR #${REVIEW_PR_NUM} (project: ${REVIEW_PROJECT:-UNSET})"
            matrix_send "review" "❌ Could not inject: tmux session '${REVIEW_SESSION}' not found (project: ${REVIEW_PROJECT:-UNSET})" "$THREAD_ROOT" >/dev/null 2>&1 || true
          fi
        else
          log "review thread ${THREAD_ROOT:0:20} has no PR mapping"
          matrix_send "review" "❌ Could not inject: no PR mapping for this thread" "$THREAD_ROOT" >/dev/null 2>&1 || true
        fi
        ;;
      action)
        # Route reply into the action tmux session using context_tag (issue number)
        ACTION_ISSUE=$(awk -F'\t' -v id="$THREAD_ROOT" '$1 == id {print $4}' "$THREAD_MAP" 2>/dev/null || true)
        ACTION_PROJECT=$(awk -F'\t' -v id="$THREAD_ROOT" '$1 == id {print $5}' "$THREAD_MAP" 2>/dev/null || true)
        if [ -n "$ACTION_ISSUE" ]; then
          ACTION_SESSION="action-${ACTION_PROJECT}-${ACTION_ISSUE}"
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
            # Reply on first successful injection only
            if ! grep -qF "$THREAD_ROOT" "$ACKED_FILE" 2>/dev/null; then
              matrix_send "action" "✓ Reply forwarded to action session for issue #${ACTION_ISSUE}" "$THREAD_ROOT" >/dev/null 2>&1 || true
              printf '%s\n' "$THREAD_ROOT" >> "$ACKED_FILE"
            fi
          else
            log "WARN: tmux session '${ACTION_SESSION}' not found for issue #${ACTION_ISSUE}"
            matrix_send "action" "❌ Could not inject: tmux session '${ACTION_SESSION}' not found" "$THREAD_ROOT" >/dev/null 2>&1 || true
          fi
        else
          log "action thread ${THREAD_ROOT:0:20} has no issue mapping"
          matrix_send "action" "❌ Could not inject: no issue mapping for this thread" "$THREAD_ROOT" >/dev/null 2>&1 || true
        fi
        ;;
      vault)
        # Route reply to vault tmux session if one exists (unified escalation path)
        VAULT_ISSUE=$(awk -F'\t' -v id="$THREAD_ROOT" '$1 == id {print $4}' "$THREAD_MAP" 2>/dev/null || true)
        VAULT_PROJECT=$(awk -F'\t' -v id="$THREAD_ROOT" '$1 == id {print $5}' "$THREAD_MAP" 2>/dev/null || true)
        VAULT_INJECTED=false
        if [ -n "$VAULT_ISSUE" ]; then
          VAULT_SESSION="vault-${VAULT_PROJECT:-default}-${VAULT_ISSUE}"
          if tmux has-session -t "$VAULT_SESSION" 2>/dev/null; then
            VAULT_INJECT_MSG="Human reply from ${SENDER} in Matrix:

${BODY}

Interpret this response and decide how to proceed."
            VAULT_INJECT_TMP=$(mktemp /tmp/vault-q-inject-XXXXXX)
            printf '%s' "$VAULT_INJECT_MSG" > "$VAULT_INJECT_TMP"
            tmux load-buffer -b "vault-q-${VAULT_ISSUE}" "$VAULT_INJECT_TMP" || true
            tmux paste-buffer -t "$VAULT_SESSION" -b "vault-q-${VAULT_ISSUE}" || true
            sleep 0.5
            tmux send-keys -t "$VAULT_SESSION" "" Enter || true
            tmux delete-buffer -b "vault-q-${VAULT_ISSUE}" 2>/dev/null || true
            rm -f "$VAULT_INJECT_TMP"
            VAULT_INJECTED=true
            log "human reply from ${SENDER} injected into ${VAULT_SESSION}"
            if ! grep -qF "$THREAD_ROOT" "$ACKED_FILE" 2>/dev/null; then
              matrix_send "vault" "✓ Reply forwarded to vault session" "$THREAD_ROOT" >/dev/null 2>&1 || true
              printf '%s\n' "$THREAD_ROOT" >> "$ACKED_FILE"
            fi
          fi
        fi
        # Fallback: parse APPROVE/REJECT for non-session vault actions
        if [ "$VAULT_INJECTED" = false ]; then
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
            log "vault: free-text reply (no session, no APPROVE/REJECT): ${BODY:0:100}"
            matrix_send "vault" "⚠️ No active vault session. Reply with APPROVE <id> or REJECT <id>, or wait for a vault session to start." "$THREAD_ROOT" >/dev/null 2>&1 || true
          fi
        fi
        ;;
      *)
        log "no handler for agent '${AGENT}'"
        ;;
    esac

  done <<< "$EVENTS"
done
