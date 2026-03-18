#!/usr/bin/env bash
# ci-helpers.sh — Shared CI helper functions
#
# Source from any script: source "$(dirname "$0")/../lib/ci-helpers.sh"
# Requires: WOODPECKER_REPO_ID (from env.sh / project config)

# ci_passed <state> — check if CI is passing (or no CI configured)
#   Returns 0 if state is "success", or if no CI is configured and
#   state is empty/pending/unknown.
ci_passed() {
  local state="$1"
  if [ "$state" = "success" ]; then return 0; fi
  if [ "${WOODPECKER_REPO_ID:-2}" = "0" ] && { [ -z "$state" ] || [ "$state" = "pending" ] || [ "$state" = "unknown" ]; }; then
    return 0  # no CI configured
  fi
  return 1
}
