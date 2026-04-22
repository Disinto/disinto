#!/usr/bin/env bash
# supervisor/actions/_common.sh — Shared setup for all action scripts
#
# Sources this file at the top of each action script to get:
#   - Standard header (set -euo pipefail, SCRIPT_DIR, FACTORY_ROOT)
#   - Project config (PROJECT_TOML, FORGE_TOKEN_OVERRIDE)
#   - Environment (lib/env.sh)
#   - Logging helper (log() → supervisor.log)
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/_common.sh"
#
# Action scripts may override LOG_FILE and log() after sourcing.

# Accept project config from argument; default to disinto
export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
export FORGE_TOKEN_OVERRIDE="${FORGE_SUPERVISOR_TOKEN:-}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"

# Override log() to append to supervisor-specific log file
log() {
  local agent="${LOG_AGENT:-supervisor}"
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$agent" "$*" >> "$LOG_FILE"
}
