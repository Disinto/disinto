#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1556.sh
#
# Issue #1556 — feat(edge): ensure the wildcard A record once and never edit
# other names. Exercises tools/edge-control/porter-dns.sh against a stateful
# Gandi LiveDNS v5 curl stub. (The original issue predates the LiveDNS migration
# of #1578; this test now verifies the post-1578 contract:)
#   * AC1: a missing * A record is created — exactly one GET and one PUT to
#     /v5/livedns/domains/disinto.ai/records (GET on .../records, PUT on
#     .../records/%2A/A), body {"rrset_ttl":300,"rrset_values":["<ip>"]},
#     no POST; the caddy token is used; the ledger is untouched.
#   * AC2: an existing * A record with a different IP is left unchanged (GET
#     only, rc!=0, current value printed) unless --set-wildcard is passed.
#   * AC3: --set-wildcard updates only the * A record (GET + one PUT to
#     .../records/%2A/A, no POST, decoy names intact).
#   * AC3b: porter-wrap.sh does not export GANDI_API_KEY, and no CODE line
#     under verbs/ references porter-dns.sh (comment mentions excluded).
#   * AC4: a matching * A record is a no-op; the caddy token file takes
#     priority and the porter file is the fallback; the token is never printed.
#
# Hermetic: no network; curl is a stateful stub; PORTER_ROOT is a throwaway
# $TMP_DIR subdir; PORTER_PUBLIC_IP is the value seam.
#
# Run via: tools/run-acceptance.sh 1556
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep awk sed cat printf chmod cp rm mv find mktemp
ac_require_cmd curl   # only needed to be present for the stub path; not invoked

DNS_SCRIPT="tools/edge-control/porter-dns.sh"
VERBS_DIR="tools/edge-control/verbs"
PORTER_WRAP="tools/edge-control/porter-wrap.sh"

TMP_DIR="$(mktemp -d /tmp/issue-1556.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

STUB_DIR="$TMP_DIR/stub"
mkdir -p "$STUB_DIR"
STATE_FILE="$TMP_DIR/state.json"
CALL_LOG="$TMP_DIR/curl5.log"

cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
# Fake Gandi LiveDNS v5 endpoint. State lives in GANDI_STUB_STATE ({"data":
# [{id, rrset_name, rrset_type, rrset_ttl, rrset_values},...]}). Every request
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
chmod +x "$STUB_DIR/curl"
export PATH="$STUB_DIR:$PATH"
export GANDI_STUB_STATE="$STATE_FILE" GANDI_STUB_LOG="$CALL_LOG"
touch "$CALL_LOG"

# make_root <root> — throwaway PORTER_ROOT; creates the caddy token dir (the
# caddy file takes priority) plus the porter dir and the ledger file.
make_root() {
  local root="$1"
  mkdir -p "$root/etc/caddy" "$root/etc/porter" "$root/var/lib/disinto"
  printf '{"version":1,"accounts":{}}' > "$root/var/lib/disinto/accounts.json"
}

write_token_file() {
  local root="$1" rel="$2" token="$3" mode="${4:-600}"
  printf 'GANDI_API_KEY=%s\n' "$token" > "${root}/${rel}"
  chmod "$mode" "${root}/${rel}"
}

seed_state() {
  printf '%s\n' "$1" > "$STATE_FILE"
}

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
      GANDI_STUB_STATE="$STATE_FILE" \
      GANDI_STUB_LOG="$CALL_LOG" \
      PATH="$STUB_DIR:$PATH" \
        bash "$DNS_SCRIPT" "$@"
  } >"$OUT" 2>"$ERR" || rc=$?
}

# n_calls <method>
n_calls() {
  jq -rs "[.[] | select(.method == \"${1}\")] | length" "$CALL_LOG"
}

# put_body — JSON body of the (single) PUT call.
put_body() {
  jq -rs 'first(.[] | select(.method == "PUT")) | .body' "$CALL_LOG" 2>/dev/null || printf 'null'
}

# put_url — URL of the (single) PUT call.
put_url() {
  jq -rs 'first(.[] | select(.method == "PUT")) | .url' "$CALL_LOG" 2>/dev/null || printf ''
}

# wildcard_value — current * A rrset value (new LiveDNS shape).
wildcard_value() {
  jq -r '[.data[]? | select(.rrset_type == "A" and .rrset_name == "*")] | .[0].rrset_values[0] // empty' "$STATE_FILE" 2>/dev/null || printf ''
}

# decoy_count — non-* A records that must survive unchanged.
decoy_count() {
  jq -r '[.data[]? | select((.rrset_name == "*" and .rrset_type == "CNAME") or (.rrset_name == "@") or (.rrset_name == "www") or (.rrset_name == "self") or (.rrset_name == "ns1"))] | length' "$STATE_FILE"
}

# bad_url_count — calls to a stub URL containing self/@/www (name leakage).
bad_url_count() {
  jq -rs '[.[] | select(.url | test("self|www|@"))] | length' "$CALL_LOG"
}

# old_path_count — calls to the legacy /v5/domains/records path (must be 0).
old_path_count() {
  jq -rs '[.[] | select(.url | test("v5/domains/disinto\\.ai/records"))] | length' "$CALL_LOG"
}

# assert_no_token <token> — token must not leak into stdout/stderr.
assert_no_token() {
  local token="$1"
  if [[ "$OUT" == *"$token"* || "$ERR" == *"$token"* ]]; then
    ac_fail "run output leaked the token $token"
  fi
}

# =============================================================================
# AC1: create the * A record — one PUT to .../records/%2A/A with the new body,
#     no POST, no legacy path, caddy token used, ledger untouched.
# =============================================================================
ac_log "AC1: missing * A record creates only that record on the LiveDNS path"
ROOT1="$TMP_DIR/root1"
make_root "$ROOT1"
write_token_file "$ROOT1" "etc/caddy/gandi.env" "tok-caddy-1556"
seed_state '{"data":[]}'
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT1"
if [[ $rc -ne 0 ]]; then ac_fail "AC1a: create should exit 0 (rc=$rc)"; fi
if [[ "$(n_calls GET)" != "1" ]]; then ac_fail "AC1a: expected exactly one GET, got $(n_calls GET)"; fi
if [[ "$(n_calls PUT)" != "1" ]]; then ac_fail "AC1a: expected exactly one PUT, got $(n_calls PUT)"; fi
if [[ "$(n_calls POST)" != "0" || "$(n_calls DELETE)" != "0" ]]; then ac_fail "AC1a: a POST/DELETE was used when creating"; fi
if [[ "$(jq -rs '[.[] | select(.url | test("v5/livedns/domains/disinto\\.ai/records"))] | length' "$CALL_LOG")" != "2" ]]; then
  ac_fail "AC1a: not every request used /v5/livedns/domains/disinto.ai/records"
fi
if ! grep -qF 'records/%2A/A' "$CALL_LOG"; then ac_fail "AC1a: the PUT did not target records/%2A/A"; fi
if [[ "$(old_path_count)" != "0" ]]; then ac_fail "AC1a: a request targeted the old /v5/domains/records path"; fi
pb="$(put_body)"
if [[ "$(jq -e --arg ip 203.0.113.10 '.rrset_ttl == 300 and (.rrset_values | length == 1) and .rrset_values[0] == $ip' <<<"$pb" 2>/dev/null)" != "true" ]]; then
  ac_fail "AC1a: PUT body must be {rrset_ttl:300, rrset_values:[203.0.113.10]}"
fi
if [[ "$(wildcard_value)" != "203.0.113.10" ]]; then ac_fail "AC1a: * A record not created"; fi
if [[ "$(jq -r '.data | length' "$STATE_FILE")" != "1" ]]; then ac_fail "AC1a: more than one record"; fi
if [[ "$(jq -s '[.[] | select(.auth == "Authorization: Bearer tok-caddy-1556")] | length' "$CALL_LOG")" != "2" ]]; then
  ac_fail "AC1a: caddy token file not used for both requests"
fi
if ! cmp -s "$ROOT1/var/lib/disinto/accounts.json" <(printf '{"version":1,"accounts":{}}'); then
  ac_fail "AC1a: ledger modified during create (side effect)"
fi
assert_no_token "tok-caddy-1556"
ac_log "AC1: pass"

# =============================================================================
# AC2: differing * A value is left unchanged without --set-wildcard (GET only,
#     rc!=0, current value printed); decoy names survive; token never printed.
# =============================================================================
ac_log "AC2: differing IP without --set-wildcard is left unchanged"
ROOT2="$TMP_DIR/root2"
make_root "$ROOT2"
write_token_file "$ROOT2" "etc/caddy/gandi.env" "tok-caddy-1556"
seed_state '{"data":[
  {"id":"rec1","rrset_name":"*","rrset_type":"A","rrset_values":["198.51.100.7"]},
  {"id":"rec2","rrset_name":"@","rrset_type":"A","rrset_values":["198.51.100.1"]},
  {"id":"rec3","rrset_name":"www","rrset_type":"A","rrset_values":["198.51.100.2"]},
  {"id":"rec4","rrset_name":"self","rrset_type":"A","rrset_values":["198.51.100.3"]},
  {"id":"rec5","rrset_name":"ns1","rrset_type":"NS","rrset_values":["ns1.example"]},
  {"id":"rec6","rrset_name":"*","rrset_type":"CNAME","rrset_values":["c.example"]}
]}'
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT2"
if [[ $rc -eq 0 ]]; then ac_fail "AC2a: differing value without --set-wildcard must exit non-zero"; fi
if [[ "$(n_calls GET)" != "1" ]]; then ac_fail "AC2a: expected exactly one GET, got $(n_calls GET)"; fi
if [[ "$(n_calls PUT)" != "0" || "$(n_calls POST)" != "0" || "$(n_calls DELETE)" != "0" ]]; then
  ac_fail "AC2a: record list was mutated"
fi
if [[ "$(wildcard_value)" != "198.51.100.7" ]]; then ac_fail "AC2a: * A record changed"; fi
if [[ "$(decoy_count)" != "5" ]]; then ac_fail "AC2a: decoy records not intact (count=$(decoy_count))"; fi
if [[ "$(bad_url_count)" -ne 0 ]]; then ac_fail "AC2a: a stub URL contained self/@/www"; fi
if ! grep -qF "198.51.100.7" "$OUT"; then ac_fail "AC2a: current value not printed"; fi
assert_no_token "tok-caddy-1556"
ac_log "AC2: pass"

# =============================================================================
# AC3: --set-wildcard updates only the * A record (GET + PUT to .../records/%2A/A,
#     new body, decoys intact); AC3b: wrap does not export the key and no CODE
#     line under verbs/ references porter-dns.sh.
# =============================================================================
ac_log "AC3: --set-wildcard updates only the * A record"
ROOT3="$TMP_DIR/root3"
make_root "$ROOT3"
write_token_file "$ROOT3" "etc/caddy/gandi.env" "tok-caddy-1556"
seed_state '{"data":[
  {"id":"rec1","rrset_name":"*","rrset_type":"A","rrset_values":["198.51.100.7"]},
  {"id":"rec2","rrset_name":"@","rrset_type":"A","rrset_values":["198.51.100.1"]},
  {"id":"rec3","rrset_name":"www","rrset_type":"A","rrset_values":["198.51.100.2"]},
  {"id":"rec4","rrset_name":"self","rrset_type":"A","rrset_values":["198.51.100.3"]},
  {"id":"rec5","rrset_name":"ns1","rrset_type":"NS","rrset_values":["ns1.example"]},
  {"id":"rec6","rrset_name":"*","rrset_type":"CNAME","rrset_values":["c.example"]}
]}'
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT3" --set-wildcard
if [[ $rc -ne 0 ]]; then ac_fail "AC3a: --set-wildcard should exit 0 (rc=$rc)"; fi
if [[ "$(n_calls GET)" != "1" ]]; then ac_fail "AC3a: expected exactly one GET"; fi
if [[ "$(n_calls PUT)" != "1" ]]; then ac_fail "AC3a: expected exactly one PUT"; fi
if [[ "$(n_calls POST)" != "0" ]]; then ac_fail "AC3a: a POST was used"; fi
if [[ "$(bad_url_count)" -ne 0 ]]; then ac_fail "AC3a: a stub URL contained self/@/www"; fi
if ! grep -qF 'records/%2A/A' "$CALL_LOG"; then ac_fail "AC3a: PUT must target records/%2A/A"; fi
pb="$(put_body)"
if [[ "$(jq -e --arg ip 203.0.113.10 '.rrset_ttl == 300 and (.rrset_values | length == 1) and .rrset_values[0] == $ip' <<<"$pb" 2>/dev/null)" != "true" ]]; then
  ac_fail "AC3a: PUT body not the * A record"
fi
if [[ "$(wildcard_value)" != "203.0.113.10" ]]; then ac_fail "AC3a: * A record not updated"; fi
if [[ "$(decoy_count)" != "5" ]]; then ac_fail "AC3a: decoy records not intact (count=$(decoy_count))"; fi
assert_no_token "tok-caddy-1556"
ac_log "AC3: pass"

ac_log "AC3b: wrap does not export GANDI_API_KEY / no code reference in verbs/"
# porter-wrap.sh must not export GANDI_API_KEY. Only code counts — the file
# carries a doc comment explaining that the key is deliberately out of the
# allowlist, which is not an export.
if {
  sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]*#.*$//' "$PORTER_WRAP" 2>/dev/null
} | grep -qF 'GANDI_API_KEY'; then
  ac_fail "AC3b: porter-wrap.sh references GANDI_API_KEY in code"
fi
# porter-dns.sh is a root script: no CODE line under verbs/ may reference it.
# Whole-line comments are excluded (approve.sh documents in a comment that it does
# NOT call porter-dns.sh; a mere mention is not a reference).
if {
  for f in "$VERBS_DIR"/*.sh; do
    sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]*#.*$//' "$f" 2>/dev/null
  done
} | grep -qF 'porter-dns.sh'; then
  ac_fail "a file under verbs/ references porter-dns.sh in code (it is a root script)"
fi
ac_log "AC3b: pass"

# =============================================================================
# AC4: matching * A is a no-op (GET only, state byte-for-byte, rc 0).
#     Token fallback: no caddy file -> porter file used. Token priority: both
#     files -> caddy file wins. Token never printed.
# =============================================================================
ac_log "AC4: matching record no-op; token file fallback and priority"

# a) matching: GET only, rc 0, state unchanged byte-for-byte.
ROOT4="$TMP_DIR/root4"
make_root "$ROOT4"
write_token_file "$ROOT4" "etc/caddy/gandi.env" "tok-caddy-1556"
seed_state '{"data":[
  {"id":"rec1","rrset_name":"*","rrset_type":"A","rrset_values":["203.0.113.10"]},
  {"id":"rec2","rrset_name":"@","rrset_type":"A","rrset_values":["198.51.100.1"]},
  {"id":"rec3","rrset_name":"www","rrset_type":"A","rrset_values":["198.51.100.2"]}
]}'
cp "$STATE_FILE" "$TMP_DIR/state-match-before"
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT4"
if [[ $rc -ne 0 ]]; then ac_fail "AC4a: matching record should exit 0 (rc=$rc)"; fi
if [[ "$(n_calls GET)" != "1" ]]; then ac_fail "AC4a: expected exactly one GET"; fi
if [[ "$(n_calls PUT)" != "0" || "$(n_calls POST)" != "0" || "$(n_calls DELETE)" != "0" ]]; then
  ac_fail "AC4a: mutating call on a no-op run"
fi
if ! cmp -s "$STATE_FILE" "$TMP_DIR/state-match-before"; then ac_fail "AC4a: state changed on a no-op run"; fi
assert_no_token "tok-caddy-1556"

# b) token fallback: no caddy file, porter file present -> porter used.
ROOT5="$TMP_DIR/root5"
make_root "$ROOT5"
rm -rf "$ROOT5/etc/caddy"
write_token_file "$ROOT5" "etc/porter/gandi.env" "tok-porter-1556"
seed_state '{"data":[]}'
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT5"
if [[ $rc -ne 0 ]]; then ac_fail "AC4b: create via porter fallback should exit 0 (rc=$rc)"; fi
if [[ "$(jq -s '[.[] | select(.auth == "Authorization: Bearer tok-porter-1556")] | length' "$CALL_LOG")" != "2" ]]; then
  ac_fail "AC4b: porter token file not used"
fi
if [[ "$(wildcard_value)" != "203.0.113.10" ]]; then ac_fail "AC4b: * A record missing after create"; fi
assert_no_token "tok-porter-1556"

# c) token priority: both files present -> caddy file wins.
ROOT6="$TMP_DIR/root6"
make_root "$ROOT6"
write_token_file "$ROOT6" "etc/caddy/gandi.env" "tok-caddy-1556"
write_token_file "$ROOT6" "etc/porter/gandi.env" "tok-porter-1556"
seed_state '{"data":[]}'
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT6"
if [[ $rc -ne 0 ]]; then ac_fail "AC4c: create with both token files should exit 0 (rc=$rc)"; fi
if [[ "$(jq -s '[.[] | select(.auth == "Authorization: Bearer tok-caddy-1556")] | length' "$CALL_LOG")" != "2" ]]; then
  ac_fail "AC4c: caddy token file must take priority (both files present)"
fi
assert_no_token "tok-caddy-1556"
assert_no_token "tok-porter-1556"
ac_log "AC4: pass"

ac_log "AC5: all checks passed"
ac_pass
