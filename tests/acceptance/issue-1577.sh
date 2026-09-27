#!/usr/bin/env bash
# shellcheck disable=SC2034  # TMP_DIR is consumed by tests/lib/webhook-route-helpers.sh
# shellcheck disable=SC2154  # err is set by run_webhook_route (tests/lib/webhook-route-helpers.sh)
# =============================================================================
# tests/acceptance/issue-1577.sh
#
# Issue #1577: fix(edge): webhook route uses the path matcher
#
# add_webhook_route POSTed a matcher named `uri`. Caddy 2.11 has no
# http.matchers.uri (admin API rejected it: 500 "loading matcher modules:
# module name 'uri'"), so the /stripe/webhook route was never added. The
# module that exists is http.matchers.path. The fix:
#   * add_webhook_route POSTs `match[].path` == /stripe/webhook (not `uri`);
#   * its idempotency check looks for that same `path`;
#   * still exactly one POST, never PUT /config/; a host-only route
#     (e.g. self.disinto.ai / *.disinto.ai) is not a match and is left in
#     place.
#
# Contract under test (#1577):
#   * AC1 the posted JSON has match[].path == /stripe/webhook and no `uri`
#         key; it proxies to 127.0.0.1:9088; it is a path-only route with no
#         host, no PUT and no DELETE.
#   * AC2 a stub route whose match is only a host is still present after the
#         call.
#   * AC3 a second add_webhook_route call does not POST again when that path
#         route already exists (idempotent).
#   * AC4 bash tests/acceptance/issue-1577.sh exits 0 and calls ac_pass.
#
# Hermetic: no network, no live Caddy. curl is the stateful Caddy admin stub
# (tests/lib/caddy-stub.sh) which records every request as JSONL {method,url,
# path,body}.
#
# Run via: tools/run-acceptance.sh 1577
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../lib/caddy-stub.sh
source "$REPO_ROOT/tests/lib/caddy-stub.sh"

ac_require_cmd bash jq grep mktemp rm cat sed awk printf chmod

PORTER_CADDY="$REPO_ROOT/tools/edge-control/porter-caddy.sh"
ac_assert_file "$PORTER_CADDY" "tools/edge-control/porter-caddy.sh is missing"
CADDY_LIB="$REPO_ROOT/tools/edge-control/lib/caddy.sh"
ac_assert_file "$CADDY_LIB" "tools/edge-control/lib/caddy.sh is missing"

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1577.XXXXXX)"
rc=0
# shellcheck source=../lib/webhook-route-helpers.sh
source "$REPO_ROOT/tests/lib/webhook-route-helpers.sh"
trap cleanup EXIT

# Count POST requests in the stub log.
count_posts() {
  jq -s '[.[] | select(.method == "POST")] | length' "$LOG" 2>/dev/null || echo 0
}

# ── AC1: posted JSON uses match[].path == /stripe/webhook, no `uri` key ──────
ac_caddy_stub
ac_log "AC1: seeding the self.disinto.ai (host-only) stub route into Caddy state"
printf '[{"match":[{"host":["self.disinto.ai"]}],"handle":[{"handler":"reverse_proxy","upstreams":[{"dial":"127.0.0.1:20000"}]}]}]' > "$STATE"
run_webhook_route

if [ "$rc" -ne 0 ]; then
  ac_fail "AC1: add_webhook_route should exit 0 (rc=$rc, err=$err)"
fi

# Exactly one POST, to the routes endpoint (append), never a PUT/DELETE.
post_count=$(count_posts)
if [ "$post_count" != "1" ]; then
  ac_fail "AC1: expected exactly one POST to the routes endpoint, got $post_count"
fi
if ! jq -e 'select(.method == "POST") | .url | contains("/routes")' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC1: POST was not to a /routes endpoint"
fi
if jq -e 'select(.method == "PUT")' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC1: a PUT occurred (must never PUT /config/)"
fi
if jq -e 'select(.method == "DELETE")' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC1: a DELETE occurred (must never delete a route)"
fi

# The single POST body: match[].path == /stripe/webhook, proxied to 9088,
# path-only (no host key in the match).
if ! jq -e '
    select(.method == "POST")
    | .body
    | .match[0].path == "/stripe/webhook"' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC1: POSTed route does not match path /stripe/webhook (match[].path)"
fi
if ! jq -e '
    select(.method == "POST")
    | .body
    | .handle[0].handler == "reverse_proxy"
    and .handle[0].upstreams[0].dial == "127.0.0.1:9088"' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC1: POSTed route is not a reverse_proxy to 127.0.0.1:9088"
fi
if jq -e '
    select(.method == "POST")
    | .body.match[]? | select(.host != null)' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC1: POSTed route contains a host key (must be path-only, no host)"
fi
# The bug this issue fixes: the `uri` matcher key. It must not appear anywhere
# in the posted route body (Caddy 2.11 has no http.matchers.uri).
uri_hits=$(jq -rs '
    [.[] | select(.method == "POST") | .body | [..]
      | select(type == "object" and has("uri"))] | length' "$LOG" 2>/dev/null || echo 0)
if [ "$uri_hits" -ne 0 ]; then
  ac_fail "AC1: POSTed route body contains a \`uri\` key (Caddy 2.11 has no http.matchers.uri)"
fi
ac_log "AC1: one path-only route /stripe/webhook -> 127.0.0.1:9088, no uri/host/PUT/DELETE"

# ── AC2: a host-only stub route is still present after the call ──────────────
if ! jq -e 'any(.[]; .match[0].host == ["self.disinto.ai"])' "$STATE" >/dev/null 2>&1; then
  ac_fail "AC2: self.disinto.ai host-only stub route is missing after add_webhook_route"
fi
# The path route must also have been appended (state has 2 routes total).
# $STATE is a single JSON array (not JSONL), so no -s slurp.
total_routes=$(jq 'length' "$STATE" 2>/dev/null || echo 0)
if [ "$total_routes" != "2" ]; then
  ac_fail "AC2: expected 2 routes (stub + path), got $total_routes"
fi
ac_log "AC2: host-only stub route survived; path route appended (2 routes total)"

# ── AC3: a second call is a no-op (no second POST) ──────────────────────────
ac_log "AC3: re-running add_webhook_route (must be idempotent, no second POST)"
run_webhook_route
if [ "$rc" -ne 0 ]; then
  ac_fail "AC3: second add_webhook_route should exit 0 (rc=$rc, err=$err)"
fi
post_count=$(count_posts)
if [ "$post_count" != "1" ]; then
  ac_fail "AC3: expected still exactly one POST after the second call (got $post_count)"
fi
recount=$(jq 'length' "$STATE" 2>/dev/null || echo 0)
if [ "$recount" != "2" ]; then
  ac_fail "AC3: route count changed on the no-op second call (expected 2, got $recount)"
fi
ac_log "AC3: second call was a no-op (no second POST, state unchanged)"

# ── AC4: all acceptance criteria passed ───────────────────────────────────────
ac_log "AC4: all checks passed"
ac_pass
