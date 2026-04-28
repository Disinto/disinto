#!/usr/bin/env bash
# =============================================================================
# env.sh — Load environment and shared utilities
# Source this at the top of every script: source "$(dirname "$0")/lib/env.sh"
#
# SURFACE CONTRACT
#
# Required preconditions — the entrypoint (or caller) MUST set these before
# sourcing this file:
#   USER              — OS user name (e.g. "agent", "johba")
#   HOME              — home directory (e.g. "/home/agent")
#
# Required when PROJECT_TOML is set (i.e. agent scripts loading a project):
#   PROJECT_REPO_ROOT — absolute path to the project git clone
#   PRIMARY_BRANCH    — default branch name (e.g. "main")
#   OPS_REPO_ROOT     — absolute path to the ops repo clone
#   (these are normally populated by load-project.sh from the TOML)
#
# What this file sets / exports:
#   FACTORY_ROOT, DISINTO_LOG_DIR
#   .env / .env.enc secrets (FORGE_TOKEN, etc.) — eager-loaded via lib/secrets.sh
#   FORGE_API, FORGE_WEB, TEA_LOGIN, FORGE_OPS_REPO (derived from FORGE_URL/FORGE_REPO)
#   Per-agent tokens (FORGE_REVIEW_TOKEN, FORGE_GARDENER_TOKEN, …)
#   CLAUDE_SHARED_DIR, CLAUDE_CONFIG_DIR
#   Helper functions: log(), validate_url(), forge_api(), forge_api_all(),
#     forge_whoami(), woodpecker_api(), wpdb(), memory_guard()
#   From lib/secrets.sh (sourced): load_dotenv(), load_dotenv_enc(), load_secret()
# =============================================================================

set -euo pipefail

# Resolve script root (parent of lib/)
FACTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Precondition assertions ──────────────────────────────────────────────────
# These must be set by the entrypoint before sourcing this file.
: "${USER:?must be set by entrypoint before sourcing lib/env.sh}"
: "${HOME:?must be set by entrypoint before sourcing lib/env.sh}"

# Container detection: when running inside the agent container, DISINTO_CONTAINER
# is set by docker-compose.yml.  Adjust paths so phase files, logs, and thread
# maps land on the persistent volume instead of /tmp (which is ephemeral).
if [ "${DISINTO_CONTAINER:-}" = "1" ]; then
  DISINTO_DATA_DIR="${HOME}/data"
  DISINTO_LOG_DIR="${DISINTO_DATA_DIR}/logs"
  # Tighten log perms (#910): JSONL transcripts captured by formula
  # sub-sessions may include tool_result stdout that echoes loaded env
  # (FORGE_*_TOKEN, etc.). With the default umask 022 those land on the
  # host volume as 644 — readable by every agent container that mounts
  # agent-data RO. Restrict to 700/600 = agent-only.
  umask 077
  mkdir -p "${DISINTO_DATA_DIR}" "${DISINTO_LOG_DIR}"/{dev,action,review,supervisor,vault,site,metrics,gardener,planner,predictor,architect,dispatcher}
  # Self-heal stale 644 perms from prior container runs (and any siblings
  # the loop above missed). Filesystem-level cap so existing transcripts
  # are no longer world-readable on a fresh container start.
  chmod 700 "${DISINTO_LOG_DIR}" 2>/dev/null || true
  find "${DISINTO_LOG_DIR}" -mindepth 1 -type d -exec chmod 700 {} + 2>/dev/null || true
  find "${DISINTO_LOG_DIR}" -type f -exec chmod 600 {} + 2>/dev/null || true
else
  DISINTO_LOG_DIR="${FACTORY_ROOT}"
fi
export DISINTO_LOG_DIR

# Secret resolution (load_dotenv, load_dotenv_enc, load_secret) lives in
# lib/secrets.sh. Sourced unconditionally so load_secret is available to every
# caller regardless of container detection. Eager .env / .env.enc loading
# below is preserved for back-compat; callers that only need load_secret (or
# log/memory_guard from this file) pay nothing extra today and, once migrated
# to source secrets.sh directly, will skip the eager-load cost entirely.
# shellcheck source=secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"

# Load secrets: prefer .env.enc (SOPS-encrypted), fall back to plaintext .env.
# Inside containers (DISINTO_CONTAINER=1), compose environment is the source of truth.
# On bare metal, .env/.env.enc is sourced to provide default values.
if [ "${DISINTO_CONTAINER:-}" != "1" ]; then
  if [ -f "$FACTORY_ROOT/.env.enc" ] && command -v sops &>/dev/null; then
    load_dotenv_enc
  elif [ -f "$FACTORY_ROOT/.env" ]; then
    load_dotenv
  fi
fi

# Allow per-container token override (#375): .env sets the default FORGE_TOKEN
# (dev-bot), then FORGE_TOKEN_OVERRIDE replaces it for containers that need a
# different Forgejo identity (e.g. dev-qwen).
if [ -n "${FORGE_TOKEN_OVERRIDE:-}" ]; then
  export FORGE_TOKEN="$FORGE_TOKEN_OVERRIDE"
fi

# PATH: foundry, node, system
export PATH="${HOME}/.local/bin:${HOME}/.foundry/bin:${HOME}/.nvm/versions/node/v22.20.0/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

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
export FORGE_FILER_TOKEN="${FORGE_FILER_TOKEN:-${FORGE_TOKEN}}"

# Bot usernames filter
export FORGE_BOT_USERNAMES="${FORGE_BOT_USERNAMES:-dev-bot,review-bot,planner-bot,gardener-bot,vault-bot,supervisor-bot,predictor-bot,architect-bot,filer-bot}"

# Project config
export FORGE_REPO="${FORGE_REPO:-}"
export FORGE_URL="${FORGE_URL:-http://localhost:3000}"
export FORGE_API_BASE="${FORGE_API_BASE:-${FORGE_URL}/api/v1}"
export FORGE_API="${FORGE_API:-${FORGE_API_BASE}/repos/${FORGE_REPO}}"
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

# Project-specific paths: no guessing from USER/HOME — must be set by
# the entrypoint or loaded from PROJECT_TOML (via load-project.sh above).
if [ -n "${PROJECT_TOML:-}" ]; then
  : "${PROJECT_REPO_ROOT:?must be set by entrypoint or PROJECT_TOML before sourcing lib/env.sh}"
  : "${PRIMARY_BRANCH:?must be set by entrypoint or PROJECT_TOML before sourcing lib/env.sh}"
  : "${OPS_REPO_ROOT:?must be set by entrypoint or PROJECT_TOML before sourcing lib/env.sh}"
fi

# Forge repo slug for the ops repo (used by agents that commit to ops).
export FORGE_OPS_REPO="${FORGE_OPS_REPO:-${FORGE_REPO:+${FORGE_REPO}-ops}}"
export WOODPECKER_REPO_ID="${WOODPECKER_REPO_ID:-}"
export WOODPECKER_SERVER="${WOODPECKER_SERVER:-http://localhost:8000}"
export CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-7200}"

# Vault-only token guard (#745): external-action tokens (GITHUB_TOKEN, CLAWHUB_TOKEN)
# must NEVER be available to agents. They live in secrets/*.enc and are decrypted
# only into the ephemeral runner container at fire time (#777). Unset them here so
# even an accidental .env inclusion cannot leak them into agent sessions.
unset GITHUB_TOKEN 2>/dev/null || true
unset CLAWHUB_TOKEN 2>/dev/null || true

# Shared Claude config directory for cross-container OAuth lock coherence (#641).
# All containers and the host resolve to the same CLAUDE_CONFIG_DIR on a shared
# bind-mounted filesystem, so proper-lockfile's atomic mkdir works across them.
: "${CLAUDE_SHARED_DIR:=/var/lib/disinto/claude-shared}"
: "${CLAUDE_CONFIG_DIR:=${CLAUDE_SHARED_DIR}/config}"
export CLAUDE_SHARED_DIR CLAUDE_CONFIG_DIR

# Disable Claude Code auto-updater, telemetry, error reporting in factory sessions.
# Factory processes must never phone home or auto-update mid-session (#725).
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# Shared log helper
# Usage: log "message"
# Output: [2026-04-03T14:00:00Z] agent: message
# Where agent is set via LOG_AGENT variable (defaults to caller's context)
log() {
  local agent="${LOG_AGENT:-agent}"
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$agent" "$*"
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
# FORGE WHOAMI HELPER
# =============================================================================
# forge_whoami() lives in lib/forge-helpers.sh so it can be sourced from
# bootstrap contexts that don't load full env.sh (lib/git-creds.sh callers,
# docker/edge/entrypoint-edge.sh). #694
# =============================================================================
# shellcheck source=forge-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/forge-helpers.sh"

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
    -H "Authorization: Bearer ${WOODPECKER_TOKEN:-}" \
    "${WOODPECKER_SERVER:-}/api${path}" "$@"
}

# Woodpecker DB query helper
wpdb() {
  PGPASSWORD="${WOODPECKER_DB_PASSWORD:-}" psql \
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

# load_secret (secret resolution) is defined in lib/secrets.sh, sourced above.

# Source tea helpers (available when tea binary is installed)
if command -v tea &>/dev/null; then
  # shellcheck source=tea-helpers.sh
  source "$(dirname "${BASH_SOURCE[0]}")/tea-helpers.sh"
fi
