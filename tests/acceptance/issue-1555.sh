#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1555.sh
#
# Issue #1555: feat(edge): adopt an existing Caddy or install one without
# replacing sites
#
# The Porter door had no Caddy step, and the only installer (install.sh)
# overwrites /etc/caddy/Caddyfile, requires a Gandi token, and installs a
# different tree. This change adds tools/edge-control/porter-caddy.sh (a
# root script, not a verb) that:
#   * ADOPTS an existing Caddy (prefix/etc/caddy/Caddyfile or
#     prefix/usr/bin/caddy): the ONLY edit allowed is inserting
#     `admin localhost:2019` into the global options block when that exact
#     admin listener is not yet configured. Site blocks stay byte-for-byte.
#     No `extra.d` files or server config are ever deleted or rewritten.
#   * INSTALLS a fresh Caddy (no Caddyfile, no binary): writes a NEW Caddyfile
#     whose whole content is the global block (`admin localhost:2019`) plus
#     `import <prefix>/etc/caddy/extra.d/*.caddy`, and creates `extra.d` if
#     missing. No site for `self`, `www`, apex, or any customer name; no
#     catch-all :80/:443 site (Porter never listens on 80/443).
# And re-specifies lib/caddy.sh route helpers:
#   * add_route POSTs exactly one route whose match.host is exactly
#     [<project>.<DOMAIN_SUFFIX>; never PUT /config/, never replaces a server,
#     no wildcard proxy site.
#   * remove_route DELETEs only the route index whose host list is exactly that
#     name; returns 0 if absent; every other route in the list is untouched.
#
# Contract under test (#1555):
#   * AC1 adopt: a Caddyfile containing `self.disinto.ai` keeps that site
#     block byte-for-byte and writes no customer site;
#   * AC2 install: a fresh install writes a Caddyfile with
#     `admin localhost:2019` and `import extra.d`, no `self`/apex site;
#   * AC3 add_route records a POST with one exact host; remove_route removes
#     only that host, leaving `self.disinto.ai` in the stub;
#   * AC4 the test exits 0 and calls ac_pass.
#
# Hermetic: no network, no real Caddy. curl is a stateful stub; PORTER_ROOT is
# a throwaway $TMP_DIR subdir. Real-host actions (package install, systemctl,
# `caddy` processes) are skipped under PORTER_ROOT.
#
# Run via: tools/run-acceptance.sh 1555
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep cmp mktemp rm cat sed awk printf chmod cp head
ac_require_cmd mktemp

PORTER_CADDY="$REPO_ROOT/tools/edge-control/porter-caddy.sh"
ac_assert_file "$PORTER_CADDY" "tools/edge-control/porter-caddy.sh is missing"
CADDY_LIB="$REPO_ROOT/tools/edge-control/lib/caddy.sh"
ac_assert_file "$CADDY_LIB" "tools/edge-control/lib/caddy.sh is missing"

# Source-level sanity: porter-caddy.sh must not *invoke* install.sh
# (comment lines mentioning it are fine).
if grep -vE '^[[:space:]]*#' "$PORTER_CADDY" 2>/dev/null \
    | grep -EqE '(^|[^./])install\.sh\b'; then
  ac_fail "porter-caddy.sh must not call install.sh"
fi

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1555.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Extract the "site region": every line from the first `host {` line to EOF.
# The global block opening line is just `{` (no host before the brace), so it
# is never matched. Used to assert site blocks are left byte-for-byte.
site_region() {
  awk '/^[[:space:]]*[^{}]+[[:space:]]*\{/{flag=1} flag{print}' "$1"
}

# Run a route command (add_route / remove_route) against the stubbed Caddy.
# $@ = the function name and its args. On return, globals rc (exit code) and
# err (captured stderr) are set. stdout is discarded (route helpers only log
# to stderr).
run_route() {
  local out_file err_file
  out_file="$TMP_DIR/route_out.txt"
  err_file="$TMP_DIR/route_err.txt"
  rc=0
  err=""
  {
    export PATH="$STUB_DIR:$PATH"
    export CADDY_ADMIN_URL="http://127.0.0.1:2019"
    export DOMAIN_SUFFIX="disinto.ai"
    source "$CADDY_LIB"
    "$@"
  } >"$out_file" 2>"$err_file" || rc=$?
  err="$(cat "$err_file" 2>/dev/null || true)"
}

# ── AC1. adopt leaves the `self` site block byte-for-byte, writes no
#     customer site; `extra.d` untouched ──────────────────────────────────────
ac_log "AC1: adopt mode preserves existing site blocks"

ROOT1="$TMP_DIR/root1"
mkdir -p "$ROOT1/etc/caddy/extra.d"
printf 'static-operator-site\n' > "$ROOT1/etc/caddy/extra.d/static.caddy"
# Global block already carries the admin listener; adopt must change nothing.
cat > "$ROOT1/etc/caddy/Caddyfile" <<'CADDYFILE'
{
  admin localhost:2019
}

self.disinto.ai {
  reverse_proxy 127.0.0.1:20000
}
CADDYFILE
snap="$ROOT1/Caddyfile.snap"
cp "$ROOT1/etc/caddy/Caddyfile" "$snap"
cp "$ROOT1/etc/caddy/extra.d/static.caddy" "$ROOT1/static.snap"

( PORTER_ROOT="$ROOT1" bash "$PORTER_CADDY" 2>&1 ) >"$ROOT1/adopts.out" 2>"$ROOT1/adopts.err"
rc=$?
if [ "$rc" -ne 0 ]; then
  ac_fail "AC1a: adopt on an admin-equipped Caddyfile should exit 0 (rc=$rc)"
fi
if ! cmp -s "$ROOT1/etc/caddy/Caddyfile" "$snap"; then
  ac_fail "AC1a: adopt changed the Caddyfile when the admin listener was already configured"
fi
if ! cmp -s "$ROOT1/etc/caddy/extra.d/static.caddy" "$ROOT1/static.snap"; then
  ac_fail "AC1a: adopt altered the extra.d file"
fi
ac_log "AC1a: admin-equipped Caddyfile left byte-for-byte; no customer site written"

# No-admin global block: adopt must insert the admin line and still leave every
# site block byte-for-byte.
ROOT2="$TMP_DIR/root2"
mkdir -p "$ROOT2/etc/caddy/extra.d"
printf 'operator-site\n' > "$ROOT2/etc/caddy/extra.d/operator.caddy"
cat > "$ROOT2/etc/caddy/Caddyfile" <<'CADDYFILE'
{
}

self.disinto.ai {
  reverse_proxy 127.0.0.1:20000
}
CADDYFILE
site_before="$(site_region "$ROOT2/etc/caddy/Caddyfile")"
( PORTER_ROOT="$ROOT2" bash "$PORTER_CADDY" 2>&1 ) >"$ROOT2/adopts.out" 2>"$ROOT2/adopts.err"
rc=$?
if [ "$rc" -ne 0 ]; then
  ac_fail "AC1b: adopt inserting the admin line should exit 0 (rc=$rc)"
fi
if ! grep -qE 'admin[[:space:]]+localhost:2019' "$ROOT2/etc/caddy/Caddyfile"; then
  ac_fail "AC1b: admin listener not inserted into global block"
fi
site_after="$(site_region "$ROOT2/etc/caddy/Caddyfile")"
if [ "$site_before" != "$site_after" ]; then
  ac_fail "AC1b: site block not byte-for-byte (before: '$site_before', after: '$site_after')"
fi
if ! grep -qE 'admin[[:space:]]+localhost:2019' "$ROOT2/etc/caddy/Caddyfile"; then
  ac_fail "AC1b: admin line missing after adopt"
fi
if ! cmp -s "$ROOT2/etc/caddy/extra.d/operator.caddy" \
    <(printf 'operator-site\n'); then
  ac_fail "AC1b: extra.d file altered"
fi
# Only the original host remains a site; nothing new (customer) was written.
site_hosts=$(site_region "$ROOT2/etc/caddy/Caddyfile" | grep -oE '^[[:space:]]*[A-Za-z0-9.-]*[[:space:]]*\{' | awk '{print $1}')
if [ "$site_hosts" != "self.disinto.ai" ]; then
  ac_fail "AC1b: unexpected site hosts present: $site_hosts"
fi
ac_log "AC1b: admin inserted, self block byte-for-byte, no customer site written"

# ── AC2. fresh install writes only admin + import; no self/apex/catch-all ───
ac_log "AC2: fresh install writes a minimal Caddyfile"

ROOT3="$TMP_DIR/root3"
# Empty prefix: neither Caddyfile nor caddy binary exists.
mkdir -p "$ROOT3"
( PORTER_ROOT="$ROOT3" bash "$PORTER_CADDY" 2>&1 ) >"$ROOT3/installs.out" 2>"$ROOT3/installs.err"
rc=$?
if [ "$rc" -ne 0 ]; then
  ac_fail "AC2: fresh install should exit 0 (rc=$rc)"
fi
CADDY3="$ROOT3/etc/caddy/Caddyfile"
ac_assert_file "$CADDY3" "installed Caddyfile missing"
if ! grep -qE 'admin[[:space:]]+localhost:2019' "$CADDY3"; then
  ac_fail "AC2: Caddyfile lacks 'admin localhost:2019'"
fi
if ! grep -qE 'import[[:space:]]+.*extra\.d/\*\.caddy' "$CADDY3"; then
  ac_fail "AC2: Caddyfile lacks the extra.d import"
fi
if ! [ -d "$ROOT3/etc/caddy/extra.d" ]; then
  ac_fail "AC2: extra.d directory not created"
fi
# No site block of any name (self, www, apex, customer, catch-all).
installed_sites="$(site_region "$CADDY3")"
if [ -n "$installed_sites" ]; then
  ac_fail "AC2: install wrote a site block: $installed_sites"
fi
if grep -qE '^[[:space:]]*:80' "$CADDY3" || grep -qE '^[[:space:]]*:443' "$CADDY3"; then
  ac_fail "AC2: catch-all :80/:443 site written"
fi
if grep -qE '^[[:space:]]*(self|www)\.' "$CADDY3"; then
  ac_fail "AC2: self or www site written"
fi
# TEST_MODE must skip real-host artifacts.
if [ -f "$ROOT3/usr/bin/caddy" ]; then
  ac_fail "AC2: TEST_MODE installed a caddy binary"
fi
if [ -f "$ROOT3/etc/systemd/system/caddy.service" ]; then
  ac_fail "AC2: TEST_MODE wrote a systemd unit"
fi
ac_log "AC2: fresh install wrote admin + import only, no sites, no real-host artifacts"

# ── AC3. caddy.sh route helpers against a stateful curl stub ─────────────────
ac_log "AC3: add_route / remove_route route behavior"

STUB_DIR="$TMP_DIR/stub"
mkdir -p "$STUB_DIR"
STATE="$TMP_DIR/caddy-state.json"
LOG="$TMP_DIR/caddy-calls.jsonl"

cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
set -u
STATE_FILE="${CADDY_STUB_STATE:?}"
CALL_LOG="${CADDY_STUB_LOG:?}"
URL=""
METHOD="GET"
BODY=""
HAS_W=0
prev=""
for arg in "$@"; do
  case "$prev" in
    -X) METHOD="$arg"; prev=""; continue;;
    -d) BODY="$arg"; prev=""; continue;;
    -w) HAS_W=1; prev=""; continue;;
  esac
  if [[ "$arg" =~ ^http:// ]]; then
    URL="$arg"; prev=""; continue
  fi
  prev="$arg"
done
# Response: <json-body>, then, when the caller asked for -w, a newline and
# status 200 (mirroring real `curl -w '\n%{http_code}'`).
resp() {
  printf '%s\n' "$1"
  if [[ $HAS_W -eq 1 ]]; then
    printf '200\n'
  fi
}
[ -n "$URL" ] || { resp '[]'; exit 0; }
host_and_path="${URL#*://}"
path="${host_and_path#*/}"
b="null"
if [ -n "$BODY" ]; then
  b="$(printf '%s' "$BODY" | jq -c . 2>/dev/null || printf 'null')"
fi
jq -cn --arg m "$METHOD" --arg p "$path" --argjson b "$b" \
  '{method:$m,path:$p,body:$b}' >> "$CALL_LOG" 2>/dev/null || true
if [ ! -f "$STATE_FILE" ]; then printf '[]' > "$STATE_FILE"; fi
case "$path" in
  config/apps/http/servers)
    resp '{"srv0":{"listen":["http://127.0.0.1:80","https://127.0.0.1:443"]}}'
    ;;
  config/apps/http/servers/*/routes/*)
    idx="${path##*/}"
    tmp="${STATE_FILE}.del.$$"
    if jq --argjson i "$idx" 'del(.[$i])' "$STATE_FILE" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$STATE_FILE"
    fi
    rm -f "$tmp"
    resp '{}'
    ;;
  config/apps/http/servers/*/routes)
    if [[ "$METHOD" == "POST" ]]; then
      tmp="${STATE_FILE}.append.$$"
      if jq --argjson new "$BODY" '. + [$new]' "$STATE_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$STATE_FILE"
      fi
      rm -f "$tmp"
      resp '{}'
    else
      body_content="$(cat "$STATE_FILE" 2>/dev/null || printf '[]')"
      resp "$body_content"
    fi
    ;;
  *)
    resp '[]'
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/curl"
export CADDY_STUB_STATE="$STATE" CADDY_STUB_LOG="$LOG"
touch "$LOG"

# AC3a: seed [self], add_route acme.
printf '[
  {
    "match": [{"host": ["self.disinto.ai"]}],
    "handle": [{"handler": "reverse_proxy", "upstreams": [{"dial": "127.0.0.1:20000"}]}]
  }
]' > "$STATE"
run_route add_route "acme" 20001
if [ "$rc" -ne 0 ]; then
  ac_fail "AC3a: add_route acme should exit 0 (rc=$rc, err=$err)"
fi
post_count=$(jq -cs 'length' <(jq -c 'select(.method == "POST")' "$LOG" 2>/dev/null) 2>/dev/null || echo 0)
if [ "$post_count" != "1" ]; then
  ac_fail "AC3a: expected exactly one POST, got $post_count"
fi
if ! jq -e 'select(.method == "POST") | .body.match[0].host[0] == "acme.disinto.ai"' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC3a: POST body host is not acme.disinto.ai"
fi
if jq -e 'select(.method == "POST") | .body.match[0].host | length == 1' "$LOG" >/dev/null 2>&1; then
  :
else
  ac_fail "AC3a: POST body must have exactly one host"
fi
if jq -e 'select(.method == "POST") | .body.match[0].host[] | test("\\*")' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC3a: POST body contains a wildcard host"
fi
if jq -e 'select(.method == "PUT")' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC3a: a PUT was used (must never PUT /config/)"
fi
if ! jq -e 'any(.[]; .match[0].host == ["acme.disinto.ai"])' "$STATE" >/dev/null 2>&1; then
  ac_fail "AC3a: acme route not present in the stub after add_route"
fi
ac_log "AC3a: add_route POSTs one exact-host route (no PUT, no wildcard)"

# AC3b: remove_route ghost (absent) -> rc 0, nothing deleted.
run_route remove_route "ghost"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC3b: remove_route on absent host should exit 0 (rc=$rc, err=$err)"
fi
if jq -e 'select(.method == "DELETE")' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC3b: remove_route on absent host deleted something"
fi
if ! jq -e 'any(.[]; .match[0].host == ["self.disinto.ai"])' "$STATE" >/dev/null 2>&1; then
  ac_fail "AC3b: self.disinto.ai missing after a no-op remove_route"
fi
ac_log "AC3b: remove_route on absent host is a no-op"

# AC3c: remove_route acme -> deletes only that index; self remains.
run_route remove_route "acme"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC3c: remove_route acme should exit 0 (rc=$rc, err=$err)"
fi
delete_count=$(jq -cs 'length' <(jq -c 'select(.method == "DELETE")' "$LOG" 2>/dev/null) 2>/dev/null || echo 0)
if [ "$delete_count" != "1" ]; then
  ac_fail "AC3c: expected exactly one DELETE, got $delete_count"
fi
if ! jq -e 'any(.[]; .match[0].host == ["self.disinto.ai"])' "$STATE" >/dev/null 2>&1; then
  ac_fail "AC3c: self.disinto.ai missing after removing acme"
fi
if jq -e 'any(.[]; .match[0].host == ["acme.disinto.ai"])' "$STATE" >/dev/null 2>&1; then
  ac_fail "AC3c: acme still present after remove_route acme"
fi
ac_log "AC3c: remove_route acme deleted only acme; self.disinto.ai remains"

# AC3d: a route that shares acme with another host must not be deleted.
printf '[
  {
    "match": [{"host": ["self.disinto.ai"]}]
  },
  {
    "match": [{"host": ["acme.disinto.ai", "extra.disinto.ai"]}]
  }
]' > "$STATE"
run_route remove_route "acme"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC3d: remove_route on a shared-host route should exit 0 (rc=$rc, err=$err)"
fi
if jq -e 'any(.[]; .match[0].host[] == "extra.disinto.ai")' "$STATE" >/dev/null 2>&1; then
  # The shared route must survive (extra must still be there).
  :
else
  # Extra is gone only if the shared route was deleted; our code deletes
  # nothing here, so the shared route (with extra) must remain.
  ac_fail "AC3d: shared-host route was deleted, taking extra.disinto.ai with it"
fi
if jq -e 'any(.[]; .match[0].host[] == "acme.disinto.ai")' "$STATE" >/dev/null 2>&1; then
  :
else
  ac_fail "AC3d: acme host missing — the shared route was altered by remove_route"
fi
ac_log "AC3d: a route sharing acme with another host is not deleted by remove_route acme"

# AC4: all acceptance criteria passed.
ac_log "AC4: all checks passed"
ac_pass
