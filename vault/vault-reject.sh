#!/usr/bin/env bash
# vault-reject.sh — Move a vault action to rejected/ with reason
#
# Usage: bash vault-reject.sh <action-id> "<reason>"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/env.sh"

VAULT_DIR="${FACTORY_ROOT}/vault"
LOGFILE="${VAULT_DIR}/vault.log"

log() {
  printf '[%s] vault-reject: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

ACTION_ID="${1:?Usage: vault-reject.sh <action-id> \"<reason>\"}"
REASON="${2:-unspecified}"

# Find the action file
ACTION_FILE=""
if [ -f "${VAULT_DIR}/pending/${ACTION_ID}.json" ]; then
  ACTION_FILE="${VAULT_DIR}/pending/${ACTION_ID}.json"
elif [ -f "${VAULT_DIR}/approved/${ACTION_ID}.json" ]; then
  ACTION_FILE="${VAULT_DIR}/approved/${ACTION_ID}.json"
else
  log "ERROR: action $ACTION_ID not found in pending/ or approved/"
  exit 1
fi

# Update with rejection metadata and move to rejected/
TMP=$(mktemp)
jq --arg reason "$REASON" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.status = "rejected" | .rejected_at = $ts | .reject_reason = $reason' \
  "$ACTION_FILE" > "$TMP" && mv "$TMP" "${VAULT_DIR}/rejected/${ACTION_ID}.json"
rm -f "$ACTION_FILE"

# Clean up lock if present
rm -f "${VAULT_DIR}/.locks/${ACTION_ID}.lock"

log "$ACTION_ID: rejected — $REASON"
