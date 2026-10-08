#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1950.sh
#
# Issue #1950: a host-side healer re-registers a lost Nomad service by
# restarting the running allocation.
#
# Hermetic: curl and nomad stubs on PATH, temp HEALER_STATE_DIR and
# TAPE_DIR. No Nomad, no network. Each scenario is one `healer.sh --once`.
#
#   1. forgejo declares forgejo, /v1/services lacks it: the stub records
#      `alloc restart <forgejo alloc>`, and the tape has one repair
#      proposal of class service-reregister.
#   2. A second --once within the cooldown restarts nothing.
#   3. agents-dev-qwen unregistered with dev-agent.sh running: no restart.
#      With nothing running: a restart.
#   4. The service registered on the next tick: the tape has the outcome
#      {"acted":1,"cleared":1}.
#   5. HEALER_DRY_RUN=1 restarts nothing and logs `would restart`.
#
# Run via: tools/run-acceptance.sh 1950
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq flock grep mktemp date

HEALER="$REPO_ROOT/bin/healer.sh"
ac_assert_file "$HEALER" "bin/healer.sh must exist"

# Header is the documentation: what it fixes, the guards, and the rule
# that no other disinto process restarts allocations.
grep -qF 'only disinto process allowed to restart allocations' "$HEALER" \
  || ac_fail "header must say this is the only disinto process allowed to restart allocations"
grep -qF 'dev-agent.sh|review-pr.sh|gardener-run.sh|dsh ' "$HEALER" \
  || ac_fail "header must name the in-flight process match"
grep -qF 'HEALER_INTERVAL_SECS:-60' "$HEALER" \
  || ac_fail "loop interval must default to 60"
grep -qF 'HEALER_COOLDOWN_SECS:-1800' "$HEALER" \
  || ac_fail "cooldown must default to 1800"
grep -qF 'HEALER_STATE_DIR:-/srv/disinto/healer' "$HEALER" \
  || ac_fail "state dir must default to /srv/disinto/healer"
grep -qF 'NOMAD_ADDR:-http://localhost:4646' "$HEALER" \
  || ac_fail "NOMAD_ADDR must default to http://localhost:4646"
grep -qF -- '--once' "$HEALER" \
  || ac_fail "healer.sh must accept --once"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/healer-1950.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

DATA="$WORK/nomad"
BIN="$WORK/bin"
STATE="$WORK/state"
TAPE="$WORK/tape"
STUB_LOG="$WORK/nomad-invocations.log"
mkdir -p "$DATA" "$BIN" "$STATE" "$TAPE"
: > "$STUB_LOG"

# ── Curl stub ────────────────────────────────────────────────────────────────
# Serves the paths healer.sh GETs. Bodies live in $FAKE_NOMAD_DATA.
# v1/agent/health exits 22 when health.fail is present.
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
path="${url#*://}"
path="${path#*/}"
path="${path%%\?*}"
data="${FAKE_NOMAD_DATA:?FAKE_NOMAD_DATA unset}"
printf '%s\n' "$url" >> "$data/urls.log"
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
  v1/job/*/allocations)
    rest="${path#v1/job/}"
    job="${rest%%/*}"
    file="$data/allocs-$job.json"
    ;;
  v1/job/*)
    job="${path#v1/job/}"
    file="$data/job-$job.json"
    ;;
  *)
    echo "healer-curl-stub: unexpected path: $path" >&2
    exit 9
    ;;
esac
[ -f "$file" ] || { echo "healer-curl-stub: no fixture for $path" >&2; exit 22; }
cat "$file"
EOF
chmod +x "$BIN/curl"

# ── Nomad stub ───────────────────────────────────────────────────────────────
# Records every invocation. `alloc restart <id>` is the remedy.
# `alloc exec` prints $FAKE_NOMAD_DATA/ps-<alloc> when that file exists.
cat > "$BIN/nomad" <<'EOF'
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
EOF
chmod +x "$BIN/nomad"

# forgejo declares a group-level service of the same name (the outage).
# nightly-batch is running but batch — the healer must not fetch it.
# stopped-job is dead — same.
jq -n '{
  ID: "forgejo",
  TaskGroups: [{
    Name: "forgejo",
    Services: [{Name: "forgejo"}],
    Tasks: [{Name: "forgejo", Services: []}]
  }]
}' > "$DATA/job-forgejo.json"
jq -n '[{ID: "alloc-forgejo", JobID: "forgejo", ClientStatus: "running"}]' \
  > "$DATA/allocs-forgejo.json"
jq -n '{
  ID: "agents-dev-qwen",
  TaskGroups: [{
    Name: "agents",
    Services: [{Name: "agents-dev-qwen"}],
    Tasks: [{Name: "agents", Services: []}]
  }]
}' > "$DATA/job-agents-dev-qwen.json"
jq -n '[{ID: "alloc-agents-dev-qwen", JobID: "agents-dev-qwen", ClientStatus: "running"}]' \
  > "$DATA/allocs-agents-dev-qwen.json"

write_jobs() {
  local extra="${1:-[]}"
  jq -n --argjson extra "$extra" '
    [
      {ID: "forgejo", Status: "running", Type: "service"},
      {ID: "nightly-batch", Status: "running", Type: "batch"},
      {ID: "stopped-job", Status: "dead", Type: "service"}
    ] + $extra
  ' > "$DATA/jobs.json"
}

write_services() {
  jq -n --argjson names "$1" \
    '[{Namespace: "default", Services: [$names[] | {ServiceName: ., Tags: []}]}]' \
    > "$DATA/services.json"
}

write_jobs '[]'
write_services '["edge"]'

run_healer() {
  PATH="$BIN:$PATH" \
  NOMAD_ADDR="http://127.0.0.1:4646" \
  NOMAD_TIMEOUT=2 \
  HEALER_STATE_DIR="$STATE" \
  HEALER_INTERVAL_SECS=60 \
  HEALER_COOLDOWN_SECS=1800 \
  TAPE_DIR="$TAPE" \
  FAKE_NOMAD_DATA="$DATA" \
  NOMAD_STUB_LOG="$STUB_LOG" \
    bash "$HEALER" --once
}

restart_lines() {
  grep -c '^alloc restart ' "$STUB_LOG" || true
}

proposal_count() {
  jq -s '[.[] | select(.type == "proposal" and .class == "service-reregister" and .loop == "repair")] | length' \
    "$TAPE/tape.jsonl"
}

# ── 1. Unregistered forgejo is restarted, one repair proposal ───────────────
ac_log "AC 1: unregistered forgejo restarts its alloc and writes a repair proposal"

: > "$DATA/urls.log"
rc=0
out="$(run_healer)" || rc=$?
ac_assert_eq "$rc" "0" "healer --once must exit 0, got $rc: $out"
ac_assert_eq "$(restart_lines)" "1" "exactly one alloc restart, stub log: $(cat "$STUB_LOG")"
grep -qx 'alloc restart alloc-forgejo' "$STUB_LOG" \
  || ac_fail "stub must record 'alloc restart alloc-forgejo', got: $(cat "$STUB_LOG")"
grep -q '127.0.0.1:4646/v1/agent/health' "$DATA/urls.log" \
  || ac_fail "tick must query NOMAD_ADDR /v1/agent/health, got: $(cat "$DATA/urls.log")"
grep -q '127.0.0.1:4646/v1/jobs' "$DATA/urls.log" \
  || ac_fail "tick must query /v1/jobs"
grep -q '127.0.0.1:4646/v1/services' "$DATA/urls.log" \
  || ac_fail "tick must query /v1/services"
grep -q '127.0.0.1:4646/v1/job/forgejo$' "$DATA/urls.log" \
  || ac_fail "tick must query /v1/job/forgejo"
if grep -q 'v1/job/nightly-batch' "$DATA/urls.log" || grep -q 'v1/job/stopped-job' "$DATA/urls.log"; then
  ac_fail "batch and non-running jobs must not be inspected, got: $(cat "$DATA/urls.log")"
fi
ac_assert_file "$TAPE/tape.jsonl" "tape must exist after a restart"
ac_assert_eq "$(proposal_count)" "1" "tape must hold one service-reregister repair proposal"
jq -s -e '
  [.[] | select(.type == "proposal")]
  | length == 1
  and .[0].class == "service-reregister"
  and .[0].loop == "repair"
  and .[0].decision == "auto"
  and .[0].ref == "job:forgejo"
  and .[0].context.signature == "service-unregistered:forgejo"
  and .[0].context.organ == "healer"
  and (.[0] | has("caused_by") | not)
  and (.[0] | has("parent") | not)
' "$TAPE/tape.jsonl" >/dev/null \
  || ac_fail "proposal shape mismatch: $(cat "$TAPE/tape.jsonl")"
FORGEJO_PID="$(jq -s -r '[.[] | select(.type == "proposal" and .ref == "job:forgejo")][0].id' "$TAPE/tape.jsonl")"
if [ -z "$FORGEJO_PID" ] || [ "$FORGEJO_PID" = "null" ]; then
  ac_fail "forgejo proposal id missing"
fi

# ── 2. Second tick inside the cooldown restarts nothing ─────────────────────
ac_log "AC 2: a second --once within the cooldown restarts nothing"

before="$(restart_lines)"
rc=0
out="$(run_healer)" || rc=$?
ac_assert_eq "$rc" "0" "second --once must exit 0, got $rc: $out"
ac_assert_eq "$(restart_lines)" "$before" "cooldown tick must not restart, stub log: $(cat "$STUB_LOG")"
ac_assert_eq "$(proposal_count)" "1" "cooldown tick must not write a second proposal"

# ── 3. agents-* with work in flight, then idle ──────────────────────────────
ac_log "AC 3: agents-dev-qwen with dev-agent.sh running is not restarted"

write_jobs '[{"ID":"agents-dev-qwen","Status":"running","Type":"service"}]'
printf '%s\n' 'dev-agent.sh --issue 1950' > "$DATA/ps-alloc-agents-dev-qwen"
before="$(restart_lines)"
rc=0
out="$(run_healer)" || rc=$?
ac_assert_eq "$rc" "0" "in-flight tick must exit 0, got $rc: $out"
ac_assert_eq "$(restart_lines)" "$before" "work in flight must not restart, stub log: $(cat "$STUB_LOG")"
grep -q 'alloc exec' "$STUB_LOG" \
  || ac_fail "in-flight check must call nomad alloc exec, stub log: $(cat "$STUB_LOG")"

ac_log "AC 3b: agents-dev-qwen with nothing running is restarted"

printf '%s\n' 'sleep 30' > "$DATA/ps-alloc-agents-dev-qwen"
rc=0
out="$(run_healer)" || rc=$?
ac_assert_eq "$rc" "0" "idle agents tick must exit 0, got $rc: $out"
grep -qx 'alloc restart alloc-agents-dev-qwen' "$STUB_LOG" \
  || ac_fail "idle agents alloc must be restarted, stub log: $(cat "$STUB_LOG")"
ac_assert_eq "$(restart_lines)" "$((before + 1))" \
  "idle tick must add exactly one restart, stub log: $(cat "$STUB_LOG")"

# ── 4. Registered on the next tick → outcome cleared 1 ──────────────────────
ac_log "AC 4: service registered on the next tick writes {acted:1,cleared:1}"

write_services '["edge","forgejo"]'
rc=0
out="$(run_healer)" || rc=$?
ac_assert_eq "$rc" "0" "clearance tick must exit 0, got $rc: $out"
jq -s -e --arg pid "$FORGEJO_PID" '
  [.[] | select(.type == "outcome" and .proposal_id == $pid)]
  | length == 1
  and .[0].bits == {acted: 1, cleared: 1}
' "$TAPE/tape.jsonl" >/dev/null \
  || ac_fail "expected outcome {acted:1,cleared:1} for ${FORGEJO_PID}, tape: $(cat "$TAPE/tape.jsonl")"

# ── 5. Dry run restarts nothing and logs would restart ──────────────────────
ac_log "AC 5: HEALER_DRY_RUN=1 restarts nothing and logs would restart"

DRY_STATE="$WORK/state-dry"
mkdir -p "$DRY_STATE"
write_services '["edge"]'
before="$(restart_lines)"
proposals_before="$(proposal_count)"
rc=0
out="$(
  HEALER_DRY_RUN=1 \
  HEALER_STATE_DIR="$DRY_STATE" \
  PATH="$BIN:$PATH" \
  NOMAD_ADDR="http://127.0.0.1:4646" \
  NOMAD_TIMEOUT=2 \
  HEALER_COOLDOWN_SECS=1800 \
  TAPE_DIR="$TAPE" \
  FAKE_NOMAD_DATA="$DATA" \
  NOMAD_STUB_LOG="$STUB_LOG" \
    bash "$HEALER" --once
)" || rc=$?
ac_assert_eq "$rc" "0" "dry-run --once must exit 0, got $rc: $out"
ac_assert_eq "$(restart_lines)" "$before" "dry run must not restart, stub log: $(cat "$STUB_LOG")"
ac_assert_eq "$(proposal_count)" "$proposals_before" "dry run must not write a proposal"
printf '%s\n' "$out" | grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] healer: would restart forgejo$' \
  || ac_fail "dry run must log 'would restart forgejo', got: $out"

ac_pass
