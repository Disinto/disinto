#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1278-nomad-service-registrations.sh
#
# Issue #1278: during the 2026-09-08 outage the `forgejo` service vanished
# from Nomad's service registry while the forgejo alloc stayed running —
# task health read success, nomadService "forgejo" resolved nothing, clients
# rendered an empty FORGE_URL and crash-looped. Only the registry knew. The
# factory walk now gates on Nomad service registration presence
# (bin/factory-walk.sh, service-registration section): for each service the
# templates discover via nomadService (default: forgejo, woodpecker) it
# queries GET /v1/service/<name> and pages the walk queue when the service
# has zero registrations while its owning job still has a running alloc.
#
# This test stubs the Nomad API response with a fake `curl` on PATH
# (responses are driven by files in a temp data dir) and drives
# bin/factory-walk.sh against a temp walk-queue dir:
#   1. all services registered                -> no walk-queue item
#   2. forgejo deregistered, job running      -> exactly one walk-queue item
#                                                 (alert within one walk interval)
#   3. forgejo deregistered, job stopped      -> no walk-queue item
#                                                 (intentional stop is not a
#                                                 registration loss)
#   4. forgejo re-registered (recovery)       -> no new walk-queue item
#   5. forgejo absent from the registry (HTTP 404),
#      job running                            -> pages (a 404 is zero regs)
#   6. woodpecker deregistered, job running   -> pages, item names the
#                                                 woodpecker-server job
#
# Read-only with respect to live systems: all state lives in a temp dir, the
# fake curl never touches the real Nomad API, the live walk queue, or the
# restart-gate state dir.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq
ac_require_cmd find

GATE="$REPO_ROOT/bin/factory-walk.sh"
ac_assert_file "$GATE" "bin/factory-walk.sh must exist"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Fake curl ────────────────────────────────────────────────────────────────
# Emulates the curl invocation the gate uses:
#   curl -sS --max-time N [-H HDR] -o <body-file> -w '%{http_code}' <url>
# The body is written to the -o file (if given), the HTTP status code is
# printed to stdout. Responses come from $FAKE_NOMAD_DATA:
#   svc-<service>.json / svc-<service>.status  — /v1/service/<service>
#   allocs-<job>.json                          — /v1/job/<job>/allocations
cat > "$TMP/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
args=("$@")
n=${#args[@]}
i=0
while [ "$i" -lt "$n" ]; do
  a="${args[i]}"
  case "$a" in
    -o) i=$((i+1)); out="${args[i]}" ;;
    --max-time|-H|-w) i=$((i+1)) ;;
    http*|*://*) url="$a" ;;
  esac
  i=$((i+1))
done
[ -n "$url" ] || { echo "fake-curl: no URL in args" >&2; exit 64; }
path="${url#*://}"
path="${path#*/}"
data="${FAKE_NOMAD_DATA:?FAKE_NOMAD_DATA unset}"
body=""
code=200
case "$path" in
  v1/service/*)
    name="${path#v1/service/}"; name="${name%%\?*}"
    f="$data/svc-$name.json"
    [ -f "$f" ] && body="$(cat "$f")"
    sf="$data/svc-$name.status"
    [ -f "$sf" ] && code="$(cat "$sf")"
    ;;
  v1/job/*/allocations*)
    rest="${path#v1/job/}"; job="${rest%%/*}"
    f="$data/allocs-$job.json"
    [ -f "$f" ] && body="$(cat "$f")"
    ;;
  *)
    echo "fake-curl: unexpected path: $path" >&2
    exit 9
    ;;
esac
if [ -n "$out" ]; then
  printf '%s' "$body" > "$out"
fi
printf '%s' "$code"
EOF
chmod +x "$TMP/curl"

DATA="$TMP/data"
mkdir -p "$DATA"

# Fixture helpers — one line of JSON per file; overwrite to flip a scenario.
present() { printf '[{"ID":"reg-%s","Name":"%s"}]' "$1" "$1" > "$DATA/svc-$1.json"; }
absent() { printf '[]' > "$DATA/svc-$1.json"; }
running_alloc() { printf '[{"ID":"%s","JobID":"%s","ClientStatus":"running"}]' "$2" "$1" > "$DATA/allocs-$1.json"; }
no_allocs() { printf '[]' > "$DATA/allocs-$1.json"; }
present forgejo
present woodpecker
no_allocs forgejo
no_allocs woodpecker-server

# run_walk — one walk interval: run the gate against the fake Nomad API with
# temp state/queue dirs. The restart gate is neutralized (NOMAD_BIN missing)
# so only the service gate can page; its queue items are the ones asserted.
run_walk() {
  PATH="$TMP:$PATH" \
  WALK_STATE_DIR="$TMP/state" \
  WALK_QUEUE_DIR="$TMP/queue" \
  NOMAD_BIN=definitely-missing-nomad \
  NOMAD_ADDR="http://fake.nomad:4646" \
  FAKE_NOMAD_DATA="$DATA" \
    bash "$GATE"
}

# queue_count — number of walk-queue item files so far.
queue_count() {
  local n=0
  if [ -d "$TMP/queue" ]; then
    n="$(find "$TMP/queue" -maxdepth 1 -type f | wc -l)"
  fi
  printf '%s' "$n" | tr -d '[:space:]'
}

# ── 1. All services registered: nothing paged ───────────────────────────────
out="$(run_walk)"
ac_assert_eq "$(queue_count)" "0" \
  "all services registered must page nothing"
grep -q 'WALK-OK service=forgejo registrations=1' <<< "$out" \
  || ac_fail "expected WALK-OK for forgejo with a registration"
grep -q 'WALK-OK service=woodpecker registrations=1' <<< "$out" \
  || ac_fail "expected WALK-OK for woodpecker with a registration"
grep -q 'service-registration gate OK' <<< "$out" \
  || ac_fail "expected a service-registration gate OK summary line"

# ── 2. forgejo deregistered while its alloc runs: page within one walk ──────
absent forgejo
running_alloc forgejo f00d000000000000
run_walk >/dev/null
ac_assert_eq "$(queue_count)" "1" \
  "deregistered forgejo with a running alloc must page within one walk interval"
item="$(find "$TMP/queue" -maxdepth 1 -type f | head -n 1)"
[ -n "$item" ] || ac_fail "no walk-queue item file found after deregistration"
grep -q 'service:      forgejo' "$item" \
  || ac_fail "walk-queue item must name the service (forgejo)"
grep -q 'job:          forgejo' "$item" \
  || ac_fail "walk-queue item must name the owning job (forgejo)"
grep -q 'registrations: 0' "$item" \
  || ac_fail "walk-queue item must record zero registrations"
grep -q 'f00d000000000000' "$item" \
  || ac_fail "walk-queue item must reference the running alloc id"
grep -q 'alloc restart f00d000000000000' "$item" \
  || ac_fail "remedy must stay manual: item must say 'nomad alloc restart <alloc>'"

# ── 3. forgejo deregistered but job stopped: no false page ──────────────────
no_allocs forgejo
run_walk >/dev/null
ac_assert_eq "$(queue_count)" "1" \
  "deregistered service with no running alloc (job stopped) must not page"

# ── 4. Recovery: re-registered, no new page ─────────────────────────────────
present forgejo
run_walk >/dev/null
ac_assert_eq "$(queue_count)" "1" \
  "a re-registered service must page nothing new"

# ── 5. Service absent from the registry (HTTP 404), job running: page ───────
absent forgejo
echo 404 > "$DATA/svc-forgejo.status"
running_alloc forgejo f00d000000000001
run_walk >/dev/null
ac_assert_eq "$(queue_count)" "2" \
  "an HTTP 404 from /v1/service/<name> is zero registrations and must page"
rm -f "$DATA/svc-forgejo.status"

# ── 6. woodpecker deregistered: page names the woodpecker-server job ────────
present forgejo   # restore scenario 5's deregistration, so only woodpecker pages
absent woodpecker
running_alloc woodpecker-server w00d000000000000
run_walk >/dev/null
ac_assert_eq "$(queue_count)" "3" \
  "deregistered woodpecker with a running alloc must page"
item="$(find "$TMP/queue" -maxdepth 1 -type f | grep woodpecker | head -n 1)"
[ -n "$item" ] || ac_fail "no walk-queue item for woodpecker found"
grep -q 'service:      woodpecker' "$item" \
  || ac_fail "walk-queue item must name the service (woodpecker)"
grep -q 'job:          woodpecker-server' "$item" \
  || ac_fail "walk-queue item must name the owning job (woodpecker-server)"

ac_pass
