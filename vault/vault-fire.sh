#!/usr/bin/env bash
# vault-fire.sh — Execute an approved vault item by ID
#
# Handles two pipelines:
#   A. Action gating (*.json): pending/ → approved/ → fired/
#      Execution delegated to ephemeral runner container via disinto run.
#      The runner gets vault secrets (.env.vault.enc); this script does NOT.
#   B. Procurement (*.md): approved/ → fired/ (writes RESOURCES.md entry)
#
# If item is in pending/, moves to approved/ first.
# If item is already in approved/, fires directly (crash recovery).
#
# Usage: bash vault-fire.sh <item-id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/vault-env.sh"

OPS_VAULT_DIR="${OPS_REPO_ROOT}/vault"
LOCKS_DIR="${DISINTO_LOG_DIR}/vault/.locks"
LOGFILE="${DISINTO_LOG_DIR}/vault/vault.log"
RESOURCES_FILE="${OPS_REPO_ROOT}/RESOURCES.md"

log() {
  printf '[%s] vault-fire: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

ACTION_ID="${1:?Usage: vault-fire.sh <item-id>}"

# =============================================================================
# Detect pipeline: procurement (.md) or action gating (.json)
# =============================================================================
IS_PROCUREMENT=false
ACTION_FILE=""

if [ -f "${OPS_VAULT_DIR}/approved/${ACTION_ID}.md" ]; then
  IS_PROCUREMENT=true
  ACTION_FILE="${OPS_VAULT_DIR}/approved/${ACTION_ID}.md"
elif [ -f "${OPS_VAULT_DIR}/pending/${ACTION_ID}.md" ]; then
  IS_PROCUREMENT=true
  mv "${OPS_VAULT_DIR}/pending/${ACTION_ID}.md" "${OPS_VAULT_DIR}/approved/${ACTION_ID}.md"
  ACTION_FILE="${OPS_VAULT_DIR}/approved/${ACTION_ID}.md"
  log "$ACTION_ID: pending → approved (procurement)"
elif [ -f "${OPS_VAULT_DIR}/approved/${ACTION_ID}.json" ]; then
  ACTION_FILE="${OPS_VAULT_DIR}/approved/${ACTION_ID}.json"
elif [ -f "${OPS_VAULT_DIR}/pending/${ACTION_ID}.json" ]; then
  mv "${OPS_VAULT_DIR}/pending/${ACTION_ID}.json" "${OPS_VAULT_DIR}/approved/${ACTION_ID}.json"
  ACTION_FILE="${OPS_VAULT_DIR}/approved/${ACTION_ID}.json"
  TMP=$(mktemp)
  jq '.status = "approved"' "$ACTION_FILE" > "$TMP" && mv "$TMP" "$ACTION_FILE"
  log "$ACTION_ID: pending → approved"
else
  log "ERROR: item $ACTION_ID not found in pending/ or approved/"
  exit 1
fi

# Acquire lock
mkdir -p "$LOCKS_DIR"
LOCKFILE="${LOCKS_DIR}/${ACTION_ID}.lock"
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || true)
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "$ACTION_ID: already being fired by PID $LOCK_PID"
    exit 0
  fi
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# =============================================================================
# Pipeline A: Procurement — extract RESOURCES.md entry and append
# =============================================================================
if [ "$IS_PROCUREMENT" = true ]; then
  log "$ACTION_ID: firing procurement request"

  # Extract the proposed RESOURCES.md entry from the markdown file.
  # Everything after the "## Proposed RESOURCES.md Entry" heading to EOF.
  # Uses awk because the entry itself contains ## headings (## <resource-id>).
  ENTRY=""
  ENTRY=$(awk '/^## Proposed RESOURCES\.md Entry/{found=1; next} found{print}' "$ACTION_FILE" 2>/dev/null || true)

  # Strip leading/trailing blank lines and markdown code fences
  ENTRY=$(echo "$ENTRY" | sed '/^```/d' | sed -e '/./,$!d' -e :a -e '/^\n*$/{$d;N;ba;}')

  if [ -z "$ENTRY" ]; then
    log "ERROR: $ACTION_ID has no '## Proposed RESOURCES.md Entry' section"
    exit 1
  fi

  # Append entry to RESOURCES.md
  printf '\n%s\n' "$ENTRY" >> "$RESOURCES_FILE"
  log "$ACTION_ID: wrote RESOURCES.md entry"

  # Move to fired/
  mv "$ACTION_FILE" "${OPS_VAULT_DIR}/fired/${ACTION_ID}.md"
  rm -f "${LOCKS_DIR}/${ACTION_ID}.notified"
  log "$ACTION_ID: approved → fired (procurement)"
  exit 0
fi

# =============================================================================
# Pipeline B: Action gating — delegate to ephemeral runner container
# =============================================================================
ACTION_TYPE=$(jq -r '.type // ""' < "$ACTION_FILE")
ACTION_SOURCE=$(jq -r '.source // ""' < "$ACTION_FILE")

if [ -z "$ACTION_TYPE" ]; then
  log "ERROR: $ACTION_ID has no type field"
  exit 1
fi

log "$ACTION_ID: firing type=$ACTION_TYPE source=$ACTION_SOURCE via runner"

FIRE_EXIT=0

# Delegate execution to the ephemeral runner container.
# The runner gets vault secrets (.env.vault.enc) injected at runtime;
# this host process never sees those secrets.
if [ -f "${FACTORY_ROOT}/.env.vault.enc" ] && [ -f "${FACTORY_ROOT}/docker-compose.yml" ]; then
  bash "${FACTORY_ROOT}/bin/disinto" run "$ACTION_ID" >> "$LOGFILE" 2>&1 || FIRE_EXIT=$?
else
  # Fallback for bare-metal or pre-migration setups: run action handler directly
  log "$ACTION_ID: no .env.vault.enc or docker-compose.yml — running action directly"
  bash "${SCRIPT_DIR}/run-action.sh" "$ACTION_ID" >> "$LOGFILE" 2>&1 || FIRE_EXIT=$?
fi

# =============================================================================
# Move to fired/ or leave in approved/ on failure
# =============================================================================
if [ "$FIRE_EXIT" -eq 0 ]; then
  # Update with fired timestamp and move to fired/
  TMP=$(mktemp)
  jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status = "fired" | .fired_at = $ts' "$ACTION_FILE" > "$TMP" \
    && mv "$TMP" "${OPS_VAULT_DIR}/fired/${ACTION_ID}.json"
  rm -f "$ACTION_FILE"
  log "$ACTION_ID: approved → fired"
else
  log "ERROR: $ACTION_ID fire failed (exit $FIRE_EXIT) — stays in approved/ for retry"
  exit "$FIRE_EXIT"
fi
