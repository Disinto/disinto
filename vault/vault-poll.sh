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
# Use vault-bot's own Forgejo identity (#747)
FORGE_TOKEN="${FORGE_VAULT_TOKEN:-${FORGE_TOKEN}}"

LOGFILE="${DISINTO_LOG_DIR}/vault/vault.log"
STATUSFILE="/tmp/vault-status"
LOCKFILE="/tmp/vault-poll.lock"
VAULT_SCRIPT_DIR="${FACTORY_ROOT}/vault"
OPS_VAULT_DIR="${OPS_REPO_ROOT}/vault"
LOCKS_DIR="${DISINTO_LOG_DIR}/vault/.locks"

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

for action_file in "${OPS_VAULT_DIR}/approved/"*.json; do
  [ -f "$action_file" ] || continue
  ACTION_ID=$(jq -r '.id // ""' < "$action_file" 2>/dev/null)
  [ -z "$ACTION_ID" ] && continue

  if ! lock_action "$ACTION_ID"; then
    log "skip $ACTION_ID — locked by another process"
    continue
  fi

  log "retrying approved action: $ACTION_ID"
  if bash "${VAULT_SCRIPT_DIR}/vault-fire.sh" "$ACTION_ID" >> "$LOGFILE" 2>&1; then
    log "fired $ACTION_ID (retry)"
  else
    log "ERROR: fire failed for $ACTION_ID (retry)"
  fi

  unlock_action "$ACTION_ID"
done

# Retry approved procurement requests (.md)
for req_file in "${OPS_VAULT_DIR}/approved/"*.md; do
  [ -f "$req_file" ] || continue
  REQ_ID=$(basename "$req_file" .md)

  if ! lock_action "$REQ_ID"; then
    log "skip procurement $REQ_ID — locked by another process"
    continue
  fi

  log "retrying approved procurement: $REQ_ID"
  if bash "${VAULT_SCRIPT_DIR}/vault-fire.sh" "$REQ_ID" >> "$LOGFILE" 2>&1; then
    log "fired procurement $REQ_ID (retry)"
  else
    log "ERROR: fire failed for procurement $REQ_ID (retry)"
  fi

  unlock_action "$REQ_ID"
done

# =============================================================================
# PHASE 2: Timeout escalations (48h no reply → auto-reject)
# =============================================================================
status "phase 2: checking escalation timeouts"

NOW_EPOCH=$(date +%s)
TIMEOUT_SECS=$((TIMEOUT_HOURS * 3600))

for action_file in "${OPS_VAULT_DIR}/pending/"*.json; do
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
    bash "${VAULT_SCRIPT_DIR}/vault-reject.sh" "$ACTION_ID" "timeout (${AGE_HOURS}h, no human reply)" >> "$LOGFILE" 2>&1 || true
  fi
done

# =============================================================================
# PHASE 3: Process new pending actions (JSON — action gating)
# =============================================================================
status "phase 3: processing pending actions"

PENDING_COUNT=0
PENDING_SUMMARY=""

for action_file in "${OPS_VAULT_DIR}/pending/"*.json; do
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

  bash "${VAULT_SCRIPT_DIR}/vault-agent.sh" >> "$LOGFILE" 2>&1 || {
    log "ERROR: vault-agent failed"
  }
fi

# =============================================================================
# PHASE 4: Notify human about new pending procurement requests (.md)
# =============================================================================
status "phase 4: processing pending procurement requests"

PROCURE_COUNT=0

for req_file in "${OPS_VAULT_DIR}/pending/"*.md; do
  [ -f "$req_file" ] || continue
  REQ_ID=$(basename "$req_file" .md)

  # Check if already notified (marker file)
  if [ -f "${LOCKS_DIR}/${REQ_ID}.notified" ]; then
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

  # Mark as notified so we don't re-send
  mkdir -p "${LOCKS_DIR}"
  touch "${LOCKS_DIR}/${REQ_ID}.notified"

  unlock_action "$REQ_ID"
done

# =============================================================================
# PHASE 5: Detect vault-bot authorized comments on issues
# =============================================================================
status "phase 5: scanning for vault-bot authorized comments"

COMMENT_COUNT=0

if [ -n "${FORGE_REPO:-}" ] && [ -n "${FORGE_TOKEN:-}" ]; then
  # Get open issues with action label
  ACTION_ISSUES=$(curl -sf \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_URL}/api/v1/repos/${FORGE_REPO}/issues?state=open&labels=action&limit=50" 2>/dev/null) || ACTION_ISSUES="[]"

  ISSUE_COUNT=$(printf '%s' "$ACTION_ISSUES" | jq 'length')
  for idx in $(seq 0 $((ISSUE_COUNT - 1))); do
    ISSUE_NUM=$(printf '%s' "$ACTION_ISSUES" | jq -r ".[$idx].number")

    # Skip if already processed
    if [ -f "${LOCKS_DIR}/issue-${ISSUE_NUM}.vault-fired" ]; then
      continue
    fi

    # Get comments on this issue
    COMMENTS=$(curl -sf \
      -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_URL}/api/v1/repos/${FORGE_REPO}/issues/${ISSUE_NUM}/comments?limit=50" 2>/dev/null) || continue

    # Look for vault-bot comments containing VAULT:APPROVED with a JSON action spec
    APPROVED_BODY=$(printf '%s' "$COMMENTS" | jq -r '
      [.[] | select(.user.login == "vault-bot") | select(.body | test("VAULT:APPROVED"))] | last | .body // empty
    ' 2>/dev/null) || continue

    [ -z "$APPROVED_BODY" ] && continue

    # Extract JSON action spec from fenced code block in the comment
    ACTION_JSON=$(printf '%s' "$APPROVED_BODY" | sed -n '/^```json$/,/^```$/p' | sed '1d;$d')
    [ -z "$ACTION_JSON" ] && continue

    # Validate JSON
    if ! printf '%s' "$ACTION_JSON" | jq empty 2>/dev/null; then
      log "malformed action JSON in vault-bot comment on issue #${ISSUE_NUM}"
      continue
    fi

    ACTION_ID=$(printf '%s' "$ACTION_JSON" | jq -r '.id // empty')
    if [ -z "$ACTION_ID" ]; then
      ACTION_ID="issue-${ISSUE_NUM}-$(date +%s)"
      ACTION_JSON=$(printf '%s' "$ACTION_JSON" | jq --arg id "$ACTION_ID" '.id = $id')
    fi

    # Skip if this action already exists in any stage
    if [ -f "${OPS_VAULT_DIR}/approved/${ACTION_ID}.json" ] || \
       [ -f "${OPS_VAULT_DIR}/fired/${ACTION_ID}.json" ] || \
       [ -f "${OPS_VAULT_DIR}/rejected/${ACTION_ID}.json" ]; then
      continue
    fi

    log "vault-bot authorized action on issue #${ISSUE_NUM}: ${ACTION_ID}"
    printf '%s' "$ACTION_JSON" | jq '.status = "approved"' > "${OPS_VAULT_DIR}/approved/${ACTION_ID}.json"
    COMMENT_COUNT=$((COMMENT_COUNT + 1))

    # Fire the action
    if bash "${VAULT_SCRIPT_DIR}/vault-fire.sh" "$ACTION_ID" >> "$LOGFILE" 2>&1; then
      log "fired ${ACTION_ID} from issue #${ISSUE_NUM}"
      # Mark issue as processed
      touch "${LOCKS_DIR}/issue-${ISSUE_NUM}.vault-fired"
    else
      log "ERROR: fire failed for ${ACTION_ID} from issue #${ISSUE_NUM}"
    fi
  done
fi

if [ "$PENDING_COUNT" -eq 0 ] && [ "$PROCURE_COUNT" -eq 0 ] && [ "$COMMENT_COUNT" -eq 0 ]; then
  status "all clear — no pending items"
else
  status "poll complete — ${PENDING_COUNT} action(s), ${PROCURE_COUNT} procurement(s), ${COMMENT_COUNT} comment-authorized"
fi
