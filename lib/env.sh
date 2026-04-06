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
  DISINTO_LOG_DIR="${DISINTO_DATA_DIR}/logs"
  mkdir -p "${DISINTO_DATA_DIR}" "${DISINTO_LOG_DIR}"/{dev,action,review,supervisor,vault,site,metrics,gardener}
else
  DISINTO_LOG_DIR="${FACTORY_ROOT}"
fi
export DISINTO_LOG_DIR

# Load secrets: prefer .env.enc (SOPS-encrypted), fall back to plaintext .env.
# Always source .env — cron jobs inside the container do NOT inherit compose
# env vars (FORGE_TOKEN, etc.). Compose-injected vars (like FORGE_URL) are
# already set and won't be clobbered since env.sh uses ${VAR:-default} patterns
# for derived values. FORGE_URL from .env (localhost:3000) is overridden below
# by the compose-injected value when running via docker exec.
if [ -f "$FACTORY_ROOT/.env.enc" ] && command -v sops &>/dev/null; then
  set -a
  _saved_forge_url="${FORGE_URL:-}"
  _saved_forge_token="${FORGE_TOKEN:-}"
  # Use temp file + validate dotenv format before sourcing (avoids eval injection)
  # SOPS -d automatically verifies MAC/GCM authentication tag during decryption
  _tmpenv=$(mktemp) || { echo "Error: failed to create temp file for .env.enc" >&2; exit 1; }
  if ! sops -d --output-type dotenv "$FACTORY_ROOT/.env.enc" > "$_tmpenv" 2>/dev/null; then
    echo "Error: failed to decrypt .env.enc — decryption failed, possible corruption" >&2
    rm -f "$_tmpenv"
    exit 1
  fi
  # Validate: non-empty, non-comment lines must match KEY=value pattern
  # Filter out blank lines and comments before validation
  _validated=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$_tmpenv" 2>/dev/null || true)
  if [ -n "$_validated" ]; then
    # Write validated content to a second temp file and source it
    _validated_env=$(mktemp)
    printf '%s\n' "$_validated" > "$_validated_env"
    # shellcheck source=/dev/null
    source "$_validated_env"
    rm -f "$_validated_env"
  else
    echo "Error: .env.enc decryption output failed format validation" >&2
    rm -f "$_tmpenv"
    exit 1
  fi
  rm -f "$_tmpenv"
  set +a
  [ -n "$_saved_forge_url" ] && export FORGE_URL="$_saved_forge_url"
  [ -n "$_saved_forge_token" ] && export FORGE_TOKEN="$_saved_forge_token"
elif [ -f "$FACTORY_ROOT/.env" ]; then
  # Preserve compose-injected FORGE_URL (localhost in .env != forgejo in Docker)
  _saved_forge_url="${FORGE_URL:-}"
  _saved_forge_token="${FORGE_TOKEN:-}"
  set -a
  # shellcheck source=/dev/null
  source "$FACTORY_ROOT/.env"
  set +a
  [ -n "$_saved_forge_url" ] && export FORGE_URL="$_saved_forge_url"
  [ -n "$_saved_forge_token" ] && export FORGE_TOKEN="$_saved_forge_token"
fi

# PATH: foundry, node, system
export PATH="${HOME}/.local/bin:${HOME}/.foundry/bin:${HOME}/.nvm/versions/node/v22.20.0/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export HOME="${HOME:-/home/debian}"

# Load project TOML if PROJECT_TOML is set (by poll scripts that accept project arg)
if [ -n "${PROJECT_TOML:-}" ] && [ -f "$PROJECT_TOML" ]; then
  source "${FACTORY_ROOT}/lib/load-project.sh" "$PROJECT_TOML"
fi

# Forge token
export FORGE_TOKEN="${FORGE_TOKEN:-}"

# Review bot token
export FORGE_REVIEW_TOKEN="${FORGE_REVIEW_TOKEN:-${REVIEW_BOT_TOKEN:-}}"

# Per-agent tokens (#747): each agent gets its own Forgejo identity.
# Falls back to FORGE_TOKEN for backwards compat with single-token setups.
export FORGE_PLANNER_TOKEN="${FORGE_PLANNER_TOKEN:-${FORGE_TOKEN}}"
export FORGE_GARDENER_TOKEN="${FORGE_GARDENER_TOKEN:-${FORGE_TOKEN}}"
export FORGE_VAULT_TOKEN="${FORGE_VAULT_TOKEN:-${FORGE_TOKEN}}"
export FORGE_SUPERVISOR_TOKEN="${FORGE_SUPERVISOR_TOKEN:-${FORGE_TOKEN}}"
export FORGE_PREDICTOR_TOKEN="${FORGE_PREDICTOR_TOKEN:-${FORGE_TOKEN}}"
export FORGE_ARCHITECT_TOKEN="${FORGE_ARCHITECT_TOKEN:-${FORGE_TOKEN}}"

# Bot usernames filter
export FORGE_BOT_USERNAMES="${FORGE_BOT_USERNAMES:-dev-bot,review-bot,planner-bot,gardener-bot,vault-bot,supervisor-bot,predictor-bot,architect-bot}"

# Project config
export FORGE_REPO="${FORGE_REPO:-}"
export FORGE_URL="${FORGE_URL:-http://localhost:3000}"
export FORGE_API="${FORGE_API:-${FORGE_URL}/api/v1/repos/${FORGE_REPO}}"
export FORGE_WEB="${FORGE_WEB:-${FORGE_URL}/${FORGE_REPO}}"
# tea CLI login name: derived from FORGE_URL (codeberg vs local forgejo)
if [ -z "${TEA_LOGIN:-}" ]; then
  case "${FORGE_URL}" in
    *codeberg.org*) TEA_LOGIN="codeberg" ;;
    *)              TEA_LOGIN="forgejo" ;;
  esac
fi
export TEA_LOGIN

export PROJECT_NAME="${PROJECT_NAME:-${FORGE_REPO##*/}}"
export PROJECT_REPO_ROOT="${PROJECT_REPO_ROOT:-/home/${USER}/${PROJECT_NAME}}"
export PRIMARY_BRANCH="${PRIMARY_BRANCH:-master}"

# Ops repo: operational data (vault items, journals, evidence, prerequisites).
# Default convention: sibling directory named {project}-ops.
export OPS_REPO_ROOT="${OPS_REPO_ROOT:-/home/${USER}/${PROJECT_NAME}-ops}"

# Forge repo slug for the ops repo (used by agents that commit to ops).
export FORGE_OPS_REPO="${FORGE_OPS_REPO:-${FORGE_REPO:+${FORGE_REPO}-ops}}"
export WOODPECKER_REPO_ID="${WOODPECKER_REPO_ID:-}"
export WOODPECKER_SERVER="${WOODPECKER_SERVER:-http://localhost:8000}"
export CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-7200}"

# Vault-only token guard (#745): external-action tokens (GITHUB_TOKEN, CLAWHUB_TOKEN)
# must NEVER be available to agents. They live in .env.vault.enc and are injected
# only into the ephemeral runner container at fire time. Unset them here so
# even an accidental .env inclusion cannot leak them into agent sessions.
unset GITHUB_TOKEN 2>/dev/null || true
unset CLAWHUB_TOKEN 2>/dev/null || true

# Disable Claude Code auto-updater, telemetry, error reporting in factory sessions.
# Factory processes must never phone home or auto-update mid-session (#725).
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# Shared log helper
log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*"
}

# =============================================================================
# URL VALIDATION HELPER
# =============================================================================
# Validates that a URL variable matches expected patterns to prevent
# URL injection or redirection attacks (OWASP URL Redirection prevention).
# Returns 0 if valid, 1 if invalid.
# =============================================================================
validate_url() {
  local url="$1"
  local allowed_hosts="${2:-}"

  # Must start with http:// or https://
  if [[ ! "$url" =~ ^https?:// ]]; then
    return 1
  fi

  # Extract host and reject if it contains @ (credential injection)
  if [[ "$url" =~ ^https?://[^@]+@ ]]; then
    return 1
  fi

  # If allowed_hosts is specified, validate against it
  if [ -n "$allowed_hosts" ]; then
    local host
    host=$(echo "$url" | sed -E 's|^https?://([^/:]+).*|\1|')
    local valid=false
    for allowed in $allowed_hosts; do
      if [ "$host" = "$allowed" ]; then
        valid=true
        break
      fi
    done
    if [ "$valid" = false ]; then
      return 1
    fi
  fi

  return 0
}

# =============================================================================
# FORGE API HELPER
# =============================================================================
# Usage: forge_api GET /issues?state=open
# Validates FORGE_API before use to prevent URL injection attacks.
# =============================================================================
forge_api() {
  local method="$1" path="$2"
  shift 2

  # Validate FORGE_API to prevent URL injection
  if ! validate_url "$FORGE_API"; then
    echo "ERROR: FORGE_API validation failed - possible URL injection attempt" >&2
    return 1
  fi

  curl -sf -X "$method" \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}${path}" "$@"
}

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
    count=$(printf '%s' "$page_items" | jq 'length' 2>/dev/null) || count=0
    [ -z "$count" ] && count=0
    [ "$count" -eq 0 ] && break
    all_items=$(printf '%s\n%s' "$all_items" "$page_items" | jq -s 'add')
    [ "$count" -lt 50 ] && break
    page=$((page + 1))
  done
  printf '%s' "$all_items"
}

# =============================================================================
# WOODPECKER API HELPER
# =============================================================================
# Usage: woodpecker_api /repos/{id}/pipelines
# Validates WOODPECKER_SERVER before use to prevent URL injection attacks.
# =============================================================================
woodpecker_api() {
  local path="$1"
  shift

  # Validate WOODPECKER_SERVER to prevent URL injection
  if ! validate_url "$WOODPECKER_SERVER"; then
    echo "ERROR: WOODPECKER_SERVER validation failed - possible URL injection attempt" >&2
    return 1
  fi

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

# Memory guard — exit 0 (skip) if available RAM is below MIN_MB.
# Usage: memory_guard [MIN_MB]   (default 2000)
memory_guard() {
  local min_mb="${1:-2000}"
  local avail_mb
  avail_mb=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
  if [ "${avail_mb:-0}" -lt "$min_mb" ]; then
    log "SKIP: only ${avail_mb}MB available (need ${min_mb}MB)"
    exit 0
  fi
}

# Source tea helpers (available when tea binary is installed)
if command -v tea &>/dev/null; then
  # shellcheck source=tea-helpers.sh
  source "$(dirname "${BASH_SOURCE[0]}")/tea-helpers.sh"
fi
