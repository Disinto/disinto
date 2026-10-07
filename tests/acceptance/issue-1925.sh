#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1925.sh
#
# Issue #1925: the nomad collector alerts when a running job's service is
# not registered.
#
# Hermetic: a curl stub serves /v1/jobs, /v1/allocations, /v1/services and
# /v1/job/<ID>. No Nomad, no network. State is a temp SNAPSHOT_PATH.
#
#   1. forgejo declares service forgejo; /v1/services lists only edge →
#      alerts contain "service forgejo of job forgejo not registered".
#   2. Every declared service is registered → no alert matches
#      ^service .* not registered$.
#   3. .collectors.nomad.ts is set and parses as %Y-%m-%dT%H:%M:%SZ.
#   4. /v1/services failing leaves the other alerts as today and adds none.
#
# Run via: tools/run-acceptance.sh 1925
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep mktemp date

COLLECTOR="$REPO_ROOT/bin/snapshot-nomad.sh"
ac_assert_file "$COLLECTOR" "bin/snapshot-nomad.sh must exist"

# Header is the documentation for this collector.
grep -qF '{"nomad":{"ts":"...","jobs":[...],"alerts":[...]}}' "$COLLECTOR" \
  || ac_fail "header Output shape must be {\"nomad\":{\"ts\":\"...\",\"jobs\":[...],\"alerts\":[...]}}"
grep -qF 'service <name> of job <ID> not registered' "$COLLECTOR" \
  || ac_fail "header must name the service-not-registered alert"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DATA="$TMP/data"
BIN="$TMP/bin"
STATE="$TMP/state.json"
mkdir -p "$DATA" "$BIN"

# ── Curl stub ────────────────────────────────────────────────────────────────
# Same invocation the collector uses:
#   curl -fsS --max-time N -H "X-Nomad-Token: …" <url>
# Body from $FAKE_NOMAD_DATA. /v1/services exits 22 when services.fail exists.
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
saw_fsS=0
saw_max_time=0
saw_token=0
args=("$@")
n=${#args[@]}
i=0
while [ "$i" -lt "$n" ]; do
  a="${args[$i]}"
  case "$a" in
    -fsS) saw_fsS=1 ;;
    --max-time) saw_max_time=1; i=$((i + 1)) ;;
    -H)
      i=$((i + 1))
      case "${args[$i]}" in
        X-Nomad-Token:*) saw_token=1 ;;
      esac
      ;;
    http://*|https://*) url="$a" ;;
  esac
  i=$((i + 1))
done
[ "$saw_fsS" -eq 1 ] || { echo "fake-curl: missing -fsS" >&2; exit 64; }
[ "$saw_max_time" -eq 1 ] || { echo "fake-curl: missing --max-time" >&2; exit 64; }
[ "$saw_token" -eq 1 ] || { echo "fake-curl: missing X-Nomad-Token" >&2; exit 64; }
[ -n "$url" ] || { echo "fake-curl: no URL" >&2; exit 64; }
path="${url#*://}"
path="${path#*/}"
path="${path%%\?*}"
data="${FAKE_NOMAD_DATA:?FAKE_NOMAD_DATA unset}"
printf '%s\n' "$path" >> "$data/requests.log"
file=""
case "$path" in
  v1/jobs) file="$data/jobs.json" ;;
  v1/allocations) file="$data/allocations.json" ;;
  v1/services)
    if [ -f "$data/services.fail" ]; then
      exit 22
    fi
    file="$data/services.json"
    ;;
  v1/job/*)
    id="${path#v1/job/}"
    file="$data/job-$id.json"
    ;;
  *)
    echo "fake-curl: unexpected path: $path" >&2
    exit 9
    ;;
esac
[ -f "$file" ] || { echo "fake-curl: no fixture for $path" >&2; exit 22; }
cat "$file"
EOF
chmod +x "$BIN/curl"

# Jobs: forgejo running (service), nightly running (batch — must not alert),
# stale dead long enough for the existing "job <ID> dead" alert.
# Alloc: restart count > 3, so the existing restart alert is present too.
cat > "$DATA/jobs.json" <<'EOF'
[
  {"ID":"forgejo","Name":"forgejo","Status":"running","Type":"service","SubmitTime":1},
  {"ID":"nightly","Name":"nightly","Status":"running","Type":"batch","SubmitTime":1},
  {"ID":"stale","Name":"stale","Status":"dead","Type":"service","SubmitTime":1}
]
EOF
cat > "$DATA/allocations.json" <<'EOF'
[
  {"ID":"cafebabe","JobID":"stale","ClientStatus":"failed","RestartCount":4},
  {"ID":"f00d","JobID":"forgejo","ClientStatus":"running","RestartCount":0}
]
EOF
# Group-level forgejo (the outage) and a task-level name, so both declaration
# paths are exercised. nightly is served in case a batch job is fetched.
cat > "$DATA/job-forgejo.json" <<'EOF'
{
  "ID": "forgejo",
  "TaskGroups": [
    {
      "Name": "forgejo",
      "Services": [{"Name": "forgejo", "PortLabel": "http"}],
      "Tasks": [
        {
          "Name": "forgejo",
          "Services": [{"Name": "forgejo-metrics"}]
        }
      ]
    }
  ]
}
EOF
cat > "$DATA/job-nightly.json" <<'EOF'
{"ID":"nightly","TaskGroups":[{"Services":[{"Name":"nightly"}],"Tasks":[]}]}
EOF

write_services() {
  # $1 is a JSON array of ServiceName strings.
  jq -n --argjson names "$1" '[{Namespace: "default", Services: [$names[] | {ServiceName: ., Tags: []}]}]' \
    > "$DATA/services.json"
}

printf '%s\n' '{"version":1,"ts":"2020-01-01T00:00:00Z","collectors":{}}' > "$STATE"

run_collector() {
  PATH="$BIN:$PATH" \
  NOMAD_ADDR="http://127.0.0.1:4646" \
  NOMAD_TOKEN="test-token" \
  NOMAD_TIMEOUT=2 \
  SNAPSHOT_PATH="$STATE" \
  FAKE_NOMAD_DATA="$DATA" \
    bash "$COLLECTOR"
}

alerts() {
  jq -c '.collectors.nomad.alerts' "$STATE"
}

non_service_alerts() {
  jq -c '[.collectors.nomad.alerts[] | select(test("^service .* not registered$") | not)]' "$STATE"
}

# ── 1. Declared forgejo, registry lists only edge ───────────────────────────
ac_log "AC 1: unregistered forgejo service is alerted"

write_services '["edge"]'
: > "$DATA/requests.log"
run_collector

jq -e '.collectors.nomad.alerts | index("service forgejo of job forgejo not registered") != null' \
  "$STATE" >/dev/null \
  || ac_fail "alerts must contain 'service forgejo of job forgejo not registered', got: $(alerts)"
jq -e '.collectors.nomad.alerts | index("service forgejo-metrics of job forgejo not registered") != null' \
  "$STATE" >/dev/null \
  || ac_fail "task-level declared service must alert, got: $(alerts)"
if jq -e '.collectors.nomad.alerts | index("service nightly of job nightly not registered") != null' \
  "$STATE" >/dev/null; then
  ac_fail "a running batch job must not raise a service alert, got: $(alerts)"
fi
jq -e '.collectors.nomad.alerts | index("job stale dead") != null' "$STATE" >/dev/null \
  || ac_fail "existing dead-job alert must still be present, got: $(alerts)"
jq -e '.collectors.nomad.alerts | index("alloc cafebabe restarted 4 times (last 1h)") != null' \
  "$STATE" >/dev/null \
  || ac_fail "existing restart alert must still be present, got: $(alerts)"

# ── 2. Every declared service is registered ─────────────────────────────────
ac_log "AC 2: registered services raise no service alert"

write_services '["edge","forgejo","forgejo-metrics"]'
run_collector
if jq -e '[.collectors.nomad.alerts[] | select(test("^service .* not registered$"))] | length > 0' \
  "$STATE" >/dev/null; then
  ac_fail "no alert may match ^service .* not registered$ when every declared service is registered, got: $(alerts)"
fi

# ── 3. Collector timestamp ──────────────────────────────────────────────────
ac_log "AC 3: .collectors.nomad.ts parses as %Y-%m-%dT%H:%M:%SZ"

ts="$(jq -r '.collectors.nomad.ts // empty' "$STATE")"
[ -n "$ts" ] || ac_fail ".collectors.nomad.ts must be set, got: $(jq -c '.collectors.nomad' "$STATE")"
printf '%s\n' "$ts" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  || ac_fail "ts must match %Y-%m-%dT%H:%M:%SZ, got: $ts"
printf '%s' "$ts" | jq -Re 'strptime("%Y-%m-%dT%H:%M:%SZ") | type == "array"' >/dev/null \
  || ac_fail "ts must parse with strptime %Y-%m-%dT%H:%M:%SZ, got: $ts"

# ── 4. /v1/services failing adds no service alerts ──────────────────────────
ac_log "AC 4: a failed /v1/services leaves the other alerts and adds none"

# Re-establish the missing-registration fixture, then fail the services call.
# "As today" is the job/alloc alerts from a successful collect with no
# service-registration misses — the alerts this collector already emitted.
write_services '["edge","forgejo","forgejo-metrics"]'
run_collector
today="$(non_service_alerts)"
if jq -e '[.[] | select(test("^service .* not registered$"))] | length > 0' <<<"$today" >/dev/null; then
  ac_fail "baseline for AC 4 must not already contain service alerts, got: $today"
fi

: > "$DATA/services.fail"
# Registry would otherwise miss forgejo; a failed call must not say so.
write_services '["edge"]'
run_collector
ac_assert_eq "$(alerts)" "$today" \
  "/v1/services failing must leave the other alerts unchanged and add none, got: $(alerts)"
if jq -e '[.collectors.nomad.alerts[] | select(test("^service .* not registered$"))] | length > 0' \
  "$STATE" >/dev/null; then
  ac_fail "/v1/services failing must add no service alert, got: $(alerts)"
fi

ac_pass
