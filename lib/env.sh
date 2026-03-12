#!/usr/bin/env bash
# env.sh — Load environment and shared utilities
# Source this at the top of every script: source "$(dirname "$0")/lib/env.sh"

set -euo pipefail

# Resolve script root (parent of lib/)
FACTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load .env if present
if [ -f "$FACTORY_ROOT/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$FACTORY_ROOT/.env"
  set +a
fi

# PATH: foundry, node, system
export PATH="${HOME}/.foundry/bin:${HOME}/.nvm/versions/node/v22.20.0/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export HOME="${HOME:-/home/debian}"

# Codeberg token: env var > ~/.netrc
if [ -z "${CODEBERG_TOKEN:-}" ]; then
  CODEBERG_TOKEN="$(awk '/codeberg.org/{getline;getline;print $2}' ~/.netrc 2>/dev/null || true)"
fi
export CODEBERG_TOKEN

# Defaults
export CODEBERG_REPO="${CODEBERG_REPO:-johba/harb}"
export CODEBERG_API="${CODEBERG_API:-https://codeberg.org/api/v1/repos/${CODEBERG_REPO}}"
export HARB_REPO_ROOT="${HARB_REPO_ROOT:-/home/debian/harb}"
export WOODPECKER_SERVER="${WOODPECKER_SERVER:-http://localhost:8000}"
export CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-7200}"

# Shared log helper
log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*"
}

# Codeberg API helper — usage: codeberg_api GET /issues?state=open
codeberg_api() {
  local method="$1" path="$2"
  shift 2
  curl -sf -X "$method" \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${CODEBERG_API}${path}" "$@"
}

# Woodpecker API helper
woodpecker_api() {
  local path="$1"
  shift
  curl -sf \
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
