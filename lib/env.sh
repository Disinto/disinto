#!/usr/bin/env bash
# env.sh — Load environment and shared utilities
# Source this at the top of every script: source "$(dirname "$0")/lib/env.sh"

set -euo pipefail

# Resolve script root (parent of lib/)
FACTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Container detection: when running inside the agent container, DISINTO_CONTAINER
# is set by docker-compose.yml.  Adjust paths so phase files, logs, and thread
# maps land on the persistent volume instead of /tmp (which is ephemeral).
if [ "${DISINTO_CONTAINER:-}" = "1" ]; then
  DISINTO_DATA_DIR="${HOME}/data"
  mkdir -p "${DISINTO_DATA_DIR}"
fi

# Load secrets: prefer .env.enc (SOPS-encrypted), fall back to plaintext .env
if [ -f "$FACTORY_ROOT/.env.enc" ] && command -v sops &>/dev/null; then
  set -a
  eval "$(sops -d --output-type dotenv "$FACTORY_ROOT/.env.enc" 2>/dev/null)" \
    || echo "Warning: failed to decrypt .env.enc — secrets not loaded" >&2
  set +a
elif [ -f "$FACTORY_ROOT/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$FACTORY_ROOT/.env"
  set +a
fi

# PATH: foundry, node, system
export PATH="${HOME}/.local/bin:${HOME}/.foundry/bin:${HOME}/.nvm/versions/node/v22.20.0/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export HOME="${HOME:-/home/debian}"

# Load project TOML if PROJECT_TOML is set (by poll scripts that accept project arg)
if [ -n "${PROJECT_TOML:-}" ] && [ -f "$PROJECT_TOML" ]; then
  source "${FACTORY_ROOT}/lib/load-project.sh" "$PROJECT_TOML"
fi

# Forge token: new FORGE_TOKEN > legacy CODEBERG_TOKEN
if [ -z "${FORGE_TOKEN:-}" ]; then
  FORGE_TOKEN="${CODEBERG_TOKEN:-}"
fi
export FORGE_TOKEN
export CODEBERG_TOKEN="${FORGE_TOKEN}"  # backwards compat

# Review bot token: FORGE_REVIEW_TOKEN > legacy REVIEW_BOT_TOKEN
export FORGE_REVIEW_TOKEN="${FORGE_REVIEW_TOKEN:-${REVIEW_BOT_TOKEN:-}}"
export REVIEW_BOT_TOKEN="${FORGE_REVIEW_TOKEN}"  # backwards compat

# Bot usernames filter: FORGE_BOT_USERNAMES > legacy CODEBERG_BOT_USERNAMES
export FORGE_BOT_USERNAMES="${FORGE_BOT_USERNAMES:-${CODEBERG_BOT_USERNAMES:-}}"
export CODEBERG_BOT_USERNAMES="${FORGE_BOT_USERNAMES}"  # backwards compat

# Project config (FORGE_* preferred, CODEBERG_* fallback)
export FORGE_REPO="${FORGE_REPO:-${CODEBERG_REPO:-}}"
export CODEBERG_REPO="${FORGE_REPO}"  # backwards compat
export FORGE_URL="${FORGE_URL:-http://localhost:3000}"
export FORGE_API="${FORGE_API:-${FORGE_URL}/api/v1/repos/${FORGE_REPO}}"
export FORGE_WEB="${FORGE_WEB:-${FORGE_URL}/${FORGE_REPO}}"
export CODEBERG_API="${FORGE_API}"  # backwards compat
export CODEBERG_WEB="${FORGE_WEB}"  # backwards compat
export PROJECT_NAME="${PROJECT_NAME:-${FORGE_REPO##*/}}"
export PROJECT_REPO_ROOT="${PROJECT_REPO_ROOT:-/home/${USER}/${PROJECT_NAME}}"
export PRIMARY_BRANCH="${PRIMARY_BRANCH:-master}"
export WOODPECKER_REPO_ID="${WOODPECKER_REPO_ID:-}"
export WOODPECKER_SERVER="${WOODPECKER_SERVER:-http://localhost:8000}"
export CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-7200}"

# Matrix homeserver: inside compose Dendrite is at http://dendrite:8008,
# on bare metal it defaults to http://localhost:8008.
if [ -z "${MATRIX_HOMESERVER:-}" ]; then
  if [ "${DISINTO_CONTAINER:-}" = "1" ]; then
    export MATRIX_HOMESERVER="http://dendrite:8008"
  else
    export MATRIX_HOMESERVER="http://localhost:8008"
  fi
else
  export MATRIX_HOMESERVER
fi

# Shared log helper
log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*"
}

# Forge API helper — usage: forge_api GET /issues?state=open
forge_api() {
  local method="$1" path="$2"
  shift 2
  curl -sf -X "$method" \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}${path}" "$@"
}
# Backwards-compat alias
codeberg_api() { forge_api "$@"; }

# Paginate a Forge API GET endpoint and return all items as a merged JSON array.
# Usage: forge_api_all /path             (no existing query params)
#        forge_api_all /path?a=b         (with existing params — appends &limit=50&page=N)
#        forge_api_all /path TOKEN       (optional second arg: token; defaults to $FORGE_TOKEN)
forge_api_all() {
  local path_prefix="$1"
  local FORGE_TOKEN="${2:-${FORGE_TOKEN}}"
  local sep page page_items count all_items="[]"
  case "$path_prefix" in
    *"?"*) sep="&" ;;
    *) sep="?" ;;
  esac
  page=1
  while true; do
    page_items=$(forge_api GET "${path_prefix}${sep}limit=50&page=${page}")
    count=$(printf '%s' "$page_items" | jq 'length')
    [ "$count" -eq 0 ] && break
    all_items=$(printf '%s\n%s' "$all_items" "$page_items" | jq -s 'add')
    [ "$count" -lt 50 ] && break
    page=$((page + 1))
  done
  printf '%s' "$all_items"
}
# Backwards-compat alias
codeberg_api_all() { forge_api_all "$@"; }

# Woodpecker API helper
woodpecker_api() {
  local path="$1"
  shift
  curl -sfL \
    -H "Authorization: Bearer ${WOODPECKER_TOKEN}" \
    "${WOODPECKER_SERVER}/api${path}" "$@"
}

# Woodpecker DB query helper
wpdb() {
  PGPASSWORD="${WOODPECKER_DB_PASSWORD}" psql \
    -U "${WOODPECKER_DB_USER:-woodpecker}" \
    -h "${WOODPECKER_DB_HOST:-127.0.0.1}" \
    -d "${WOODPECKER_DB_NAME:-woodpecker}" \
    -t "$@" 2>/dev/null
}

# Matrix messaging helper — usage: matrix_send <prefix> <message> [thread_event_id] [context_tag]
# Returns event_id on stdout. Registers threads for listener dispatch.
# context_tag is stored in the thread map (e.g. issue number) for routing replies.
# Thread map: use persistent data dir inside container, /tmp on bare metal
if [ "${DISINTO_CONTAINER:-}" = "1" ]; then
  MATRIX_THREAD_MAP="${MATRIX_THREAD_MAP:-${DISINTO_DATA_DIR}/matrix-thread-map}"
else
  MATRIX_THREAD_MAP="${MATRIX_THREAD_MAP:-/tmp/matrix-thread-map}"
fi
matrix_send() {
  [ -z "${MATRIX_TOKEN:-}" ] && return 0
  local prefix="$1" msg="$2" thread_id="${3:-}" ctx_tag="${4:-}"
  local room_encoded="${MATRIX_ROOM_ID//!/%21}"
  local txn
  txn="$(date +%s%N)$$"
  local body
  if [ -n "$thread_id" ]; then
    body=$(jq -nc --arg m "[${prefix}] ${msg}" --arg t "$thread_id" \
      '{msgtype:"m.text",body:$m,"m.relates_to":{rel_type:"m.thread",event_id:$t}}')
  else
    body=$(jq -nc --arg m "[${prefix}] ${msg}" '{msgtype:"m.text",body:$m}')
  fi
  local response
  response=$(curl -s -X PUT \
    -H "Authorization: Bearer ${MATRIX_TOKEN}" \
    -H "Content-Type: application/json" \
    "${MATRIX_HOMESERVER}/_matrix/client/v3/rooms/${room_encoded}/send/m.room.message/${txn}" \
    -d "$body" 2>/dev/null) || return 0
  local event_id
  event_id=$(printf '%s' "$response" | jq -r '.event_id // empty' 2>/dev/null)
  if [ -n "$event_id" ]; then
    printf '%s' "$event_id"
    # Register thread root for listener dispatch (escalations only)
    if [ -z "$thread_id" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$event_id" "$prefix" "$(date +%s)" "${ctx_tag}" "${PROJECT_NAME:-}" >> "$MATRIX_THREAD_MAP" 2>/dev/null || true
    fi
  fi
}

# matrix_send_ctx — Send rich Matrix message with HTML formatting
# Usage: matrix_send_ctx <prefix> <plain_text> <html_body> [thread_event_id]
# Use for notifications that benefit from links, code blocks, or structured content.
matrix_send_ctx() {
  [ -z "${MATRIX_TOKEN:-}" ] && return 0
  local prefix="$1" plain="$2" html="$3" thread_id="${4:-}"
  local room_encoded="${MATRIX_ROOM_ID//!/%21}"
  local txn
  txn="$(date +%s%N)$$"
  local body
  if [ -n "$thread_id" ]; then
    body=$(jq -nc \
      --arg m "[${prefix}] ${plain}" \
      --arg h "<b>[${prefix}]</b> ${html}" \
      --arg t "$thread_id" \
      '{msgtype:"m.text",body:$m,format:"org.matrix.custom.html",formatted_body:$h,"m.relates_to":{rel_type:"m.thread",event_id:$t}}')
  else
    body=$(jq -nc \
      --arg m "[${prefix}] ${plain}" \
      --arg h "<b>[${prefix}]</b> ${html}" \
      '{msgtype:"m.text",body:$m,format:"org.matrix.custom.html",formatted_body:$h}')
  fi
  local response
  response=$(curl -s -X PUT \
    -H "Authorization: Bearer ${MATRIX_TOKEN}" \
    -H "Content-Type: application/json" \
    "${MATRIX_HOMESERVER}/_matrix/client/v3/rooms/${room_encoded}/send/m.room.message/${txn}" \
    -d "$body" 2>/dev/null) || return 0
  local event_id
  event_id=$(printf '%s' "$response" | jq -r '.event_id // empty' 2>/dev/null)
  if [ -n "$event_id" ]; then
    printf '%s' "$event_id"
  fi
}
