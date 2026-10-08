#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1952.sh
#
# Issue #1952: a second healer check restarts the failing layer when a public
# endpoint is down — no human in the loop.
#
# Rule (see bin/healer.sh header): after 3 consecutive failing probes of a URL,
#   - backend UNHEALTHY  -> restart that backend's alloc (forgejo / woodpecker)
#   - backend HEALTHY    -> restart the edge alloc
#   - service UNREGISTERED -> leave to the #1950 service-reregister pass
#   - still down after an edge restart, backend healthy -> record `unfixable`
#     (fault is the Cloudflare tunnel, outside the box) and stop retrying until
#     the URL answers 2xx/3xx again.
#
# Hermetic: curl + nomad stubs on PATH, per-AC temp HEALER_STATE_DIR and
# TAPE_DIR. The Nomad API is served from fixtures ($FAKE_NOMAD_DATA); the two
# public endpoints and the two backend health checks are driven by per-run
# code files in $HEALER_WORK, so each AC is a controlled set of `--once` ticks.
#
# All three services (forgejo, woodpecker, edge) are registered with live
# allocations, so the #1950 service-reregister pass stays idle and the only
# restarts observed are the endpoint ones.
#
# Verifies the four acceptance criteria (per the issue):
#   AC1  /forge/ down 3 ticks, forgejo HEALTHY  -> restart edge (not forgejo)
#   AC2  /forge/ down 3 ticks, forgejo UNHEALTHY -> restart forgejo (not edge)
#   AC3  /forge/ + /ci/ down 3 ticks, forgejo healthy + woodpecker unhealthy
#        -> restart edge AND woodpecker-server (2 restarts <= 3 shared budget)
#   AC4  /forge/ down, forgejo healthy, edge in cooldown (short cooldown)
#        -> record unfixable once, no edge re-restart (fault outside the box)
#
# Run via: tools/run-acceptance.sh 1952
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq flock grep mktemp date

HEALER="$REPO_ROOT/bin/healer.sh"
ac_assert_file "$HEALER" "bin/healer.sh must exist"

grep -qF 'HEALER_PUBLIC_URLS' "$HEALER" \
  || ac_fail "must define HEALER_PUBLIC_URLS"
grep -qF 'HEALER_PUBLIC_FAILURES' "$HEALER" \
  || ac_fail "must define HEALER_PUBLIC_FAILURES"
grep -qF 'HEALER_PROBE_TIMEOUT_SECS' "$HEALER" \
  || ac_fail "must define HEALER_PROBE_TIMEOUT_SECS"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/healer-1952.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

DATA="$WORK/nomad"
BIN="$WORK/bin"
mkdir -p "$DATA" "$BIN"

# ── Curl stub: Nomad API -> fixture body; probe -> exact HTTP code ───────────
cat > "$BIN/curl" <<'EOF'
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
work="${HEALER_WORK:?HEALER_WORK unset}"
printf '%s\n' "$url" >> "$data/urls.log"

# Nomad API -> body
if [[ "$url" == "http://127.0.0.1:4646"* ]]; then
  path="${url#*://}"; path="${path#*/}"; path="${path%%\?*}"
  file=""
  case "$path" in
    v1/agent/health)
      printf '%s\n' '{"client":{"ok":true},"server":{"ok":true}}'
      exit 0
      ;;
    v1/jobs) file="$data/jobs.json" ;;
    v1/services) file="$data/services.json" ;;
    v1/service/forgejo) file="$data/svc-forgejo.json" ;;
    v1/service/woodpecker) file="$data/svc-woodpecker.json" ;;
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

# Probe -> code (2xx/3xx = up; the code is the response, curl "succeeds")
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
if [ -n "$key" ] && [ -f "$work/code-for-$key" ]; then
  printf '%s' "$(cat "$work/code-for-$key")"
else
  printf '%s' "200"
fi
exit 0
EOF
chmod +x "$BIN/curl"

# ── Nomad stub (only alloc restart/exec are exercised) ───────────────────────
cat > "$BIN/nomad" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log="${NOMAD_STUB_LOG:?NOMAD_STUB_LOG unset}"
printf '%s\n' "$*" >> "$log"
case "${1:-} ${2:-}" in
  'alloc restart'|'alloc exec')
    exit 0
    ;;
  *)
    echo "healer-nomad-stub: unexpected: $*" >&2
    exit 9
    ;;
esac
EOF
chmod +x "$BIN/nomad"

# ── Nomad fixtures: all services registered, running, with live allocations ──
jq -n '[{ID:"forgejo",Status:"running",Type:"service"},
       {ID:"woodpecker-server",Status:"running",Type:"service"},
       {ID:"edge",Status:"running",Type:"service"}]' > "$DATA/jobs.json"

jq -n '{ID:"forgejo",TaskGroups:[{Name:"forgejo",Services:[{Name:"forgejo"}],
       Tasks:[{Name:"forgejo",Services:[]}]}]}' > "$DATA/job-forgejo.json"
jq -n '[{ID:"alloc-forgejo",JobID:"forgejo",ClientStatus:"running"}]' > "$DATA/allocs-forgejo.json"

jq -n '{ID:"woodpecker-server",TaskGroups:[{Name:"wp",Services:[{Name:"woodpecker"}],
       Tasks:[{Name:"wp",Services:[]}]}]}' > "$DATA/job-woodpecker-server.json"
jq -n '[{ID:"alloc-woodpecker-server",JobID:"woodpecker-server",ClientStatus:"running"}]' \
  > "$DATA/allocs-woodpecker-server.json"

jq -n '{ID:"edge",TaskGroups:[{Name:"edge",Services:[{Name:"edge"}],
       Tasks:[{Name:"edge",Services:[]}]}]}' > "$DATA/job-edge.json"
jq -n '[{ID:"alloc-edge",JobID:"edge",ClientStatus:"running"}]' > "$DATA/allocs-edge.json"

# Nomad /v1/services returns a top-level array of {Namespace, Services:[...]}.
jq -n '[{Namespace:"default",Services:[{ServiceName:"forgejo",Tags:[]},
       {ServiceName:"woodpecker",Tags:[]},{ServiceName:"edge",Tags:[]}]}]' \
  > "$DATA/services.json"

# service addresses used for the backend health check (127.0.0.1:3000 / 9999)
jq -n '{Services:[{Address:"127.0.0.1:3000"}]}' > "$DATA/svc-forgejo.json"
jq -n '{Services:[{Address:"127.0.0.1:9999"}]}' > "$DATA/svc-woodpecker.json"

# ── helpers ───────────────────────────────────────────────────────────────────
set_code() { printf '%s\n' "$2" > "$WORK/code-for-$1"; }
clear_code() { rm -f "$WORK/code-for-$1"; }
restart_lines() { grep -c '^alloc restart ' "$STUB_LOG" || true; }
restarts_of() { grep -c "alloc restart alloc-$1" "$STUB_LOG" || true; }

# Run exactly N ticks; probe/health codes are fixed for the whole scenario.
# Returns the first non-zero exit code seen. Only truncates $stub_log when
# it does not yet exist, so consecutive run_ticks calls on one log accumulate.
run_ticks() {
  local n="$1" state_dir="$2" tape_dir="$3" stub_log="$4" i rc=0
  mkdir -p "$state_dir" "$tape_dir"
  [ -f "$stub_log" ] || : > "$stub_log"
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    HEALER_WORK="$WORK" \
    PATH="$BIN:$PATH" \
    NOMAD_ADDR="http://127.0.0.1:4646" \
    NOMAD_TIMEOUT=2 \
    HEALER_STATE_DIR="$state_dir" \
    HEALER_INTERVAL_SECS=60 \
    HEALER_COOLDOWN_SECS=1800 \
    HEALER_MAX_RESTARTS=3 \
    HEALER_PUBLIC_URLS="https://self.disinto.ai/forge/ https://self.disinto.ai/ci/" \
    HEALER_PUBLIC_FAILURES=3 \
    HEALER_PROBE_TIMEOUT_SECS=1 \
    TAPE_DIR="$tape_dir" \
    FAKE_NOMAD_DATA="$DATA" \
    NOMAD_STUB_LOG="$stub_log" \
      bash "$HEALER" --once || { rc=$?; break; }
  done
  return "$rc"
}

# ── AC 1: /forge/ down 3 ticks, forgejo healthy -> restart edge, not forgejo ──
ac_log "AC1: /forge/ down 3 ticks, forgejo HEALTHY -> restart edge (not forgejo)"
STATE_DIR="$WORK/st-1"; TAPE_DIR="$WORK/tp-1"; STUB_LOG="$WORK/nm-1.log"
set_code forge 502
set_code forgejo 200
clear_code ci; clear_code woodpecker
rc=0; run_ticks 3 "$STATE_DIR" "$TAPE_DIR" "$STUB_LOG" || rc=$?
ac_assert_eq "$rc" "0" "AC1 exit 0, got $rc"
ac_assert_eq "$(restart_lines)" "1" "AC1 exactly one restart: $(cat "$STUB_LOG")"
ac_assert_eq "$(restarts_of edge)" "1" "AC1 restart is alloc-edge: $(cat "$STUB_LOG")"
ac_assert_eq "$(restarts_of forgejo)" "0" "AC1 must not restart forgejo (backend healthy)"
ac_assert_eq "$(restarts_of woodpecker-server)" "0" "AC1 must not restart woodpecker"

# ── AC 2: /forge/ down 3 ticks, forgejo unhealthy -> restart forgejo ────────
ac_log "AC2: /forge/ down 3 ticks, forgejo UNHEALTHY -> restart forgejo (not edge)"
STATE_DIR="$WORK/st-2"; TAPE_DIR="$WORK/tp-2"; STUB_LOG="$WORK/nm-2.log"
set_code forge 502
set_code forgejo 503
clear_code ci; clear_code woodpecker
rc=0; run_ticks 3 "$STATE_DIR" "$TAPE_DIR" "$STUB_LOG" || rc=$?
ac_assert_eq "$rc" "0" "AC2 exit 0, got $rc"
ac_assert_eq "$(restart_lines)" "1" "AC2 exactly one restart: $(cat "$STUB_LOG")"
ac_assert_eq "$(restarts_of forgejo)" "1" "AC2 restart is alloc-forgejo: $(cat "$STUB_LOG")"
ac_assert_eq "$(restarts_of edge)" "0" "AC2 must not restart edge (backend unhealthy)"
ac_assert_eq "$(restarts_of woodpecker-server)" "0" "AC2 must not restart woodpecker"

# ── AC 3: both down, forgejo healthy + woodpecker unhealthy -> edge + wp ----
ac_log "AC3: /forge/+ /ci/ down 3 ticks (forgejo healthy, woodpecker unhealthy) -> edge + woodpecker-server"
STATE_DIR="$WORK/st-3"; TAPE_DIR="$WORK/tp-3"; STUB_LOG="$WORK/nm-3.log"
set_code forge 502
set_code ci 502
set_code forgejo 200
set_code woodpecker 503
rc=0; run_ticks 3 "$STATE_DIR" "$TAPE_DIR" "$STUB_LOG" || rc=$?
ac_assert_eq "$rc" "0" "AC3 exit 0, got $rc"
ac_assert_eq "$(restarts_of edge)" "1" "AC3 restarts alloc-edge (forge healthy): $(cat "$STUB_LOG")"
ac_assert_eq "$(restarts_of woodpecker-server)" "1" "AC3 restarts alloc-woodpecker-server (ci unhealthy): $(cat "$STUB_LOG")"
ac_assert_eq "$(restart_lines)" "2" "AC3 exactly two restarts (<= 3 budget): $(cat "$STUB_LOG")"
ac_assert_eq "$(restarts_of forgejo)" "0" "AC3 must not restart forgejo (healthy)"

# ── AC 4: edge in cooldown, backend healthy -> unfixable, no edge re-restart ─
ac_log "AC4: /forge/ down, forgejo healthy, edge in cooldown -> unfixable (no re-restart)"
STATE_DIR="$WORK/st-4"; TAPE_DIR="$WORK/tp-4"; STUB_LOG="$WORK/nm-4.log"
set_code forge 502
set_code forgejo 200
clear_code ci; clear_code woodpecker
# Ticks 1-3: streak reaches 3 on tick 3 -> edge restart (cooldown[edge] set).
# Ticks 4-6: URL still down, edge in cooldown, backend healthy -> unfixable
# is recorded once (tick 4) and no further restart is attempted.
rc=0; run_ticks 6 "$STATE_DIR" "$TAPE_DIR" "$STUB_LOG" || rc=$?
ac_assert_eq "$rc" "0" "AC4 exit 0, got $rc"
ac_assert_eq "$(restart_lines)" "1" "AC4 exactly one restart (edge), no re-restart: $(cat "$STUB_LOG")"
ac_assert_eq "$(restarts_of edge)" "1" "AC4 only alloc-edge was restarted: $(cat "$STUB_LOG")"
# state.json must contain the unfixable record for the forge URL
jq -e '(.unfixable // {}) | has("https://self.disinto.ai/forge/")' \
  "$STATE_DIR/state.json" >/dev/null 2>&1 \
  || ac_fail "AC4 state.json must record unfixable for /forge/, got: $(cat "$STATE_DIR/state.json")"
ac_pass
