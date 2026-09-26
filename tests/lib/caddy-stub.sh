#!/usr/bin/env bash
# =============================================================================
# tests/lib/caddy-stub.sh — shared stateful curl stub for the Caddy admin API
#
# Sourced by acceptance tests that drive the edge-control Caddy helpers
# (tools/edge-control/lib/caddy.sh) against a fake Caddy admin listener, with
# no network:
#   issue-1555.sh — porter-caddy.sh (add_route / remove_route)
#   issue-1558.sh — approve.sh + lib/apply-name.sh (edge approve side-effects)
#
# ac_caddy_stub — installs a fake `curl` at $TMP_DIR/stub/curl (used by
# putting $STUB_DIR at the front of PATH), sets the globals STATE / LOG that
# the test's assertions read, and the CADDY_STUB_STATE / CADDY_STUB_LOG env
# vars the fake reads. The fake implements exactly the admin endpoints
# lib/caddy.sh uses:
#   GET  /config/apps/http/servers
#   POST /config/apps/http/servers/<srv>/routes
#   GET  /config/apps/http/servers/<srv>/routes
#   POST /config/apps/http/servers/<srv>/routes/<n>   (remove by index)
# Every call is recorded to $LOG as a JSONL object
# {method, url, path, body} so ACs can assert request shape with no network.
#
# Opt-in failure mode: if a test sets AC_STUB_FAIL_POST=1, POSTs to the routes
# endpoint exit 1 without a response — a "dead Caddy" for the apply-failed AC
# (issue-1558.sh AC2). No-op when unset.
# =============================================================================

ac_caddy_stub() {
  STUB_DIR="$TMP_DIR/stub"
  STATE="$TMP_DIR/caddy-state.json"
  LOG="$TMP_DIR/caddy-calls.jsonl"
  : > "$LOG"
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
# AC_STUB_FAIL_POST=1 makes the routes POST exit 1 with no response (a "dead
# Caddy" for apply-failed ACs — issue-1558.sh AC2; no-op when unset).
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
}
