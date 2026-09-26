#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1556.sh
#
# Issue #1556: feat(edge): ensure the wildcard A record once and never edit
# other names
#
# Exercises tools/edge-control/porter-dns.sh (a root script, NOT a verb)
# against a stateful Gandi LiveDNS v5 curl stub — no network, no real
# registrar. The stub records every call as
# {method,url,auth,body} in a JSONL log and holds the zone in a JSON
# state file ({data:[{id,name,type,value}]}), so the test can assert which
# record was created/updated and that no other name was touched.
#
# Contract under test (#1556):
#   * AC1 a missing * A record creates only that record: exactly one POST to
#     domains/disinto.ai/records with body {name:"*",type:"A",value:$IP};
#     no stub URL ever contains self, @, or www.
#   * AC2 an existing * A record with a different IP is left unchanged
#     (GET only, rc!=0, current value printed, token never printed) unless
#     --set-wildcard is passed (GET + one PUT to records/<id>, no POST).
#   * AC3 porter-wrap.sh still does not export GANDI_API_KEY, and no file
#     under verbs/ references porter-dns.sh.
#   * AC4 stdout and stderr of successful runs never contain the token
#     (and the ledger at the prefixed path is untouched).
#   * AC5 the test exits 0 and calls ac_pass.
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

ac_require_cmd bash jq grep cmp mktemp rm cat printf chmod head
ac_require_cmd mktemp

DNS_SCRIPT="$REPO_ROOT/tools/edge-control/porter-dns.sh"
WRAP_SCRIPT="$REPO_ROOT/tools/edge-control/porter-wrap.sh"
VERBS_DIR="$REPO_ROOT/tools/edge-control/verbs"

ac_assert_file "$DNS_SCRIPT" "tools/edge-control/porter-dns.sh is missing"
ac_assert_file "$WRAP_SCRIPT" "tools/edge-control/porter-wrap.sh is missing"

# ── Source-level wiring checks ───────────────────────────────────────────────

# porter-dns.sh is a root script: no file under verbs/ may reference it.
if grep -RqF 'porter-dns.sh' "$VERBS_DIR" 2>/dev/null; then
  ac_fail "a file under verbs/ references porter-dns.sh (it is a root script)"
fi

# porter-wrap.sh must NOT export the registrar token: no single line may pair
# GANDI_API_KEY with an export (the allowlist export is the generic
# `export "$key=$value"`). The clarifying comment is deliberately kept on
# lines that do not pair the two words.
if grep -F 'GANDI_API_KEY' "$WRAP_SCRIPT" | grep -qF 'export'; then
  ac_fail "porter-wrap.sh exports GANDI_API_KEY"
fi

# porter-dns.sh must never reference the Caddy configuration or the ledger
# (the token is never written to either).
if grep -qE 'Caddyfile|accounts\.json' "$DNS_SCRIPT"; then
  ac_fail "porter-dns.sh references the Caddy config or the ledger"
fi

# ── Stateful Gandi LiveDNS v5 curl stub ──────────────────────────────────────
TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1556.XXXXXX)"
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
# Fake Gandi LiveDNS v5 endpoint. State lives in GANDI_STUB_STATE ({"data":
# [{id,name,type,value},...]}); every request appends {method,url,auth,body}
# to GANDI_STUB_LOG.
set -u
STATE_FILE="${GANDI_STUB_STATE:?GANDI_STUB_STATE not set}"
CALL_LOG="${GANDI_STUB_LOG:?GANDI_STUB_LOG not set}"
url=""
method="GET"
body=""
auth=""
prev=""
# Parse curl-style args: -X METHOD, -H HEADER, -d BODY, -f|-s|-S (valueless),
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
    -f|-s|-S) : ;;
    https://*) url="$arg" ;;
  esac
done
# jq -n (the log line) never reads stdin. The body parse reads from a pipe,
# and jq -c on a pipe with an empty body yields nothing, so default to the
# JSON null (valid for --argjson) when there is no body.
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
    case "$method" in
      POST)
        next_num="$(jq -r '.data | length' "$STATE_FILE" 2>/dev/null || echo 0)"
        next_num=$((next_num + 1))
        tmp="${STATE_FILE}.tmp.$$"
        if jq -c --argjson b "$b" --arg id "rec${next_num}" \
            '.data = (.data + [ {id: $id, name: $b.name, type: $b.type, value: $b.value} ])' \
            "$STATE_FILE" > "$tmp" 2>/dev/null; then
          mv "$tmp" "$STATE_FILE"
          cat "$STATE_FILE"
        else
          rm -f "$tmp"
          printf '{"error":"stub state update failed"}'
        fi
        ;;
      *)
        cat "$STATE_FILE"
        ;;
    esac
    ;;
  */domains/*/records/*)
    tmp="${STATE_FILE}.tmp.$$"
    if [[ "$method" == "PUT" ]] && [[ -n "$body" ]]; then
      id="${path##*/}"
      if jq -c --argjson b "$b" --arg id "$id" \
          '.data = (.data | map(if .id == $id then {id: $id, name: $b.name, type: $b.type, value: $b.value} else . end))' \
          "$STATE_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$STATE_FILE"
        cat "$STATE_FILE"
      else
        rm -f "$tmp"
        printf '{"error":"stub put failed"}'
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
  printf '{"version":1,"accounts":{}}' > "$root/var/lib/disinto/accounts.json"
}

# <root> <rel> <token> [mode=600] where rel is e.g. etc/caddy/gandi.env
write_token_file() {
  local root="$1" rel="$2" token="$3" mode="${4:-600}"
  printf 'GANDI_API_KEY=%s\n' "$token" > "${root}/${rel}"
  chmod "$mode" "${root}/${rel}"
}

# jq program (object) for the zone state file.
seed_state() {
  jq -nc "$1" > "$STATE_FILE"
  # -n: pure jq literal emits nothing with no input; null input writes it once.
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
  jq -s "[.[] | select(.method == \"${1}\")] | length" "$CALL_LOG"
}
url_set() {
  jq -rs 'map(.url) | unique' "$CALL_LOG"
}
first_url() {
  jq -sr 'first(.[] | .url)' "$CALL_LOG"
}
# Wildcard A record value in the stub state ("" if absent).
wildcard_value() {
  jq -r '[.data[]? | select(.type == "A" and .name == "*")] | .[0].value // empty' "$STATE_FILE" 2>/dev/null || printf ''
}
# Count of decoy records that must survive (CNAME *, apex, www, self, NS).
decoy_count() {
  jq -r '[.data[]? | select((.name == "*" and .type == "CNAME") or (.name == "@") or (.name == "www") or (.name == "self") or (.name == "ns1"))] | length' "$STATE_FILE"
}
bad_url_count() {
  jq -rs '[.[] | select(.url | test("self|www|@"))] | length' "$CALL_LOG"
}
assert_no_token() {  # <token> — token must never appear in OUT/ERR
  local token="$1"
  if [[ "$OUT" == *"$token"* || "$ERR" == *"$token"* ]]; then
    ac_fail "run output leaked the token $token"
  fi
}

# ── AC1. missing * A record -> exactly one POST, nothing else touched ─────────
ac_log "AC1: missing * A record creates only that record"

ROOT1="$TMP_DIR/root1"
make_root "$ROOT1"
write_token_file "$ROOT1" "etc/caddy/gandi.env" "tok-caddy-1556"
seed_state '{data: []}'
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT1"
if [[ $rc -ne 0 ]]; then
  ac_fail "AC1a: create should exit 0 (rc=$rc, out=$(head -c 120 "$OUT" 2>/dev/null), err=$(head -c 120 "$ERR" 2>/dev/null))"
fi
if [[ "$(n_calls GET)" != "1" ]]; then
  ac_fail "AC1a: expected exactly one GET, got $(n_calls GET)"
fi
if [[ "$(n_calls POST)" != "1" ]]; then
  ac_fail "AC1a: expected exactly one POST, got $(n_calls POST)"
fi
if [[ "$(n_calls PUT)" != "0" || $(n_calls DELETE) -ne 0 ]]; then
  ac_fail "AC1a: a PUT or DELETE was used when creating the record"
fi
if [[ "$(bad_url_count)" -ne 0 ]]; then
  ac_fail "AC1a: a stub URL contains self, @, or www: $(url_set | tr '\n' ' ')"
fi
if ! jq -e 'select(.method == "POST") | .body.name == "*" and .body.type == "A" and .body.value == "203.0.113.10"' "$CALL_LOG" >/dev/null 2>&1; then
  ac_fail "AC1a: POST body must be name=* type=A value=203.0.113.10"
fi
if [[ "$(first_url)" != "https://api.gandi.net/v5/domains/disinto.ai/records" ]]; then
  ac_fail "AC1a: first URL is not the records list URL: $(first_url)"
fi
if [[ "$(wildcard_value)" != "203.0.113.10" ]]; then
  ac_fail "AC1a: * A record not created with expected value (got: $(wildcard_value))"
fi
if [[ "$(jq -r '.data | length' "$STATE_FILE")" != "1" ]]; then
  ac_fail "AC1a: more than one record in the zone after create"
fi
if [[ "$(jq -s '[.[] | select(.auth == "Authorization: Bearer tok-caddy-1556")] | length' "$CALL_LOG")" != "2" ]]; then
  ac_fail "AC1a: caddy token file not used (auth header mismatch)"
fi
if ! cmp -s "$ROOT1/var/lib/disinto/accounts.json" <(printf '{"version":1,"accounts":{}}'); then
  ac_fail "AC1a: ledger at the prefixed path was modified by a successful run"
fi
assert_no_token "tok-caddy-1556"
ac_log "AC1: missing record created exactly once; no other name or path touched"

# ── AC2. present * A record with a different IP, no flag -> refused ───────────
ac_log "AC2: different IP without --set-wildcard is left unchanged"

ROOT2="$TMP_DIR/root2"
make_root "$ROOT2"
write_token_file "$ROOT2" "etc/caddy/gandi.env" "tok-caddy-1556"
seed_state '{data: [
  {id: "rec1", name: "*",  type: "A", value: "198.51.100.7"},
  {id: "rec2", name: "@",  type: "A", value: "198.51.100.1"},
  {id: "rec3", name: "www", type: "A", value: "198.51.100.2"},
  {id: "rec4", name: "self", type: "A", value: "198.51.100.3"},
  {id: "rec5", name: "ns1", type: "NS", value: "ns1.example"},
  {id: "rec6", name: "*",  type: "CNAME", value: "c.example"}
]}'
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT2"
if [[ $rc -eq 0 ]]; then
  ac_fail "AC2a: differing value without --set-wildcard must exit non-zero"
fi
if [[ "$(n_calls GET)" != "1" ]]; then
  ac_fail "AC2a: expected exactly one GET, got $(n_calls GET)"
fi
if [[ "$(n_calls POST)" != "0" || $(n_calls PUT) -ne 0 || $(n_calls DELETE) -ne 0 ]]; then
  ac_fail "AC2a: record list was mutated (POST/PUT/DELETE) when value differed"
fi
if [[ "$(wildcard_value)" != "198.51.100.7" ]]; then
  ac_fail "AC2a: * A record changed (now: $(wildcard_value))"
fi
if [[ "$(decoy_count)" != "5" ]]; then
  ac_fail "AC2a: decoy records (@, www, self, NS, CNAME) not intact (count=$(decoy_count))"
fi
if [[ "$(bad_url_count)" -ne 0 ]]; then
  ac_fail "AC2a: a stub URL contains self, @, or www"
fi
if ! grep -qF "198.51.100.7" "$OUT"; then
  ac_fail "AC2a: current value (198.51.100.7) not printed on refusal"
fi
assert_no_token "tok-caddy-1556"
ac_log "AC2: differing value refused; record and decoys untouched; current value printed"

# ── AC3. --set-wildcard updates only that record ──────────────────────────────
ac_log "AC3: --set-wildcard updates only the * A record"

ROOT3="$TMP_DIR/root3"
make_root "$ROOT3"
write_token_file "$ROOT3" "etc/caddy/gandi.env" "tok-caddy-1556"
seed_state '{data: [
  {id: "rec1", name: "*",  type: "A", value: "198.51.100.7"},
  {id: "rec2", name: "@",  type: "A", value: "198.51.100.1"},
  {id: "rec3", name: "www", type: "A", value: "198.51.100.2"},
  {id: "rec4", name: "self", type: "A", value: "198.51.100.3"},
  {id: "rec5", name: "ns1", type: "NS", value: "ns1.example"},
  {id: "rec6", name: "*",  type: "CNAME", value: "c.example"}
]}'
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT3" --set-wildcard
if [[ $rc -ne 0 ]]; then
  ac_fail "AC3a: --set-wildcard update should exit 0 (rc=$rc)"
fi
if [[ "$(n_calls GET)" != "1" ]]; then
  ac_fail "AC3a: expected exactly one GET, got $(n_calls GET)"
fi
if [[ "$(n_calls PUT)" != "1" ]]; then
  ac_fail "AC3a: expected exactly one PUT, got $(n_calls PUT)"
fi
if [[ "$(n_calls POST)" != "0" ]]; then
  ac_fail "AC3a: a POST was used when updating (must PUT the existing record)"
fi
if [[ "$(bad_url_count)" -ne 0 ]]; then
  ac_fail "AC3a: a stub URL contains self, @, or www"
fi
if ! jq -e 'select(.method == "PUT") | .url == "https://api.gandi.net/v5/domains/disinto.ai/records/rec1" and .body.name == "*" and .body.type == "A" and .body.value == "203.0.113.10"' "$CALL_LOG" >/dev/null 2>&1; then
  ac_fail "AC3a: PUT must target records/rec1 with the new value"
fi
if [[ "$(wildcard_value)" != "203.0.113.10" ]]; then
  ac_fail "AC3a: * A record not updated (now: $(wildcard_value))"
fi
if [[ "$(decoy_count)" != "5" ]]; then
  ac_fail "AC3a: decoy records not intact after update (count=$(decoy_count))"
fi
assert_no_token "tok-caddy-1556"
ac_log "AC3: --set-wildcard PUT only the * record; decoys untouched"

# ── AC4. no-op when the record already matches; token-file fallback and
#     priority; no ledger/secret side effects ─────────────────────────────────
ac_log "AC4: matching record is a no-op; token file resolution checks"

# a) Matching record: GET only, rc 0, state byte-for-byte.
ROOT4="$TMP_DIR/root4"
make_root "$ROOT4"
write_token_file "$ROOT4" "etc/caddy/gandi.env" "tok-caddy-1556"
seed_state '{data: [
  {id: "rec1", name: "*",  type: "A", value: "203.0.113.10"},
  {id: "rec2", name: "@",  type: "A", value: "198.51.100.1"},
  {id: "rec3", name: "www", type: "A", value: "198.51.100.2"}
]}'
cp "$STATE_FILE" "$TMP_DIR/state-match-before"
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT4"
if [[ $rc -ne 0 ]]; then
  ac_fail "AC4a: matching record should exit 0 (rc=$rc)"
fi
if [[ "$(n_calls GET)" != "1" ]]; then
  ac_fail "AC4a: expected exactly one GET, got $(n_calls GET)"
fi
if [[ "$(n_calls POST)" != "0" || $(n_calls PUT) -ne 0 || $(n_calls DELETE) -ne 0 ]]; then
  ac_fail "AC4a: mutating call when the record already matches"
fi
if ! cmp -s "$STATE_FILE" "$TMP_DIR/state-match-before"; then
  ac_fail "AC4a: state file changed on a no-op run"
fi
assert_no_token "tok-caddy-1556"

# b) Token fallback: no caddy file, porter file exists -> porter token used.
ROOT5="$TMP_DIR/root5"
make_root "$ROOT5"
rm -rf "$ROOT5/etc/caddy"
write_token_file "$ROOT5" "etc/porter/gandi.env" "tok-porter-1556"
seed_state '{data: []}'
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT5"
if [[ $rc -ne 0 ]]; then
  ac_fail "AC4b: create via porter token file should exit 0 (rc=$rc)"
fi
if [[ "$(jq -s '[.[] | select(.auth == "Authorization: Bearer tok-porter-1556")] | length' "$CALL_LOG")" != "2" ]]; then
  ac_fail "AC4b: porter token file not used (auth header mismatch)"
fi
if [[ "$(wildcard_value)" != "203.0.113.10" ]]; then
  ac_fail "AC4b: * A record missing after create via porter token"
fi
assert_no_token "tok-porter-1556"

# c) Both files present: caddy file must take priority.
ROOT6="$TMP_DIR/root6"
make_root "$ROOT6"
write_token_file "$ROOT6" "etc/caddy/gandi.env" "tok-caddy-1556"
write_token_file "$ROOT6" "etc/porter/gandi.env" "tok-porter-1556"
seed_state '{data: []}'
PORTER_PUBLIC_IP="203.0.113.10"
run_dns "$ROOT6"
if [[ $rc -ne 0 ]]; then
  ac_fail "AC4c: create with both token files should exit 0 (rc=$rc)"
fi
if [[ "$(jq -s '[.[] | select(.auth == "Authorization: Bearer tok-caddy-1556")] | length' "$CALL_LOG")" != "2" ]]; then
  ac_fail "AC4c: caddy token file must take priority over porter file"
fi
assert_no_token "tok-caddy-1556"
assert_no_token "tok-porter-1556"

ac_log "AC4: matching record is a no-op; caddy file takes priority; porter file is the fallback"

# ── AC5. all acceptance criteria passed ───────────────────────────────────────
ac_log "AC5: all checks passed"
ac_pass
