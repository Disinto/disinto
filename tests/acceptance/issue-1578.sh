#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1578.sh
#
# Issue #1578: fix(edge): porter-dns uses the LiveDNS records API
#
# The old porter-dns.sh hit /v5/domains/<suffix>/records, which returns 404.
# The real Gandi LiveDNS v5 endpoint is /v5/livedns/domains/<suffix>/records,
# and it returns rrset_name / rrset_type / rrset_values (not name/type/value).
# This test exercises tools/edge-control/porter-dns.sh against a stateful
# LiveDNS curl stub — no network, no real registrar — and asserts:
#
#   * AC1 a missing * A record creates only that record: exactly one GET and
#     one PUT whose URLs contain /v5/livedns/domains/disinto.ai/records, and no
#     request ever targets the old /v5/domains/disinto.ai/records path.
#   * AC2 the PUT body is the * A record only
#     ({"rrset_ttl":300,"rrset_values":["<ip>"]}), and no request URL contains
#     @, www, or self.
#   * AC3 an existing * A record with a different IP is not changed unless
#     --set-wildcard is passed (refuse: GET only, rc!=0, current value printed,
#     state unchanged, token never printed; with --set-wildcard: GET + one PUT
#     and the value is updated); a matching IP is a no-op.
#   * AC4 the test exits 0 and calls ac_pass.
#
# Hermetic: no network; curl is a stateful stub; PORTER_ROOT is a throwaway
# $TMP_DIR subdir; PORTER_PUBLIC_IP is the value seam.
#
# Run via: tools/run-acceptance.sh 1578
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep cmp mktemp rm cat printf chmod head

DNS_SCRIPT="$REPO_ROOT/tools/edge-control/porter-dns.sh"
ac_assert_file "$DNS_SCRIPT" "tools/edge-control/porter-dns.sh is missing"

# Source-level wiring: porter-dns.sh must use the LiveDNS endpoint and must
# not carry the old 404ing base as code.
if ! grep -qF '/v5/livedns' "$DNS_SCRIPT"; then
  ac_fail "porter-dns.sh must target the LiveDNS base (/v5/livedns/...)"
fi
if grep -qF 'https://api.gandi.net/v5/domains' "$DNS_SCRIPT"; then
  ac_fail "porter-dns.sh still carries the old https://api.gandi.net/v5/domains base"
fi

# ── Stateful Gandi LiveDNS v5 curl stub ──────────────────────────────────────
TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1578.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

STUB_DIR="$TMP_DIR/stub"
mkdir -p "$STUB_DIR"
STATE_FILE="$TMP_DIR/gandi-state.json"
CALL_LOG="$TMP_DIR/gandi-calls.jsonl"
: > "$CALL_LOG"

cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
# Fake Gandi LiveDNS v5 endpoint. State lives in GANDI_STUB_STATE ({"data":[
# {id, rrset_name, rrset_type, rrset_ttl, rrset_values},...]}). Every request
# appends {method,url,auth,body} to GANDI_STUB_LOG.
set -u
STATE_FILE="${GANDI_STUB_STATE:?GANDI_STUB_STATE not set}"
CALL_LOG="${GANDI_STUB_LOG:?GANDI_STUB_LOG not set}"
url=""
method="GET"
body=""
auth=""
prev=""
# Parse curl-style args: -X METHOD, -H HEADER, -d BODY, -f|-s|-S|-L (valueless),
# and a trailing https:// URL. Only the Authorization header is recorded.
for arg in "$@"; do
  case "$prev" in
    -X) method="$arg"; prev=""; continue ;;
    -d) body="$arg"; prev=""; continue ;;
    -H)
      if [[ "$arg" == Authorization:* ]]; then
        auth="$arg"
      fi
      prev=""; continue ;;
  esac
  case "$arg" in
    -X|-d|-H) prev="$arg" ;;
    -f|-s|-S|-L) : ;;
    https://*) url="$arg" ;;
  esac
done
if [[ -n "$body" ]]; then
  b="$(printf '%s' "$body" | jq -c . 2>/dev/null || printf 'null')"
else
  b="null"
fi
jq -cn --arg m "$method" --arg u "$url" --arg a "$auth" --argjson b "$b" \
  '{method: $m, url: $u, auth: $a, body: $b}' >> "$CALL_LOG"
if [[ -z "$url" ]]; then
  printf '{"data":[]}'
  exit 0
fi
path="${url#*://}"
case "$path" in
  */domains/*/records)
    cat "$STATE_FILE"
    ;;
  */domains/*/records/*)
    # PUT upserts the * A record (the only name porter-dns.sh may write).
    tmp="${STATE_FILE}.tmp.$$"
    if [[ "$method" == "PUT" ]] && [[ -n "$body" ]]; then
      if jq -e '.data | any(.rrset_name == "*" and .rrset_type == "A")' \
          "$STATE_FILE" >/dev/null 2>&1; then
        # A * A record exists: overwrite its values.
        jq -c --argjson b "$b" \
          '.data = (.data | map(if (.rrset_name == "*" and .rrset_type == "A")
             then {id: .id, rrset_name: "*", rrset_type: "A",
                  rrset_ttl: ($b.rrset_ttl // 300), rrset_values: $b.rrset_values}
             else . end))' "$STATE_FILE" > "$tmp" 2>/dev/null
      else
        # No * A record: append one.
        next_num="$(jq -r '.data | length' "$STATE_FILE" 2>/dev/null || echo 0)"
        next_num=$((next_num + 1))
        jq -c --argjson b "$b" --arg id "rec${next_num}" \
          '.data = (.data + [{id: $id, rrset_name: "*", rrset_type: "A",
          rrset_ttl: ($b.rrset_ttl // 300), rrset_values: $b.rrset_values}])' \
          "$STATE_FILE" > "$tmp" 2>/dev/null
      fi
      if mv "$tmp" "$STATE_FILE" 2>/dev/null; then
        cat "$STATE_FILE"
      else
        rm -f "$tmp"
        printf '{"error":"stub upsert failed"}'
      fi
    else
      rm -f "$tmp" 2>/dev/null
      cat "$STATE_FILE"
    fi
    ;;
  *)
    printf '{"data":[]}'
    ;;
esac
exit 0
STUB
chmod a+x "$STUB_DIR/curl"
export GANDI_STUB_STATE="$STATE_FILE" GANDI_STUB_LOG="$CALL_LOG"
touch "$CALL_LOG"

# ── Fixture helpers ───────────────────────────────────────────────────────────
make_root() {
  local root="$1"
  mkdir -p "$root/etc/caddy" "$root/etc/porter" "$root/var/lib/disinto"
}

# <root> <rel> <token> [mode=600] where rel is e.g. etc/porter/gandi.env
write_token_file() {
  local root="$1" rel="$2" token="$3" mode="${4:-600}"
  printf 'GANDI_API_KEY=%s\n' "$token" > "${root}/${rel}"
  chmod "$mode" "${root}/${rel}"
}

# Seed the stub zone state with a JSON object (single-quoted in this script so
# the embedded double quotes are literal). The stub feeds the file straight to
# jq, so this must be well-formed JSON.
seed_state() {
  printf '%s\n' "$1" > "$STATE_FILE"
}

# Run porter-dns.sh against the stub. Sets globals rc, OUT, ERR.
run_dns() {
  local root="$1"
  shift
  rc=0
  OUT="$TMP_DIR/run.out"
  ERR="$TMP_DIR/run.err"
  : > "$CALL_LOG"
  {
    PORTER_ROOT="$root" \
      DOMAIN_SUFFIX="disinto.ai" \
      PORTER_PUBLIC_IP="$PORTER_PUBLIC_IP" \
      PATH="$STUB_DIR:$PATH" \
        bash "$DNS_SCRIPT" "$@"
  } >"$OUT" 2>"$ERR" || rc=$?
}

# Assertion helpers over the call log + state file.
n_calls() {  # n_calls <method>
  jq -rs "[.[] | select(.method == \"${1}\")] | length" "$CALL_LOG"
}
put_body() {
  # Body of the first PUT call (JSON value, or "null").
  jq -rs 'first(.[] | select(.method == "PUT")) | .body' "$CALL_LOG" 2>/dev/null \
    || printf 'null'
}
put_url() {
  # URL of the first PUT call.
  jq -rs 'first(.[] | select(.method == "PUT")) | .url' "$CALL_LOG" 2>/dev/null \
    || printf ''
}
# Wildcard A record value in the stub state ("" if absent).
wildcard_value() {
  jq -r '[.data[]? | select(.rrset_type == "A" and .rrset_name == "*")] | .[0].rrset_values[0] // empty' "$STATE_FILE" 2>/dev/null || printf ''
}
# Count of request URLs containing the old (404) base path — must be zero.
old_path_count() {
  jq -rs '[.[] | select(.url | test("v5/domains/disinto\\.ai/records"))] | length' "$CALL_LOG"
}
# Count of request URLs that touched a forbidden name (self / www / @).
bad_url_count() {
  jq -rs '[.[] | select(.url | test("self|www|@"))] | length' "$CALL_LOG"
}
assert_no_token() {  # <token> — token must never appear in OUT/ERR
  local token="$1"
  if [[ "$OUT" == *"$token"* || "$ERR" == *"$token"* ]]; then
    ac_fail "run output leaked the token $token"
  fi
}

# ── AC1. missing * A record -> GET + PUT on the LiveDNS path only ─────────────
ac_log "AC1: missing * A record creates only that record on the LiveDNS path"
ROOT1="$TMP_DIR/root1"
make_root "$ROOT1"
write_token_file "$ROOT1" "etc/porter/gandi.env" "tok-1578-create"
seed_state '{"data":[]}'
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT1"
if [[ $rc -ne 0 ]]; then
  ac_fail "AC1: create run should exit 0 (rc=$rc): $OUT"
fi
if [[ "$(n_calls GET)" != "1" ]]; then
  ac_fail "AC1: expected exactly 1 GET, got $(n_calls GET)"
fi
if [[ "$(n_calls PUT)" != "1" ]]; then
  ac_fail "AC1: expected exactly 1 PUT (no POST), got $(n_calls PUT) PUT, $(n_calls POST) POST"
fi
if [[ "$(n_calls POST)" != "0" ]]; then
  ac_fail "AC1: a POST was issued (the old create path is gone)"
fi
# Both calls must go through the LiveDNS records path.
if [[ "$(jq -rs '[.[] | select(.url | test("v5/livedns/domains/disinto\\.ai/records"))] | length' "$CALL_LOG")" != "2" ]]; then
  ac_fail "AC1a: not every request used /v5/livedns/domains/disinto.ai/records"
fi
if ! grep -qF 'records/%2A/A' "$CALL_LOG"; then
  ac_fail "AC1b: the PUT did not target records/%2A/A"
fi
if [[ "$(old_path_count)" != "0" ]]; then
  ac_fail "AC1c: a request targeted the old /v5/domains/disinto.ai/records path"
fi
if [[ "$(wildcard_value)" != "203.0.113.10" ]]; then
  ac_fail "AC1d: state does not hold the * A record -> 203.0.113.10 (got '$(wildcard_value)')"
fi
assert_no_token "tok-1578-create"
ac_log "AC1: pass"

# ── AC2. PUT body is the * A record only; no @/www/self in any URL ───────────
ac_log "AC2: PUT body is the * A record only; no @/www/self in any request URL"
pb="$(put_body)"
if [[ "$(jq -e --arg ip 203.0.113.10 '.rrset_ttl == 300 and (.rrset_values | length == 1) and .rrset_values[0] == $ip' <<<"$pb" 2>/dev/null)" != "true" ]]; then
  ac_fail "AC2: PUT body is not the * A record only: $pb"
fi
if [[ "$(bad_url_count)" != "0" ]]; then
  ac_fail "AC2: a request URL contained @, www, or self (count=$(bad_url_count))"
fi
ac_log "AC2: pass"

# ── AC3a. different IP, no --set-wildcard -> refuse, state unchanged ──────────
ac_log "AC3a: existing * A with a different IP, no --set-wildcard -> refuse"
ROOT3="$TMP_DIR/root3"
make_root "$ROOT3"
write_token_file "$ROOT3" "etc/porter/gandi.env" "tok-1578-diff"
seed_state '{"data":[{"id":"rec1","rrset_name":"*","rrset_type":"A","rrset_ttl":300,"rrset_values":["198.51.100.2"]}]}'
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT3"
if [[ $rc -eq 0 ]]; then
  ac_fail "AC3a: a different IP without --set-wildcard must exit non-zero (rc=$rc)"
fi
if [[ "$(n_calls PUT)" != "0" ]]; then
  ac_fail "AC3a: refuse must issue no PUT (got $(n_calls PUT))"
fi
if [[ "$(n_calls GET)" != "1" ]]; then
  ac_fail "AC3a: expected exactly 1 GET, got $(n_calls GET)"
fi
if [[ "$(wildcard_value)" != "198.51.100.2" ]]; then
  ac_fail "AC3a: state changed without --set-wildcard (now '$(wildcard_value)')"
fi
if ! grep -qF '198.51.100.2' "$OUT"; then
  ac_fail "AC3a: refused run must print the current value (198.51.100.2): $OUT"
fi
assert_no_token "tok-1578-diff"
ac_log "AC3a: pass"

# ── AC3b. different IP, --set-wildcard -> update the * A record ───────────────
ac_log "AC3b: existing * A with a different IP, --set-wildcard -> update"
ROOT4="$TMP_DIR/root4"
make_root "$ROOT4"
write_token_file "$ROOT4" "etc/porter/gandi.env" "tok-1578-diff2"
seed_state '{"data":[{"id":"rec1","rrset_name":"*","rrset_type":"A","rrset_ttl":300,"rrset_values":["198.51.100.2"]}]}'
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT4" --set-wildcard
if [[ $rc -ne 0 ]]; then
  ac_fail "AC3b: --set-wildcard update should exit 0 (rc=$rc): $OUT"
fi
if [[ "$(n_calls GET)" != "1" ]]; then
  ac_fail "AC3b: expected exactly 1 GET, got $(n_calls GET)"
fi
if [[ "$(n_calls PUT)" != "1" ]]; then
  ac_fail "AC3b: expected exactly 1 PUT, got $(n_calls PUT)"
fi
if [[ "$(wildcard_value)" != "203.0.113.10" ]]; then
  ac_fail "AC3b: --set-wildcard did not update the * A record (now '$(wildcard_value)')"
fi
pb="$(put_body)"
if [[ "$(jq -e --arg ip 203.0.113.10 '.rrset_ttl == 300 and .rrset_values[0] == $ip' <<<"$pb" 2>/dev/null)" != "true" ]]; then
  ac_fail "AC3b: update PUT body is not the * A record: $pb"
fi
if [[ "$(bad_url_count)" != "0" ]]; then
  ac_fail "AC3b: a request URL contained @, www, or self (count=$(bad_url_count))"
fi
assert_no_token "tok-1578-diff2"
ac_log "AC3b: pass"

# ── AC4. matching IP -> no-op (GET only) ──────────────────────────────────────
ac_log "AC4: existing * A with a matching IP is a no-op (GET only)"
ROOT5="$TMP_DIR/root5"
make_root "$ROOT5"
write_token_file "$ROOT5" "etc/porter/gandi.env" "tok-1578-same"
seed_state '{"data":[{"id":"rec1","rrset_name":"*","rrset_type":"A","rrset_ttl":300,"rrset_values":["203.0.113.10"]}]}'
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT5"
if [[ $rc -ne 0 ]]; then
  ac_fail "AC4: a matching * A record must exit 0 (rc=$rc): $OUT"
fi
if [[ "$(n_calls PUT)" != "0" ]]; then
  ac_fail "AC4: a matching * A record must be a no-op (no PUT), got $(n_calls PUT)"
fi
if [[ "$(n_calls GET)" != "1" ]]; then
  ac_fail "AC4: expected exactly 1 GET, got $(n_calls GET)"
fi
assert_no_token "tok-1578-same"
ac_log "AC4: pass"

# ── AC5. all acceptance criteria passed ───────────────────────────────────────
ac_log "AC5: all checks passed"
ac_pass
