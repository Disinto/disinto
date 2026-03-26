#!/usr/bin/env bash
# vault-run-action.sh — Execute an action inside the ephemeral vault-runner container
#
# This script is the entrypoint for the vault-runner container. It runs with
# vault secrets injected as environment variables (GITHUB_TOKEN, CLAWHUB_TOKEN,
# deploy keys, etc.) and dispatches to the appropriate action handler.
#
# The vault-runner container is ephemeral: it starts, runs the action, and is
# destroyed. Secrets exist only in container memory, never on disk.
#
# Usage: vault-run-action.sh <action-id>

set -euo pipefail

VAULT_DIR="${DISINTO_VAULT_DIR:-/home/agent/disinto/vault}"
LOGFILE="${VAULT_DIR}/vault.log"
ACTION_ID="${1:?Usage: vault-run-action.sh <action-id>}"

log() {
  printf '[%s] vault-runner: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE" 2>/dev/null || \
    printf '[%s] vault-runner: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >&2
}

# Find action file in approved/
ACTION_FILE="${VAULT_DIR}/approved/${ACTION_ID}.json"
if [ ! -f "$ACTION_FILE" ]; then
  log "ERROR: action file not found: ${ACTION_FILE}"
  echo "ERROR: action file not found: ${ACTION_FILE}" >&2
  exit 1
fi

ACTION_TYPE=$(jq -r '.type // ""' < "$ACTION_FILE")
ACTION_SOURCE=$(jq -r '.source // ""' < "$ACTION_FILE")
PAYLOAD=$(jq -c '.payload // {}' < "$ACTION_FILE")

if [ -z "$ACTION_TYPE" ]; then
  log "ERROR: ${ACTION_ID} has no type field"
  exit 1
fi

log "${ACTION_ID}: executing type=${ACTION_TYPE} source=${ACTION_SOURCE}"

FIRE_EXIT=0

case "$ACTION_TYPE" in
  webhook-call)
    # HTTP call to endpoint with optional method/headers/body
    ENDPOINT=$(echo "$PAYLOAD" | jq -r '.endpoint // ""')
    METHOD=$(echo "$PAYLOAD" | jq -r '.method // "POST"')
    REQ_BODY=$(echo "$PAYLOAD" | jq -r '.body // ""')

    if [ -z "$ENDPOINT" ]; then
      log "ERROR: ${ACTION_ID} webhook-call missing endpoint"
      exit 1
    fi

    CURL_ARGS=(-sf -X "$METHOD" -o /dev/null -w "%{http_code}")
    while IFS= read -r header; do
      [ -n "$header" ] && CURL_ARGS+=(-H "$header")
    done < <(echo "$PAYLOAD" | jq -r '.headers // {} | to_entries[] | "\(.key): \(.value)"' 2>/dev/null || true)
    if [ -n "$REQ_BODY" ] && [ "$REQ_BODY" != "null" ]; then
      CURL_ARGS+=(-d "$REQ_BODY")
    fi

    HTTP_CODE=$(curl "${CURL_ARGS[@]}" "$ENDPOINT" 2>/dev/null) || HTTP_CODE="000"
    if [[ "$HTTP_CODE" =~ ^2 ]]; then
      log "${ACTION_ID}: webhook-call -> HTTP ${HTTP_CODE} OK"
    else
      log "ERROR: ${ACTION_ID} webhook-call -> HTTP ${HTTP_CODE}"
      FIRE_EXIT=1
    fi
    ;;

  blog-post|social-post|email-blast|pricing-change|dns-change|stripe-charge)
    HANDLER="${VAULT_DIR}/handlers/${ACTION_TYPE}.sh"
    if [ -x "$HANDLER" ]; then
      bash "$HANDLER" "$ACTION_ID" "$PAYLOAD" 2>&1 || FIRE_EXIT=$?
    else
      log "ERROR: ${ACTION_ID} no handler for type '${ACTION_TYPE}' (${HANDLER} not found)"
      FIRE_EXIT=1
    fi
    ;;

  *)
    log "ERROR: ${ACTION_ID} unknown action type '${ACTION_TYPE}'"
    FIRE_EXIT=1
    ;;
esac

exit "$FIRE_EXIT"
