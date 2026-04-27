#!/usr/bin/env bash
# =============================================================================
# forge-helpers.sh — Lightweight Forgejo helper functions
#
# Self-contained module that defines forge_whoami(). Extracted from env.sh
# (#694) so it can be sourced from contexts that haven't yet loaded the full
# env.sh surface — notably:
#   - lib/git-creds.sh (called from runner entrypoints that don't source env.sh)
#   - docker/edge/entrypoint-edge.sh (runs before /opt/disinto is cloned;
#     the edge image bakes a copy of this file into /usr/local/bin/)
#
# This file MUST stay free of preconditions other than FORGE_TOKEN / FORGE_URL
# (or FORGE_API_BASE) so it remains safe to source during bootstrap.
#
# Usage:
#   source "${FACTORY_ROOT}/lib/forge-helpers.sh"
#   login=$(forge_whoami)
# =============================================================================

# forge_whoami — resolve the current FORGE_TOKEN's login name.
# Echoes the login to stdout, empty string on failure.
# Requires: FORGE_TOKEN, FORGE_URL (or FORGE_API_BASE).
forge_whoami() {
  local base="${FORGE_API_BASE:-${FORGE_URL}/api/v1}"
  curl -sf --max-time 10 \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${base}/user" 2>/dev/null | jq -r '.login // empty' 2>/dev/null || true
}
