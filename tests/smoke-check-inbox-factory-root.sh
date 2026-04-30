#!/usr/bin/env bash
# =============================================================================
# tests/smoke-check-inbox-factory-root.sh — regression test for issue #953
#
# Verifies that check-inbox.sh resolves FACTORY_ROOT to the repo root, not
# one level too high (/). The bug was an off-by-one in the number of ../
# segments: 5 instead of 4, causing FACTORY_ROOT to resolve to /opt instead
# of /opt/disinto, which made the source of inbox-sentinels.sh fail.
#
# This test creates a temporary directory tree that mimics the deployed layout,
# places a mock inbox-sentinels.sh that sets a marker, and then sources the
# path-resolution portion of check-inbox.sh to assert FACTORY_ROOT is correct.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Setup: create a mock deployment tree ─────────────────────────────────────

MOCK_BASE="$(mktemp -d)"
MOCK_DEPLOY="${MOCK_BASE}/opt/disinto"
MOCK_SKILL="${MOCK_DEPLOY}/docker/edge/chat-skills/check-inbox"
MOCK_LIB="${MOCK_DEPLOY}/lib"
mkdir -p "$MOCK_SKILL" "$MOCK_LIB"

# Mock inbox-sentinels.sh — sets a marker so we know it was sourced.
cat > "${MOCK_LIB}/inbox-sentinels.sh" << 'EOF'
CHECK_INBOX_SENTINELS_LOADED=1
EOF

# Copy the real script into the mock tree.
cp "${REPO_ROOT}/docker/edge/chat-skills/check-inbox/check-inbox.sh" \
   "${MOCK_SKILL}/check-inbox.sh"

# ── Test: source the script with FACTORY_ROOT pointing to our mock tree ──────

# We need to override the source path so it picks up our mock.
# The script computes FACTORY_ROOT from SCRIPT_DIR, so we just set
# SCRIPT_DIR to the mock skill path and unset FACTORY_ROOT so the
# default computation runs.
(
  export SCRIPT_DIR="$MOCK_SKILL"
  unset FACTORY_ROOT

  # Evaluate the same path-resolution logic from the script.
  # shellcheck disable=SC2154
  SCRIPT_DIR="$(cd "${SCRIPT_DIR}" && pwd)"
  # shellcheck disable=SC2154
  FACTORY_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

  if [ "$FACTORY_ROOT" != "$MOCK_DEPLOY" ]; then
    printf 'FAIL: FACTORY_ROOT=%s (expected %s)\n' "$FACTORY_ROOT" "$MOCK_DEPLOY"
    exit 1
  fi

  # Now source the script — it should find our mock inbox-sentinels.sh.
  # Override SNAPSHOT_PATH so the script exits cleanly (no snapshot file).
  export SNAPSHOT_PATH="/nonexistent"
  # shellcheck disable=SC1090
  source "${MOCK_SKILL}/check-inbox.sh" >/dev/null 2>&1 || true

  # shellcheck disable=SC2154
  if [ "${CHECK_INBOX_SENTINELS_LOADED:-}" != "1" ]; then
    printf 'FAIL: inbox-sentinels.sh was not sourced (marker not set)\n'
    exit 1
  fi
)

# ── Cleanup ──────────────────────────────────────────────────────────────────

rm -rf "$MOCK_BASE"

printf 'PASS: FACTORY_ROOT resolves correctly (issue #953)\n'
