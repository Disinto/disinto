#!/usr/bin/env bash
# shellcheck disable=SC2034  # rc/err are consumed by the calling acceptance test
# =============================================================================
# tests/lib/webhook-route-helpers.sh — shared helpers for acceptance tests that
# mount the Stripe webhook route (tools/edge-control/lib/caddy.sh::
# add_webhook_route) against a stubbed Caddy.
#
# Sourced by the acceptance tests that exercise the edge webhook route against
# the fake Caddy admin listener from tests/lib/caddy-stub.sh (currently
# tests/acceptance/issue-1561.sh and tests/acceptance/issue-1577.sh).
#
# Requires the calling script to define these globals before sourcing:
#   * TMP_DIR   — per-test temp dir used to capture the route call's stdout/stderr
#   * CADDY_LIB — path to the caddy.sh that owns add_webhook_route
#
# STUB_DIR is provided by tests/lib/caddy-stub.sh::ac_caddy_stub at call time
# (inside run_webhook_route), not at source time.
#
# Provides:
#   * cleanup()          — removes TMP_DIR. The caller must `trap cleanup EXIT`.
#   * run_webhook_route() — sources $CADDY_LIB and calls add_webhook_route in a
#     subshell against the stubbed Caddy. On return, the calling script's
#     globals rc (exit status) and err (captured stderr) are set.
# =============================================================================

# Idempotent guard — sourcing twice (nested test) must not redefine functions.
if [ -n "${WEBHOOK_ROUTE_HELPERS_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # exit 0 is the fallback if return is ineffective
  return 0 2>/dev/null || exit 0
fi
WEBHOOK_ROUTE_HELPERS_LOADED=1

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

# Run add_webhook_route against the stubbed Caddy. On return, globals rc and
# err are set (rc = function's exit status, err = captured stderr).
run_webhook_route() {
  local out_file err_file
  out_file="$TMP_DIR/route_out.txt"
  err_file="$TMP_DIR/route_err.txt"
  rc=0
  err=""
  {
    export PATH="$STUB_DIR:$PATH"
    export CADDY_ADMIN_URL="http://127.0.0.1:2019"
    export DOMAIN_SUFFIX="disinto.ai"
    # shellcheck source=lib/caddy.sh
    source "$CADDY_LIB"
    add_webhook_route
  } >"$out_file" 2>"$err_file" || rc=$?
  err="$(cat "$err_file" 2>/dev/null || true)"
}
