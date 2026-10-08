#!/usr/bin/env bash
# =============================================================================
# tests/lib/healer-stubs.sh — shared hermetic Nomad stubs for the healer
#
# Sourced by acceptance tests that drive bin/healer.sh against fake curl/nomad
# with no network:
#   issue-1950.sh — the service-reregister pass
#   issue-1952.sh — the public-endpoint pass
#
# The fake implements exactly the surface healer.sh exercises:
#   * curl: routes 127.0.0.1:4646/* to fixture files in $FAKE_NOMAD_DATA and
#     records every request in $FAKE_NOMAD_DATA/urls.log. /v1/agent/health
#     answers ok (exits 22 if $FAKE_NOMAD_DATA/health.fail exists). Any other
#     URL is a probe: the code is taken from $HEALER_WORK/code-for-<key> when
#     present, else 200 (up). Keys: forge, ci, forgejo, woodpecker.
#   * nomad: records every invocation in $NOMAD_STUB_LOG; `alloc restart`
#     exits 0; `alloc exec <alloc> ...` cats $FAKE_NOMAD_DATA/ps-<alloc>.
#
# Globals the test must set before calling ac_healer_stubs / healer_run_once:
#   DATA       — where Nomad fixtures live
#   BIN        — where the fake curl/nomad go (put at the front of PATH)
#   STUB_LOG   — the file the fake nomad records calls to
#   HEALER     — path to the script under test (bin/healer.sh)
# Optional:
#   HEALER_WORK   — dir with per-probe code files (1952 only)
#   HEALER_DRY_RUN  — set to 1 to make the tick a dry run (1950 AC5)
#
# ac_healer_stubs   — writes the fake curl and fake nomad into $BIN.
# ac_healer_init <template> — mktemp, trap, DATA/BIN/HEALER_WORK, stubs.
# ac_healer_public_fixtures — running forgejo, woodpecker-server, edge,
#                             each registered, with health-check addresses.
# healer_run_once <state-dir> <tape-dir> — one `healer.sh --once` tick.
#   Optional overrides (unset = the defaults 1950/1952 rely on):
#     HEALER_TEST_COOLDOWN_SECS, HEALER_TEST_ESCALATE_AFTER_SECS,
#     HEALER_TEST_REMIND_SECS, HEALER_TEST_NOW, HEALER_TEST_NOTIFY_CMD,
#     HEALER_TEST_PUBLIC_URLS (empty is kept: no public probing).
# healer_restart_lines        — count of `alloc restart ` in $STUB_LOG.
# healer_restarts_of <alloc>  — count of restarts of alloc-<alloc>.
# set_probe_code <key> <code> / clear_probe_code <key> — probe code files.
# =============================================================================

# The shared fake curl. A strict superset of each test's original stub: it
# routes the Nomad API (both tests), keeps the /v1/agent/health health.fail
# opt-out (1950), and adds probe-code handling (1952). For 1950 the probe
# branch is never reached (no public endpoints probed) and its /forge/ and
# /ci/ never hit a code file, so they answer 200 and the endpoint pass stays
# idle.
_healer_curl_stub() {
  cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
url=""
for a in "$@"; do
  case "$a" in
    http://*|https://*) url="$a" ;;
  esac
done
[ -n "$url" ] || { echo "healer-curl-stub: no URL" >&2; exit 64; }
data="${FAKE_NOMAD_DATA:?FAKE_NOMAD_DATA unset}"
work="${HEALER_WORK:-}"
printf '%s\n' "$url" >> "$data/urls.log"

# Nomad API -> body.
if [[ "$url" == "http://127.0.0.1:4646"* ]]; then
  path="${url#*://}"; path="${path#*/}"; path="${path%%\?*}"
  file=""
  case "$path" in
    v1/agent/health)
      if [ -f "$data/health.fail" ]; then
        exit 22
      fi
      printf '%s\n' '{"client":{"ok":true},"server":{"ok":true}}'
      exit 0
      ;;
    v1/jobs) file="$data/jobs.json" ;;
    v1/services) file="$data/services.json" ;;
    v1/service/*)
      name="${path#v1/service/}"; file="$data/svc-$name.json" ;;
    v1/job/*/allocations)
      rest="${path#v1/job/}"; job="${rest%%/*}"; file="$data/allocs-$job.json" ;;
    v1/job/*)
      job="${path#v1/job/}"; file="$data/job-$job.json" ;;
    *)
      echo "healer-curl-stub: unexpected nomad path: $path" >&2
      exit 9
      ;;
  esac
  [ -f "$file" ] || { echo "healer-curl-stub: no fixture for $path" >&2; exit 22; }
  cat "$file"
  exit 0
fi

# Probe -> code (2xx/3xx = up; the code is the response, curl "succeeds").
key=""
case "$url" in
  *self.disinto.ai/forge*) key="forge" ;;
  *self.disinto.ai/ci*) key="ci" ;;
  *127.0.0.1:3000*) key="forgejo" ;;
  *127.0.0.1:9999*) key="woodpecker" ;;
  *)
    echo "healer-curl-stub: unexpected probe: $url" >&2
    exit 9
    ;;
esac
if [ -n "$key" ] && [ -n "$work" ] && [ -f "$work/code-for-$key" ]; then
  printf '%s' "$(cat "$work/code-for-$key")"
else
  printf '%s' "200"
fi
exit 0
STUB
  chmod +x "$BIN/curl"
}

# The shared fake nomad. A strict superset of each test's original stub: it
# records every call, and implements `alloc restart` (exit 0) and `alloc exec`
# (cat ps-<alloc>, 1950's in-flight check). 1952 only ever restarts, so its
# behaviour is unchanged.
_healer_nomad_stub() {
  cat > "$BIN/nomad" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
log="${NOMAD_STUB_LOG:?NOMAD_STUB_LOG unset}"
printf '%s\n' "$*" >> "$log"
if [ "${1:-}" = "alloc" ] && [ "${2:-}" = "restart" ]; then
  exit 0
fi
if [ "${1:-}" = "alloc" ] && [ "${2:-}" = "exec" ]; then
  alloc=""
  shift 2
  for a in "$@"; do
    case "$a" in
      -*|sh) ;;
      *) alloc="$a"; break ;;
    esac
  done
  data="${FAKE_NOMAD_DATA:?FAKE_NOMAD_DATA unset}"
  if [ -n "$alloc" ] && [ -f "$data/ps-$alloc" ]; then
    cat "$data/ps-$alloc"
  fi
  exit 0
fi
echo "healer-nomad-stub: unexpected: $*" >&2
exit 9
STUB
  chmod +x "$BIN/nomad"
}

# Writes both stubs into $BIN.
ac_healer_stubs() {
  mkdir -p "$DATA" "$BIN"
  _healer_curl_stub
  _healer_nomad_stub
}

# ac_healer_init TEMPLATE — a temp work dir, the stub PATH, and HEALER_WORK.
# Sets WORK, DATA, BIN. The trap removes WORK on exit.
ac_healer_init() {
  WORK="$(mktemp -d "$1")"
  trap 'rm -rf "$WORK"' EXIT
  DATA="$WORK/nomad"
  BIN="$WORK/bin"
  export HEALER_WORK="$WORK"
  mkdir -p "$DATA" "$BIN"
  ac_healer_stubs
}

# Running forgejo, woodpecker-server and edge, each registered, plus the
# backend addresses the public-endpoint health check curls. Reads $DATA.
ac_healer_public_fixtures() {
  mkdir -p "$DATA"
  jq -n '[{ID:"forgejo",Status:"running",Type:"service"},
         {ID:"woodpecker-server",Status:"running",Type:"service"},
         {ID:"edge",Status:"running",Type:"service"}]' > "$DATA/jobs.json"
  jq -n '{ID:"forgejo",TaskGroups:[{Name:"forgejo",Services:[{Name:"forgejo"}],
         Tasks:[{Name:"forgejo",Services:[]}]}]}' > "$DATA/job-forgejo.json"
  jq -n '[{ID:"alloc-forgejo",JobID:"forgejo",ClientStatus:"running"}]' \
    > "$DATA/allocs-forgejo.json"
  jq -n '{ID:"woodpecker-server",TaskGroups:[{Name:"wp",Services:[{Name:"woodpecker"}],
         Tasks:[{Name:"wp",Services:[]}]}]}' > "$DATA/job-woodpecker-server.json"
  jq -n '[{ID:"alloc-woodpecker-server",JobID:"woodpecker-server",ClientStatus:"running"}]' \
    > "$DATA/allocs-woodpecker-server.json"
  jq -n '{ID:"edge",TaskGroups:[{Name:"edge",Services:[{Name:"edge"}],
         Tasks:[{Name:"edge",Services:[]}]}]}' > "$DATA/job-edge.json"
  jq -n '[{ID:"alloc-edge",JobID:"edge",ClientStatus:"running"}]' \
    > "$DATA/allocs-edge.json"
  jq -n '[{Namespace:"default",Services:[{ServiceName:"forgejo",Tags:[]},
         {ServiceName:"woodpecker",Tags:[]},{ServiceName:"edge",Tags:[]}]}]' \
    > "$DATA/services.json"
  jq -n '{Services:[{Address:"127.0.0.1:3000"}]}' > "$DATA/svc-forgejo.json"
  jq -n '{Services:[{Address:"127.0.0.1:9999"}]}' > "$DATA/svc-woodpecker.json"
}

# One `healer.sh --once` tick. Reads $BIN, $DATA, $HEALER, $STUB_LOG globals.
# $HEALER_WORK / $HEALER_DRY_RUN must be *exported* by the caller; the child
# (and the fake curl it spawns) inherit them — a command-assignment prefix can
# only be literal source text, not the result of a parameter expansion, so the
# vars are passed through the exported environment instead.
# HEALER_TEST_* overrides are for tests that must move the clock or the
# notify command (1955). Unset, the tick matches the 1950/1952 defaults.
healer_run_once() {
  local state_dir="$1" tape_dir="$2"
  local public_urls cooldown escalate remind now_epoch notify_cmd
  cooldown="${HEALER_TEST_COOLDOWN_SECS:-1800}"
  escalate="${HEALER_TEST_ESCALATE_AFTER_SECS:-1800}"
  remind="${HEALER_TEST_REMIND_SECS:-86400}"
  now_epoch="${HEALER_TEST_NOW:-}"
  notify_cmd="${HEALER_TEST_NOTIFY_CMD:-}"
  # Empty is a request for no probing, not "use the default".
  if [ -n "${HEALER_TEST_PUBLIC_URLS+x}" ]; then
    public_urls="$HEALER_TEST_PUBLIC_URLS"
  else
    public_urls="https://self.disinto.ai/forge/ https://self.disinto.ai/ci/"
  fi
  PATH="$BIN:$PATH" \
  NOMAD_ADDR="http://127.0.0.1:4646" \
  NOMAD_TIMEOUT=2 \
  HEALER_STATE_DIR="$state_dir" \
  HEALER_INTERVAL_SECS=60 \
  HEALER_COOLDOWN_SECS="$cooldown" \
  HEALER_ESCALATE_AFTER_SECS="$escalate" \
  HEALER_REMIND_SECS="$remind" \
  HEALER_NOW="$now_epoch" \
  HEALER_NOTIFY_CMD="$notify_cmd" \
  HEALER_PUBLIC_URLS="$public_urls" \
  HEALER_PUBLIC_FAILURES=3 \
  HEALER_PROBE_TIMEOUT_SECS=1 \
  TAPE_DIR="$tape_dir" \
  FAKE_NOMAD_DATA="$DATA" \
  NOMAD_STUB_LOG="$STUB_LOG" \
    bash "$HEALER" --once
}

healer_restart_lines() {
  grep -c '^alloc restart ' "$STUB_LOG" || true
}

healer_restarts_of() {
  grep -c "alloc restart alloc-$1" "$STUB_LOG" || true
}

# Probe code helpers (1952; a no-op when HEALER_WORK is unset, 1950).
set_probe_code() {
  [ -n "${HEALER_WORK:-}" ] || return 1
  printf '%s\n' "$2" > "$HEALER_WORK/code-for-$1"
}

clear_probe_code() {
  [ -n "${HEALER_WORK:-}" ] || return 1
  rm -f "$HEALER_WORK/code-for-$1"
}