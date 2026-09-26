#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1561.sh
#
# Issue #1561: feat(edge): stripe webhook is one path on the existing Caddy
#
# stripe-webhook.sh credits a fingerprint but nothing mounted it. A NEW HTTP
# server is the wrong mount. This change adds lib/caddy.sh::add_webhook_route
# (POSTs exactly one route whose match.uri is /stripe/webhook, reverse_proxied
# to 127.0.0.1:9088 — no host, no wildcard, no PUT /config/, idempotent, never
# touches any other route) and wires it into porter-caddy.sh at the end of a
# successful adopt/install.
#
# Contract under test (#1561):
#   * AC1 add_webhook_route POSTs exactly one path route for /stripe/webhook to
#     127.0.0.1:9088 (uri match, no host, no PUT/DELETE).
#   * AC2 a second add_webhook_route call returns 0 and does NOT POST again
#     (idempotent).
#   * AC3 the self.disinto.ai stub route stays present and is never PUT or
#     deleted across the calls.
#   * AC4 porter-caddy.sh (adopt mode) mounts the route on the existing Caddy
#     and is idempotent; the test exits 0 via ac_pass.
#
# Hermetic: no network, no real Caddy. curl is a stateful stub; PORTER_ROOT is
# a throwaway $TMP_DIR subdir. Real-host actions are skipped under PORTER_ROOT.
#
# Run via: tools/run-acceptance.sh 1561
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../lib/caddy-stub.sh
source "$REPO_ROOT/tests/lib/caddy-stub.sh"

ac_require_cmd bash jq grep cmp mktemp rm cat sed awk printf chmod cp head
ac_require_cmd mktemp

PORTER_CADDY="$REPO_ROOT/tools/edge-control/porter-caddy.sh"
ac_assert_file "$PORTER_CADDY" "tools/edge-control/porter-caddy.sh is missing"
CADDY_LIB="$REPO_ROOT/tools/edge-control/lib/caddy.sh"
ac_assert_file "$CADDY_LIB" "tools/edge-control/lib/caddy.sh is missing"

# Source-level sanity: porter-caddy.sh must source caddy.sh and invoke
# add_webhook_route after a successful adopt/install.
if ! grep -Eq 'source .*lib/caddy\.sh' "$PORTER_CADDY"; then
  ac_fail "porter-caddy.sh must source lib/caddy.sh"
fi
if ! grep -qF 'add_webhook_route' "$PORTER_CADDY"; then
  ac_fail "porter-caddy.sh must call add_webhook_route"
fi

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1561.XXXXXX)"
rc=0
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

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

# ── AC1: the helper POSTs exactly one /stripe/webhook path route ─────────────
ac_caddy_stub
ac_log "AC1: seeding the self.disinto.ai stub route into Caddy state"
printf '[{ "match":[{"host":["self.disinto.ai"]}],"handle":[{"handler":"reverse_proxy","upstreams":[{"dial":"127.0.0.1:20000"}]}] }]' > "$STATE"
run_webhook_route

if [ "$rc" -ne 0 ]; then
  ac_fail "AC1: add_webhook_route should exit 0 (rc=$rc, err=$err)"
fi
post_count=$(jq -cs 'length' <(jq -c 'select(.method == "POST")' "$LOG" 2>/dev/null) 2>/dev/null || echo 0)
if [ "$post_count" != "1" ]; then
  ac_fail "AC1: expected exactly one POST, got $post_count"
fi
if ! jq -e 'select(.method == "POST") | .body.match[0].uri == "/stripe/webhook"' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC1: POST does not match path /stripe/webhook"
fi
if ! jq -e 'select(.method == "POST") | .body.handle[0].handler == "reverse_proxy" and .body.handle[0].upstreams[0].dial == "127.0.0.1:9088"' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC1: POST upstream is not 127.0.0.1:9088"
fi
if jq -e 'select(.method == "POST") | any(.match[]; .host != null)' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC1: POST chose a host (must be path-only, no host)"
fi
if jq -e 'select(.method == "PUT")' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC1: a PUT occurred (must not PUT /config/)"
fi
if jq -e 'select(.method == "DELETE")' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC1: a DELETE occurred"
fi
if ! jq -e 'any(.[]; .match[0].host == ["self.disinto.ai"])' "$STATE" >/dev/null 2>&1; then
  ac_fail "AC1: self.disinto.ai stub route missing after add_webhook_route"
fi
ac_log "AC1: one path route /stripe/webhook -> 127.0.0.1:9088, no host, no PUT/DELETE, self stub intact"

# ── AC2: a second call is a no-op (no second POST) ──────────────────────────
run_webhook_route
if [ "$rc" -ne 0 ]; then
  ac_fail "AC2: second add_webhook_route should exit 0 (rc=$rc, err=$err)"
fi
post_count=$(jq -cs 'length' <(jq -c 'select(.method == "POST")' "$LOG" 2>/dev/null) 2>/dev/null || echo 0)
if [ "$post_count" != "1" ]; then
  ac_fail "AC2: expected still one POST, got $post_count (second call must not POST again)"
fi
ac_log "AC2: second call was a no-op (no second POST)"

# ── AC3: self stub route untouched (present; never PUT or deleted) ──────────
if ! jq -e 'any(.[]; .match[0].host == ["self.disinto.ai"])' "$STATE" >/dev/null 2>&1; then
  ac_fail "AC3: self.disinto.ai stub route missing (was PUT/deleted?)"
fi
if jq -e 'select(.method == "PUT")' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC3: a PUT occurred"
fi
if jq -e 'select(.method == "DELETE")' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC3: a DELETE occurred"
fi
ac_log "AC3: self.disinto.ai stub present; no PUT/DELETE"

# ── AC4: porter-caddy.sh (adopt) mounts the route and is idempotent ─────────
ac_caddy_stub
ROOT="$TMP_DIR/porter-root"
mkdir -p "$ROOT/etc/caddy/extra.d"
printf '{\n  admin localhost:2019\n}\n\nself.disinto.ai {\n  reverse_proxy 127.0.0.1:20000\n}\n' > "$ROOT/etc/caddy/Caddyfile"
printf '[{ "match":[{"host":["self.disinto.ai"]}],"handle":[{"handler":"reverse_proxy","upstreams":[{"dial":"127.0.0.1:20000"}]}] }]' > "$STATE"

ac_log "AC4: running porter-caddy.sh (adopt) with the curl stub on the existing Caddy"
pout="$TMP_DIR/porter-out.txt"
perr="$TMP_DIR/porter-err.txt"
rc=0
( PATH="$STUB_DIR:$PATH" PORTER_ROOT="$ROOT" bash "$PORTER_CADDY" ) >"$pout" 2>"$perr" || rc=$?
if [ "$rc" -ne 0 ]; then
  ac_fail "AC4: porter-caddy.sh adopt exited $rc (out: $(cat "$pout" 2>/dev/null); err: $(cat "$perr" 2>/dev/null))"
fi
post_count=$(jq -cs 'length' <(jq -c 'select(.method == "POST")' "$LOG" 2>/dev/null) 2>/dev/null || echo 0)
if [ "$post_count" != "1" ]; then
  ac_fail "AC4: porter-caddy.sh adopt expected exactly one webhook POST, got $post_count"
fi
if ! jq -e 'select(.method == "POST") | .body.match[0].uri == "/stripe/webhook" and .body.handle[0].upstreams[0].dial == "127.0.0.1:9088"' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC4: porter-caddy.sh webhook POST is not /stripe/webhook -> 127.0.0.1:9088"
fi
if jq -e 'select(.method == "PUT")' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC4: a PUT occurred"
fi
if jq -e 'select(.method == "DELETE")' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC4: a DELETE occurred"
fi
if ! jq -e 'any(.[]; .match[0].host == ["self.disinto.ai"])' "$STATE" >/dev/null 2>&1; then
  ac_fail "AC4: self.disinto.ai stub missing after adopt"
fi
if ! grep -qF 'self.disinto.ai' "$ROOT/etc/caddy/Caddyfile"; then
  ac_fail "AC4: self.disinto.ai site block missing from Caddyfile (sites must be preserved)"
fi

# Re-run adopt: add_webhook_route is idempotent -> no second POST.
rc=0
( PATH="$STUB_DIR:$PATH" PORTER_ROOT="$ROOT" bash "$PORTER_CADDY" ) >"$pout" 2>"$perr" || rc=$?
if [ "$rc" -ne 0 ]; then
  ac_fail "AC4: second porter-caddy.sh adopt should exit 0 (rc=$rc)"
fi
post_count=$(jq -cs 'length' <(jq -c 'select(.method == "POST")' "$LOG" 2>/dev/null) 2>/dev/null || echo 0)
if [ "$post_count" != "1" ]; then
  ac_fail "AC4: second adopt added another POST (got $post_count); add_webhook_route must be idempotent"
fi
ac_log "AC4: porter-caddy.sh adopt mounted /stripe/webhook on the existing Caddy; idempotent; sites preserved"

# ── AC5: all acceptance criteria passed ──────────────────────────────────────
ac_log "AC5: all checks passed"
ac_pass
