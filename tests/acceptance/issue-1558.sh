#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1558.sh
#
# Issue #1558: feat(edge): approve adds one route and prints the tunnel
# command
#
# approve is the only verb that may open <name>.disinto.ai, and only when
# EDGE_APPLY=1. That path allocates a port and calls add_route, but the old
# output never told the caller the URL or the tunnel command. This test drives
# verbs/approve.sh through lib/apply-name.sh against a throwaway root and a
# stateful curl stub (no network) and asserts:
#
#   * AC1: with EDGE_APPLY=1, a successful admin approve posts exactly one
#         route for the exact host <name>.<DOMAIN_SUFFIX> (proxied to the
#         allocated port) and prints the updated compact account row (status
#         approved) followed by exactly two plain lines on stdout:
#             https://<name>.<DOMAIN_SUFFIX>
#             ssh -N -R 127.0.0.1:<port>:127.0.0.1:<port> disinto-tunnel@<host>
#         where <port> is the allocated port and <host> is $PORTER_SSH_HOST
#         when set, otherwise the machine's hostname;
#   * AC1b: with $PORTER_SSH_HOST unset, the command's <host> is the hostname;
#   * AC2: a failed add_route (downed-Caddy stub) makes approve return 1 with
#         {"error":"apply failed"}, leaves status pending, and prints no
#         URL/tunnel command;
#   * AC3a: with EDGE_APPLY=0, approve invokes no curl at all and prints no
#         tunnel command (the row is still set to approved — the no-apply
#         mode is a pure ledger mutation);
#   * AC3b: with EDGE_APPLY unset, same as AC3a (genuinely unset in the
#         test process env, not just unset in the child);
#   * AC4: the stub shows no request whose URL/path contains gandi, self, or
#         a zone update (approve must not create a DNS record), and the
#         verb's apply path never calls porter-dns.sh (checked at source level
#         and by the call log);
#   * the test exits 0 and calls ac_pass.
#
# Hermetic: no network. curl is a stateful stub that records every request
# (method, url, path, body) in a JSONL log and serves the Caddy admin API
# shape used by lib/caddy.sh. The port registry + account ledger are throwaway
# under $TMP_DIR (never /var/lib/disinto).
#
# Run via: tools/run-acceptance.sh 1558
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep mktemp rm cat printf sed awk chmod hostname env

APPROVE="$REPO_ROOT/tools/edge-control/verbs/approve.sh"
APPLY="$REPO_ROOT/tools/edge-control/lib/apply-name.sh"
ac_assert_file "$APPROVE" "tools/edge-control/verbs/approve.sh is missing"
ac_assert_file "$APPLY" "tools/edge-control/lib/apply-name.sh is missing"

# Source-level sanity: the approve path must not shell out to Gandi /
# porter-dns.sh (comment lines may mention the files; code lines may not).
if grep -vE '^[[:space:]]*#' "$APPROVE" 2>/dev/null \
    | grep -EqiE 'porter-dns|gandi'; then
  ac_fail "verbs/approve.sh must not call porter-dns.sh or shell out to Gandi"
fi
if grep -vE '^[[:space:]]*#' "$APPLY" 2>/dev/null \
    | grep -EqiE 'porter-dns|gandi'; then
  ac_fail "lib/apply-name.sh must not call porter-dns.sh or shell out to Gandi"
fi

# The verb reads EDGE_APPLY / PORTER_SSH_HOST from its environment; start the
# test with both clean so the "unset" case is genuinely unset.
unset -v PORTER_SSH_HOST EDGE_APPLY 2>/dev/null || true

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1558.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ── Stateful curl stub (Caddy admin API) ─────────────────────────────────────
STUB_DIR="$TMP_DIR/stub"
STATE="$TMP_DIR/caddy-state.json"
LOG="$TMP_DIR/caddy-calls.jsonl"
mkdir -p "$STUB_DIR"

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
# Record every request for the test.
jq -cn --arg m "$METHOD" --arg u "$URL" --arg p "$path" --argjson b "$b" \
  '{method:$m,url:$u,path:$p,body:$b}' >> "$CALL_LOG" 2>/dev/null || true
# AC2: a "downed Caddy" — POST to routes exits 1 without a response.
if [[ "$METHOD" == "POST" && -n "${AC_STUB_FAIL_POST:-}" \
    && "$path" == "config/apps/http/servers"/*/routes ]]; then
  exit 1
fi
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

# Fresh throwaway root: ledger + pre-existing registry dir (so ports.sh
# skips its real-host root/chown) with a "other" project at 20000 (acme then
# deterministically gets 20001) + the "acme" row (pending, FP_A) + admin.
new_root() {
  local name="$1"
  ROOT="$TMP_DIR/$name"
  mkdir -p "$ROOT/var/lib/disinto" "$ROOT/home/disinto-tunnel/.ssh"
  ACCOUNTS_FILE="$ROOT/var/lib/disinto/accounts.json"
  REGISTRY_DIR="$ROOT/var/lib/disinto"
  printf '[]' > "$STATE"
  : > "$LOG"
  printf '{"version":1,"projects":{"other":{"port":20000,"fqdn":"other.disinto.ai","registered_by":"admin"}}}\n' \
    > "$REGISTRY_DIR/registry.json"
  printf '{"version":1,"accounts":{}}\n' > "$ACCOUNTS_FILE"
  seed_row "$FP_A" "acme" "false" 0
  seed_row "$FP_ADMIN" "admin-who" "true" 0
}

# Run the approve verb as the given fingerprint with optional per-run env.
# Sets globals RC (exit code) and OUT (stdout).
run_approve() {
  local fp="$1"
  shift
  local envs=(
    PATH="$STUB_DIR:$PATH"
    ACCOUNTS_FILE="$ACCOUNTS_FILE"
    REGISTRY_DIR="$REGISTRY_DIR"
    PORTER_ROOT="$ROOT"
    CADDY_ADMIN_URL="http://127.0.0.1:2019"
    DOMAIN_SUFFIX="disinto.ai"
    CADDY_STUB_STATE="$STATE"
    CADDY_STUB_LOG="$LOG"
    DISPATCH_FP="$fp"
  )
  if [ $# -gt 0 ]; then
    envs+=("$@")
  fi
  RC=0
  OUT="$(env "${envs[@]}" bash "$APPROVE" "acme" 2>"$TMP_DIR/stderr.txt")" || RC=$?
}

# AC4 helper: the stub log must contain no request whose URL/path mentions
# Gandi, `self`, or a zone update (approve must not create a DNS record).
# A literal grep over the stub's JSONL is deterministic (the local jq build
# exits 0 on an empty input file, which would defeat a `jq -e` `if`).
no_dns_request() {
  if grep -EqE 'gandi|self|zone' "$LOG"; then
    ac_fail "a stubbed request URL/path contains gandi/self/zone: $(grep -E 'gandi|self|zone' "$LOG" || true)"
  fi
}

# The regex for an approved row. It lives in a variable (unquoted on the RHS
# of =~) so bash treats it as an ERE; a quoted string on that RHS would be
# matched as a literal in this environment.
APPROVED_ROW_RE='"status"[[:space:]]*:[[:space:]]*"approved"'

# Assert: approved row + the two plain lines (URL + tunnel command) with
# the expected <host>.
expect_apply_output() {
  local host="$1"
  if [[ ! "$OUT" =~ $APPROVED_ROW_RE ]]; then
    ac_fail "updated row must have status approved, got: $OUT"
  fi
  local nlines
  nlines="$(printf '%s\n' "$OUT" | wc -l)"
  if [ "$nlines" -ne 3 ]; then
    ac_fail "expected exactly 3 stdout lines (row, URL, command), got $nlines: $OUT"
  fi
  local url_line cmd_line
  url_line="$(printf '%s\n' "$OUT" | sed -n '2p')"
  cmd_line="$(printf '%s\n' "$OUT" | sed -n '3p')"
  ac_assert_eq "$url_line" "https://acme.disinto.ai" "URL line"
  ac_assert_eq "$cmd_line" \
    "ssh -N -R 127.0.0.1:20001:127.0.0.1:20001 disinto-tunnel@$host" \
    "ssh command line"
}

# Assert the Caddy call log + route state reflect exactly one POST of the
# exact-host route for acme.
expect_one_route() {
  local nposts
  nposts="$(jq -cs '[.[] | select(.method == "POST")] | length' "$LOG")"
  if [ "$nposts" -ne 1 ]; then
    ac_fail "expected exactly one POST to Caddy, got $nposts"
  fi
  if ! jq -e 'select(.method == "POST")
                | .body.match[0].host == ["acme.disinto.ai"]' "$LOG" \
      >/dev/null 2>&1; then
    ac_fail 'the POSTed route host must be exactly ["acme.disinto.ai"]'
  fi
  if ! jq -e 'select(.method == "POST")
                | .body.handle[0].upstreams[0].dial == "127.0.0.1:20001"' "$LOG" \
      >/dev/null 2>&1; then
    ac_fail "the POSTed route must proxy to 127.0.0.1:20001"
  fi
  if jq -e 'select(.method == "PUT" or .method == "DELETE")' "$LOG" \
      >/dev/null 2>&1; then
    ac_fail "approve must not PUT/DELETE on the Caddy admin API"
  fi
  if jq -e '.[] | select(.body.match != null)
           | .body.match[] | .host[] | test("\\*")' "$LOG" \
      >/dev/null 2>&1; then
    ac_fail "a wildcard host was POSTed to a route"
  fi
  # State must carry the acme route. (nposts == 1 above plus the no-
  # PUT/DELETE checks imply it carries exactly one.)
  if ! jq -e 'any(.[]; .match[0].host == ["acme.disinto.ai"]
                   and .handle[0].upstreams[0].dial == "127.0.0.1:20001")' \
        "$STATE" >/dev/null 2>&1; then
    ac_fail "Caddy route state after approve is wrong: $(cat "$STATE")"
  fi
}

# ── AC1. EDGE_APPLY=1: one exact-host route + URL/tunnel command printed ─────
ac_log "AC1: EDGE_APPLY=1 — one exact-host route; URL + tunnel command printed"
new_root "a1"
run_approve "$FP_ADMIN" PORTER_SSH_HOST="tunnel.example.org" EDGE_APPLY=1
no_dns_request

if [ "$RC" -ne 0 ]; then
  ac_fail "AC1: admin approve (EDGE_APPLY=1) must return 0 (rc=$RC, out=$OUT)"
fi
expect_apply_output "tunnel.example.org"
expect_one_route
reg_port="$(jq -r '.projects["acme"].port // empty' "$REGISTRY_DIR/registry.json")"
if [ "$reg_port" -ne "20001" ]; then
  ac_fail "AC1: expected port 20001 allocated to acme, got $reg_port"
fi
ac_log "AC1: pass"

# ── AC1b. same, without PORTER_SSH_HOST: <host> falls back to hostname ───────
ac_log "AC1b: no PORTER_SSH_HOST — hostname fallback"
new_root "a2"
run_approve "$FP_ADMIN" EDGE_APPLY=1
no_dns_request
if [ "$RC" -ne 0 ]; then
  ac_fail "AC1b: admin approve (EDGE_APPLY=1, no PORTER_SSH_HOST) must return 0 (rc=$RC, out=$OUT)"
fi
expect_apply_output "$(hostname)"
expect_one_route
ac_log "AC1b: pass"

# ── AC2. failed add_route → status pending, no URL/tunnel command ────────────
ac_log "AC2: failed add_route leaves status pending, no tunnel command printed"
new_root "a3"
run_approve "$FP_ADMIN" EDGE_APPLY=1 AC_STUB_FAIL_POST=1
no_dns_request
if [ "$RC" -ne 1 ]; then
  ac_fail "AC2: failed add_route must make approve return 1 (rc=$RC, out=$OUT)"
fi
case "$OUT" in
  *'"error":"apply failed"'*) ;;
  *) ac_fail "AC2: expected {\"error\":\"apply failed\"}, got: $OUT" ;;
esac
status="$(jq -r --arg fp "$FP_A" '.accounts[$fp].status // empty' "$ACCOUNTS_FILE")"
if [ "$status" != "pending" ]; then
  ac_fail "AC2: a failed apply must leave status pending, got $status"
fi
if printf '%s\n' "$OUT" | grep -EqE 'https://|ssh -N -R'; then
  ac_fail "AC2: a failed apply must print no URL or tunnel command, got: $OUT"
fi
ac_log "AC2: pass"

# ── AC3a. EDGE_APPLY=0: no curl at all, no tunnel command ─────────────────────
ac_log "AC3a: EDGE_APPLY=0 — no curl, no tunnel command"
new_root "a4"
run_approve "$FP_ADMIN" EDGE_APPLY=0
no_dns_request
if [ "$RC" -ne 0 ]; then
  ac_fail "AC3a: EDGE_APPLY=0 approve must return 0 (rc=$RC, out=$OUT)"
fi
if [ -s "$LOG" ]; then
  ac_fail "AC3a: EDGE_APPLY=0 must invoke no curl (call log has content): $(cat "$LOG")"
fi
if printf '%s\n' "$OUT" | grep -EqE 'https://|ssh -N -R'; then
  ac_fail "AC3a: EDGE_APPLY=0 must print no URL or tunnel command, got: $OUT"
fi
nlines="$(printf '%s\n' "$OUT" | wc -l)"
if [ "$nlines" -ne 1 ]; then
  ac_fail "AC3a: EDGE_APPLY=0 must print exactly the row, got $nlines lines: $OUT"
fi
if [[ ! "$OUT" =~ $APPROVED_ROW_RE ]]; then
  ac_fail "AC3a: the row must be status approved, got: $OUT"
fi
ac_log "AC3a: pass"

# ── AC3b. EDGE_APPLY unset (genuinely unset in the test process env) ─────────
ac_log "AC3b: EDGE_APPLY unset — no curl, no tunnel command"
new_root "a5"
run_approve "$FP_ADMIN"
no_dns_request
if [ "$RC" -ne 0 ]; then
  ac_fail "AC3b: EDGE_APPLY-unset approve must return 0 (rc=$RC, out=$OUT)"
fi
if [ -s "$LOG" ]; then
  ac_fail "AC3b: EDGE_APPLY-unset must invoke no curl (call log has content): $(cat "$LOG")"
fi
if printf '%s\n' "$OUT" | grep -EqE 'https://|ssh -N -R'; then
  ac_fail "AC3b: EDGE_APPLY-unset must print no URL or tunnel command, got: $OUT"
fi
if [[ ! "$OUT" =~ $APPROVED_ROW_RE ]]; then
  ac_fail "AC3b: the row must be status approved, got: $OUT"
fi
ac_log "AC3b: pass"

# AC4 summary: every run's stub log was clean of DNS-related traffic (checked
# per run above via no_dns_request), and the source check at the top guarantees
# no porter-dns.sh / Gandi shell-out in the approve path.
ac_pass
