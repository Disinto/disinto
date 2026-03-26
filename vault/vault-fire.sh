#!/usr/bin/env bash
# vault-fire.sh — Execute an approved vault item by ID
#
# Handles two pipelines:
#   A. Action gating (*.json): pending/ → approved/ → fired/
#   B. Procurement (*.md): approved/ → fired/ (writes RESOURCES.md entry)
#
# If item is in pending/, moves to approved/ first.
# If item is already in approved/, fires directly (crash recovery).
#
# Usage: bash vault-fire.sh <item-id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/env.sh"

VAULT_DIR="${FACTORY_ROOT}/vault"
LOCKS_DIR="${VAULT_DIR}/.locks"
LOGFILE="${VAULT_DIR}/vault.log"
RESOURCES_FILE="${PROJECT_REPO_ROOT:-${FACTORY_ROOT}}/RESOURCES.md"

log() {
  printf '[%s] vault-fire: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

ACTION_ID="${1:?Usage: vault-fire.sh <item-id>}"

# =============================================================================
# Detect pipeline: procurement (.md) or action gating (.json)
# =============================================================================
IS_PROCUREMENT=false
ACTION_FILE=""

if [ -f "${VAULT_DIR}/approved/${ACTION_ID}.md" ]; then
  IS_PROCUREMENT=true
  ACTION_FILE="${VAULT_DIR}/approved/${ACTION_ID}.md"
elif [ -f "${VAULT_DIR}/pending/${ACTION_ID}.md" ]; then
  IS_PROCUREMENT=true
  mv "${VAULT_DIR}/pending/${ACTION_ID}.md" "${VAULT_DIR}/approved/${ACTION_ID}.md"
  ACTION_FILE="${VAULT_DIR}/approved/${ACTION_ID}.md"
  log "$ACTION_ID: pending → approved (procurement)"
elif [ -f "${VAULT_DIR}/approved/${ACTION_ID}.json" ]; then
  ACTION_FILE="${VAULT_DIR}/approved/${ACTION_ID}.json"
elif [ -f "${VAULT_DIR}/pending/${ACTION_ID}.json" ]; then
  mv "${VAULT_DIR}/pending/${ACTION_ID}.json" "${VAULT_DIR}/approved/${ACTION_ID}.json"
  ACTION_FILE="${VAULT_DIR}/approved/${ACTION_ID}.json"
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
  mv "$ACTION_FILE" "${VAULT_DIR}/fired/${ACTION_ID}.md"
  rm -f "${LOCKS_DIR}/${ACTION_ID}.notified"
  log "$ACTION_ID: approved → fired (procurement)"
  exit 0
fi

# =============================================================================
# Pipeline B: Action gating — dispatch to handler
# =============================================================================
ACTION_TYPE=$(jq -r '.type // ""' < "$ACTION_FILE")
ACTION_SOURCE=$(jq -r '.source // ""' < "$ACTION_FILE")
PAYLOAD=$(jq -c '.payload // {}' < "$ACTION_FILE")

if [ -z "$ACTION_TYPE" ]; then
  log "ERROR: $ACTION_ID has no type field"
  exit 1
fi

log "$ACTION_ID: firing type=$ACTION_TYPE source=$ACTION_SOURCE"

FIRE_EXIT=0

case "$ACTION_TYPE" in
  webhook-call)
    # Universal handler: HTTP call to endpoint with optional method/headers/body
    ENDPOINT=$(echo "$PAYLOAD" | jq -r '.endpoint // ""')
    METHOD=$(echo "$PAYLOAD" | jq -r '.method // "POST"')
    REQ_BODY=$(echo "$PAYLOAD" | jq -r '.body // ""')
    HEADERS=$(echo "$PAYLOAD" | jq -r '.headers // {} | to_entries[] | "-H\n\(.key): \(.value)"' 2>/dev/null || true)

    if [ -z "$ENDPOINT" ]; then
      log "ERROR: $ACTION_ID webhook-call missing endpoint"
      exit 1
    fi

    # Build curl args
    CURL_ARGS=(-sf -X "$METHOD" -o /dev/null -w "%{http_code}")
    if [ -n "$HEADERS" ]; then
      while IFS= read -r header; do
        [ -n "$header" ] && CURL_ARGS+=(-H "$header")
      done < <(echo "$PAYLOAD" | jq -r '.headers // {} | to_entries[] | "\(.key): \(.value)"' 2>/dev/null || true)
    fi
    if [ -n "$REQ_BODY" ] && [ "$REQ_BODY" != "null" ]; then
      CURL_ARGS+=(-d "$REQ_BODY")
    fi

    HTTP_CODE=$(curl "${CURL_ARGS[@]}" "$ENDPOINT" 2>/dev/null) || HTTP_CODE="000"
    if [[ "$HTTP_CODE" =~ ^2 ]]; then
      log "$ACTION_ID: webhook-call → HTTP $HTTP_CODE OK"
    else
      log "ERROR: $ACTION_ID webhook-call → HTTP $HTTP_CODE"
      FIRE_EXIT=1
    fi
    ;;

  blog-post|social-post|email-blast|pricing-change|dns-change|stripe-charge)
    # Check for a handler script
    HANDLER="${VAULT_DIR}/handlers/${ACTION_TYPE}.sh"
    if [ -x "$HANDLER" ]; then
      bash "$HANDLER" "$ACTION_ID" "$PAYLOAD" >> "$LOGFILE" 2>&1 || FIRE_EXIT=$?
    else
      log "ERROR: $ACTION_ID no handler for type '$ACTION_TYPE' (${HANDLER} not found)"
      FIRE_EXIT=1
    fi
    ;;

  *)
    log "ERROR: $ACTION_ID unknown action type '$ACTION_TYPE'"
    FIRE_EXIT=1
    ;;
esac

# =============================================================================
# Move to fired/ or leave in approved/ on failure
# =============================================================================
if [ "$FIRE_EXIT" -eq 0 ]; then
  # Update with fired timestamp and move to fired/
  TMP=$(mktemp)
  jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status = "fired" | .fired_at = $ts' "$ACTION_FILE" > "$TMP" \
    && mv "$TMP" "${VAULT_DIR}/fired/${ACTION_ID}.json"
  rm -f "$ACTION_FILE"
  log "$ACTION_ID: approved → fired"
else
  log "ERROR: $ACTION_ID fire failed (exit $FIRE_EXIT) — stays in approved/ for retry"
  exit "$FIRE_EXIT"
fi
