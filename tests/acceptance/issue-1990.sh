#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1990.sh
#
# Issue #1990: a URL marked unfixable while its backend was healthy (edge in
# cooldown, fault outside the box) must not stay unfixable forever. A later
# recheck that finds that backend unhealthy or unregistered drops
# state.unfixable[url] and the normal endpoint pass restarts the backend
# alloc, still subject to HEALER_COOLDOWN_SECS and HEALER_MAX_RESTARTS.
#
# A recheck that still finds the backend healthy keeps the record. A public
# URL that answers 2xx/3xx still clears it. A failed Nomad read is not
# "unregistered" and does not drop the record.
#
# Hermetic: shared curl/nomad stubs, --once, no network.
#
# Run via: tools/run-acceptance.sh 1990
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../lib/healer-stubs.sh
source "$REPO_ROOT/tests/lib/healer-stubs.sh"

ac_require_cmd bash jq grep mktemp date

HEALER="$REPO_ROOT/bin/healer.sh"
ac_assert_file "$HEALER" "bin/healer.sh must exist"

ac_healer_init "${TMPDIR:-/tmp}/healer-1990.XXXXXX"
ac_healer_public_fixtures

FORGE_URL="https://self.disinto.ai/forge/"
export HEALER_TEST_PUBLIC_URLS="$FORGE_URL"

# Streak already at the act threshold, unfixable recorded, edge cooled down
# (the #1952 outside-the-box record). Optional extra object is merged in.
seed_unfixable() {
  local state_dir="$1" now="$2" extra="${3:-}"
  mkdir -p "$state_dir"
  if [ -z "$extra" ]; then
    extra='{}'
  fi
  jq -n --arg u "$FORGE_URL" --argjson now "$now" --argjson extra "$extra" \
    '{failures:{($u):3}, unfixable:{($u):$now}, cooldown:{edge:$now}} + $extra' \
    > "$state_dir/state.json"
}

has_unfixable() {
  jq -e --arg u "$FORGE_URL" '(.unfixable // {}) | has($u)' \
    "$1/state.json" >/dev/null 2>&1
}

# ── AC1: backend dies after unfixable → drop record, restart forgejo ────────
ac_log "AC1: healthy backend marks unfixable; later death restarts forgejo"
STATE_DIR="$WORK/st-1"
TAPE_DIR="$WORK/tp-1"
STUB_LOG="$WORK/nm-1.log"
mkdir -p "$TAPE_DIR"
: > "$STUB_LOG"
set_probe_code forge 502
set_probe_code forgejo 200
clear_probe_code ci
clear_probe_code woodpecker

i=0
while [ "$i" -lt 4 ]; do
  i=$((i + 1))
  rc=0
  out="$(healer_run_once "$STATE_DIR" "$TAPE_DIR")" || rc=$?
  ac_assert_eq "$rc" "0" "AC1 tick ${i} exit 0, got $rc: $out"
done
ac_assert_eq "$(healer_restarts_of edge)" "1" \
  "AC1 edge restarted once before unfixable: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of forgejo)" "0" \
  "AC1 must not restart a healthy forgejo: $(cat "$STUB_LOG")"
has_unfixable "$STATE_DIR" \
  || ac_fail "AC1 tick 4 must record unfixable, got: $(cat "$STATE_DIR/state.json")"

set_probe_code forgejo 503
rc=0
out="$(healer_run_once "$STATE_DIR" "$TAPE_DIR")" || rc=$?
ac_assert_eq "$rc" "0" "AC1 death tick exit 0, got $rc: $out"
if has_unfixable "$STATE_DIR"; then
  ac_fail "AC1 must drop unfixable once forgejo is unhealthy, got: $(cat "$STATE_DIR/state.json")"
fi
ac_assert_eq "$(healer_restarts_of forgejo)" "1" \
  "AC1 restarts the now-unhealthy forgejo alloc: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of edge)" "1" \
  "AC1 must not restart edge again: $(cat "$STUB_LOG")"
printf '%s\n' "$out" | grep -q "backend down — unfixable cleared" \
  || ac_fail "AC1 must log that unfixable was cleared, got: $out"

# ── AC2: backend still healthy → unfixable stays, no restart ────────────────
ac_log "AC2: recheck still healthy keeps unfixable and does not restart"
STATE_DIR="$WORK/st-2"
TAPE_DIR="$WORK/tp-2"
STUB_LOG="$WORK/nm-2.log"
mkdir -p "$TAPE_DIR"
: > "$STUB_LOG"
seed_unfixable "$STATE_DIR" 500000
set_probe_code forge 502
set_probe_code forgejo 200
rc=0
out="$(healer_run_once "$STATE_DIR" "$TAPE_DIR")" || rc=$?
ac_assert_eq "$rc" "0" "AC2 exit 0, got $rc: $out"
has_unfixable "$STATE_DIR" \
  || ac_fail "AC2 healthy backend must keep unfixable, got: $(cat "$STATE_DIR/state.json")"
ac_assert_eq "$(healer_restart_lines)" "0" \
  "AC2 must not restart while the backend is healthy: $(cat "$STUB_LOG")"
printf '%s\n' "$out" | grep -q "unfixable — no action" \
  || ac_fail "AC2 must keep the no-action short-circuit, got: $out"

# ── AC3: URL 2xx/3xx still clears unfixable ─────────────────────────────────
ac_log "AC3: URL 2xx still clears unfixable, no restart"
STATE_DIR="$WORK/st-3"
TAPE_DIR="$WORK/tp-3"
STUB_LOG="$WORK/nm-3.log"
mkdir -p "$TAPE_DIR"
: > "$STUB_LOG"
seed_unfixable "$STATE_DIR" 500000
set_probe_code forge 200
set_probe_code forgejo 200
rc=0
out="$(healer_run_once "$STATE_DIR" "$TAPE_DIR")" || rc=$?
ac_assert_eq "$rc" "0" "AC3 exit 0, got $rc: $out"
if has_unfixable "$STATE_DIR"; then
  ac_fail "AC3 URL 2xx must clear unfixable, got: $(cat "$STATE_DIR/state.json")"
fi
ac_assert_eq "$(healer_restart_lines)" "0" \
  "AC3 an up URL must not restart: $(cat "$STUB_LOG")"

# ── AC4: cooldown still blocks the restart after unfixable is dropped ───────
ac_log "AC4: forgejo in cooldown → unfixable dropped, restart waits"
STATE_DIR="$WORK/st-4"
TAPE_DIR="$WORK/tp-4"
STUB_LOG="$WORK/nm-4.log"
mkdir -p "$TAPE_DIR"
: > "$STUB_LOG"
export HEALER_TEST_COOLDOWN_SECS=1800
export HEALER_TEST_NOW=600000
seed_unfixable "$STATE_DIR" 600000 '{"cooldown":{"edge":600000,"forgejo":600000}}'
set_probe_code forge 502
set_probe_code forgejo 503
rc=0
out="$(healer_run_once "$STATE_DIR" "$TAPE_DIR")" || rc=$?
ac_assert_eq "$rc" "0" "AC4 cooldown tick exit 0, got $rc: $out"
if has_unfixable "$STATE_DIR"; then
  ac_fail "AC4 must drop unfixable even when cooldown blocks the restart, got: $(cat "$STATE_DIR/state.json")"
fi
ac_assert_eq "$(healer_restarts_of forgejo)" "0" \
  "AC4 must not restart forgejo during cooldown: $(cat "$STUB_LOG")"

ac_log "AC4b: after cooldown, the same unhealthy backend is restarted"
export HEALER_TEST_NOW=601800
rc=0
out="$(healer_run_once "$STATE_DIR" "$TAPE_DIR")" || rc=$?
ac_assert_eq "$rc" "0" "AC4b exit 0, got $rc: $out"
ac_assert_eq "$(healer_restarts_of forgejo)" "1" \
  "AC4b restarts forgejo once cooldown ends: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of edge)" "0" \
  "AC4b must not restart edge for an unhealthy backend: $(cat "$STUB_LOG")"
unset HEALER_TEST_NOW
unset HEALER_TEST_COOLDOWN_SECS

# ── AC5: per-tick cap still blocks; next tick restarts ──────────────────────
ac_log "AC5: restart cap → unfixable dropped, forgejo waits until next tick"
for id in extra-a extra-b extra-c; do
  jq -n --arg id "$id" \
    '{ID:$id,TaskGroups:[{Name:$id,Services:[{Name:$id}],Tasks:[{Name:$id,Services:[]}]}]}' \
    > "$DATA/job-$id.json"
  jq -n --arg id "$id" --arg alloc "alloc-$id" \
    '[{ID:$alloc,JobID:$id,ClientStatus:"running"}]' \
    > "$DATA/allocs-$id.json"
done
jq -n '[
  {ID:"forgejo",Status:"running",Type:"service"},
  {ID:"woodpecker-server",Status:"running",Type:"service"},
  {ID:"edge",Status:"running",Type:"service"},
  {ID:"extra-a",Status:"running",Type:"service"},
  {ID:"extra-b",Status:"running",Type:"service"},
  {ID:"extra-c",Status:"running",Type:"service"}
]' > "$DATA/jobs.json"

STATE_DIR="$WORK/st-5"
TAPE_DIR="$WORK/tp-5"
STUB_LOG="$WORK/nm-5.log"
mkdir -p "$TAPE_DIR"
: > "$STUB_LOG"
seed_unfixable "$STATE_DIR" 700000
set_probe_code forge 502
set_probe_code forgejo 503
rc=0
out="$(healer_run_once "$STATE_DIR" "$TAPE_DIR")" || rc=$?
ac_assert_eq "$rc" "0" "AC5 exit 0, got $rc: $out"
ac_assert_eq "$(healer_restart_lines)" "3" \
  "AC5 exactly the 3 service restarts, not a 4th: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of forgejo)" "0" \
  "AC5 must not restart forgejo past the cap: $(cat "$STUB_LOG")"
if has_unfixable "$STATE_DIR"; then
  ac_fail "AC5 must drop unfixable even when the cap blocks the restart, got: $(cat "$STATE_DIR/state.json")"
fi
printf '%s\n' "$out" | grep -q "restart cap reached — ${FORGE_URL} waits" \
  || ac_fail "AC5 capped URL must be logged as waiting, got: $out"

ac_log "AC5b: next tick, budget free, the dropped-unfixable backend is restarted"
rc=0
out="$(healer_run_once "$STATE_DIR" "$TAPE_DIR")" || rc=$?
ac_assert_eq "$rc" "0" "AC5b exit 0, got $rc: $out"
ac_assert_eq "$(healer_restarts_of forgejo)" "1" \
  "AC5b restarts forgejo once the budget is free: $(cat "$STUB_LOG")"
ac_healer_public_fixtures

# ── AC6: unregistered backend drops unfixable ───────────────────────────────
ac_log "AC6: unregistered backend drops unfixable"
STATE_DIR="$WORK/st-6"
TAPE_DIR="$WORK/tp-6"
STUB_LOG="$WORK/nm-6.log"
mkdir -p "$TAPE_DIR"
: > "$STUB_LOG"
seed_unfixable "$STATE_DIR" 800000
set_probe_code forge 502
jq -n '{Services:[]}' > "$DATA/svc-forgejo.json"
jq -n '[{Namespace:"default",Services:[
  {ServiceName:"woodpecker",Tags:[]},{ServiceName:"edge",Tags:[]}
]}]' > "$DATA/services.json"
rc=0
out="$(healer_run_once "$STATE_DIR" "$TAPE_DIR")" || rc=$?
ac_assert_eq "$rc" "0" "AC6 exit 0, got $rc: $out"
if has_unfixable "$STATE_DIR"; then
  ac_fail "AC6 unregistered backend must drop unfixable, got: $(cat "$STATE_DIR/state.json")"
fi
ac_assert_eq "$(healer_restarts_of forgejo)" "1" \
  "AC6 service pass restarts the unregistered alloc: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of edge)" "0" \
  "AC6 must not restart edge for an unregistered backend: $(cat "$STUB_LOG")"
ac_healer_public_fixtures

# ── AC7: a failed Nomad read keeps unfixable ────────────────────────────────
ac_log "AC7: failed service read keeps unfixable and does not restart"
STATE_DIR="$WORK/st-7"
TAPE_DIR="$WORK/tp-7"
STUB_LOG="$WORK/nm-7.log"
mkdir -p "$TAPE_DIR"
: > "$STUB_LOG"
seed_unfixable "$STATE_DIR" 900000
set_probe_code forge 502
set_probe_code forgejo 503
rm -f "$DATA/svc-forgejo.json"
rc=0
out="$(healer_run_once "$STATE_DIR" "$TAPE_DIR")" || rc=$?
ac_assert_eq "$rc" "0" "AC7 exit 0, got $rc: $out"
has_unfixable "$STATE_DIR" \
  || ac_fail "AC7 a failed recheck must keep unfixable, got: $(cat "$STATE_DIR/state.json")"
ac_assert_eq "$(healer_restart_lines)" "0" \
  "AC7 must not restart on a failed recheck: $(cat "$STUB_LOG")"
printf '%s\n' "$out" | grep -q "unfixable — no action" \
  || ac_fail "AC7 must keep the no-action short-circuit, got: $out"

ac_pass
