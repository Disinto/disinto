#!/usr/bin/env bash
# supervisor/actions/cleanup-phase-files.sh — P4 stale phase file cleanup
#
# Auto-removes PHASE:escalate files whose parent issue/PR is confirmed closed.
# Grace period: 24h after issue closure to avoid race conditions.
#
# Sources preflight.sh to reuse __preflight_cleanup_stale_phases().

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared setup (header, env, log function)
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh" "$@"

# shellcheck disable=SC2034
LOG_FILE="${DISINTO_LOG_DIR}/supervisor/supervisor.log"
# shellcheck disable=SC2034
LOG_AGENT="supervisor"

# Source preflight.sh to get __preflight_cleanup_stale_phases() and forge_api
# shellcheck source=../preflight.sh
source "$FACTORY_ROOT/supervisor/preflight.sh"

# Run cleanup in log mode (uses log() instead of echo)
__preflight_cleanup_stale_phases log
