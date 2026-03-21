#!/usr/bin/env bash
# vault-poll.sh — Vault: process pending actions + procurement requests
#
# Runs every 30min via cron. Two pipelines:
#   A. Action gating (*.json): auto-approve/escalate/reject via vault-agent.sh
#   B. Procurement (*.md): notify human, fire approved requests via vault-fire.sh
#
# Phases:
#   1. Retry any approved/ items that weren't fired (crash recovery)
#   2. Auto-reject escalations with no reply for 48h
#   3. Invoke vault-agent.sh for new pending JSON actions
#   4. Notify human about new pending procurement requests (.md)
#
# Cron: */30 * * * * /path/to/disinto/vault/vault-poll.sh
#
# Peek:  cat /tmp/vault-status
# Log:   tail -f /path/to/disinto/vault/vault.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/env.sh"

LOGFILE="${FACTORY_ROOT}/vault/vault.log"
STATUSFILE="/tmp/vault-status"
LOCKFILE="/tmp/vault-poll.lock"
VAULT_DIR="${FACTORY_ROOT}/vault"
LOCKS_DIR="${VAULT_DIR}/.locks"

TIMEOUT_HOURS=48

# Prevent overlapping runs
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
  if kill -0 "$LOCK_PID" 2>/dev/null; then
    exit 0
  fi
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE" "$STATUSFILE"' EXIT

log() {
  printf '[%s] vault: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

status() {
  printf '[%s] vault: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" > "$STATUSFILE"
  log "$*"
}

# Acquire per-action lock (returns 0 if acquired, 1 if already locked)
lock_action() {
  local action_id="$1"
  local lockfile="${LOCKS_DIR}/${action_id}.lock"
  mkdir -p "$LOCKS_DIR"
  if [ -f "$lockfile" ]; then
    local lock_pid
    lock_pid=$(cat "$lockfile" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      return 1
    fi
    rm -f "$lockfile"
  fi
  echo $$ > "$lockfile"
  return 0
}

unlock_action() {
  local action_id="$1"
  rm -f "${LOCKS_DIR}/${action_id}.lock"
}

# =============================================================================
# PHASE 1: Retry approved items (crash recovery — JSON actions + MD procurement)
# =============================================================================
status "phase 1: retrying approved items"

for action_file in "${VAULT_DIR}/approved/"*.json; do
  [ -f "$action_file" ] || continue
  ACTION_ID=$(jq -r '.id // ""' < "$action_file" 2>/dev/null)
  [ -z "$ACTION_ID" ] && continue

  if ! lock_action "$ACTION_ID"; then
    log "skip $ACTION_ID — locked by another process"
    continue
  fi

  log "retrying approved action: $ACTION_ID"
  if bash "${VAULT_DIR}/vault-fire.sh" "$ACTION_ID" >> "$LOGFILE" 2>&1; then
    log "fired $ACTION_ID (retry)"
  else
    log "ERROR: fire failed for $ACTION_ID (retry)"
    matrix_send "vault" "❌ Vault fire failed on retry: ${ACTION_ID}" 2>/dev/null || true
  fi

  unlock_action "$ACTION_ID"
done

# Retry approved procurement requests (.md)
for req_file in "${VAULT_DIR}/approved/"*.md; do
  [ -f "$req_file" ] || continue
  REQ_ID=$(basename "$req_file" .md)

  if ! lock_action "$REQ_ID"; then
    log "skip procurement $REQ_ID — locked by another process"
    continue
  fi

  log "retrying approved procurement: $REQ_ID"
  if bash "${VAULT_DIR}/vault-fire.sh" "$REQ_ID" >> "$LOGFILE" 2>&1; then
    log "fired procurement $REQ_ID (retry)"
  else
    log "ERROR: fire failed for procurement $REQ_ID (retry)"
    matrix_send "vault" "❌ Vault fire failed on retry: ${REQ_ID} (procurement)" 2>/dev/null || true
  fi

  unlock_action "$REQ_ID"
done

# =============================================================================
# PHASE 2: Timeout escalations (48h no reply → auto-reject)
# =============================================================================
status "phase 2: checking escalation timeouts"

NOW_EPOCH=$(date +%s)
TIMEOUT_SECS=$((TIMEOUT_HOURS * 3600))

for action_file in "${VAULT_DIR}/pending/"*.json; do
  [ -f "$action_file" ] || continue

  ACTION_STATUS=$(jq -r '.status // ""' < "$action_file" 2>/dev/null)
  [ "$ACTION_STATUS" != "escalated" ] && continue

  ACTION_ID=$(jq -r '.id // ""' < "$action_file" 2>/dev/null)
  ESCALATED_AT=$(jq -r '.escalated_at // ""' < "$action_file" 2>/dev/null)
  [ -z "$ESCALATED_AT" ] && continue

  ESCALATED_EPOCH=$(date -d "$ESCALATED_AT" +%s 2>/dev/null || echo 0)
  AGE_SECS=$((NOW_EPOCH - ESCALATED_EPOCH))

  if [ "$AGE_SECS" -gt "$TIMEOUT_SECS" ]; then
    AGE_HOURS=$((AGE_SECS / 3600))
    log "timeout: $ACTION_ID escalated ${AGE_HOURS}h ago with no reply — auto-rejecting"
    bash "${VAULT_DIR}/vault-reject.sh" "$ACTION_ID" "timeout (${AGE_HOURS}h, no human reply)" >> "$LOGFILE" 2>&1 || true
    matrix_send "vault" "⏰ Vault auto-rejected ${ACTION_ID} — no reply after ${AGE_HOURS}h" 2>/dev/null || true
  fi
done

# =============================================================================
# PHASE 3: Process new pending actions (JSON — action gating)
# =============================================================================
status "phase 3: processing pending actions"

PENDING_COUNT=0
PENDING_SUMMARY=""

for action_file in "${VAULT_DIR}/pending/"*.json; do
  [ -f "$action_file" ] || continue

  ACTION_STATUS=$(jq -r '.status // ""' < "$action_file" 2>/dev/null)
  # Skip already-escalated actions (waiting for human reply)
  [ "$ACTION_STATUS" = "escalated" ] && continue

  ACTION_ID=$(jq -r '.id // ""' < "$action_file" 2>/dev/null)
  [ -z "$ACTION_ID" ] && continue

  if ! lock_action "$ACTION_ID"; then
    log "skip $ACTION_ID — locked"
    continue
  fi

  PENDING_COUNT=$((PENDING_COUNT + 1))
  ACTION_TYPE=$(jq -r '.type // "unknown"' < "$action_file" 2>/dev/null)
  ACTION_SOURCE=$(jq -r '.source // "unknown"' < "$action_file" 2>/dev/null)
  PENDING_SUMMARY="${PENDING_SUMMARY}  ${ACTION_ID} [${ACTION_TYPE}] from ${ACTION_SOURCE}\n"

  unlock_action "$ACTION_ID"
done

if [ "$PENDING_COUNT" -gt 0 ]; then
  log "found $PENDING_COUNT pending action(s), invoking vault-agent"
  status "invoking vault-agent for $PENDING_COUNT action(s)"

  bash "${VAULT_DIR}/vault-agent.sh" >> "$LOGFILE" 2>&1 || {
    log "ERROR: vault-agent failed"
    matrix_send "vault" "❌ vault-agent.sh failed — check vault.log" 2>/dev/null || true
  }
fi

# =============================================================================
# PHASE 4: Notify human about new pending procurement requests (.md)
# =============================================================================
status "phase 4: processing pending procurement requests"

PROCURE_COUNT=0

for req_file in "${VAULT_DIR}/pending/"*.md; do
  [ -f "$req_file" ] || continue
  REQ_ID=$(basename "$req_file" .md)

  # Check if already notified (marker file)
  if [ -f "${VAULT_DIR}/.locks/${REQ_ID}.notified" ]; then
    continue
  fi

  if ! lock_action "$REQ_ID"; then
    log "skip procurement $REQ_ID — locked"
    continue
  fi

  PROCURE_COUNT=$((PROCURE_COUNT + 1))

  # Extract title from first heading
  REQ_TITLE=$(grep -m1 '^# ' "$req_file" | sed 's/^# //' || echo "$REQ_ID")

  log "new procurement request: $REQ_ID — $REQ_TITLE"

  # Notify human via Matrix
  matrix_send "vault" "🔑 PROCUREMENT REQUEST — ${REQ_TITLE}

ID: ${REQ_ID}
Action: review vault/pending/${REQ_ID}.md
To approve: fulfill the request, add secrets to .env, move file to vault/approved/

$(head -20 "$req_file")" 2>/dev/null || true

  # Mark as notified so we don't re-send
  mkdir -p "${VAULT_DIR}/.locks"
  touch "${VAULT_DIR}/.locks/${REQ_ID}.notified"

  unlock_action "$REQ_ID"
done

if [ "$PENDING_COUNT" -eq 0 ] && [ "$PROCURE_COUNT" -eq 0 ]; then
  status "all clear — no pending items"
else
  status "poll complete — ${PENDING_COUNT} action(s), ${PROCURE_COUNT} procurement request(s)"
fi
