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
# Hermetic: shared curl + nomad stubs from tests/lib/healer-stubs.sh,
# per-AC temp HEALER_STATE_DIR/TAPE_DIR. The Nomad API is served from fixtures
# ($FAKE_NOMAD_DATA); the two public endpoints and the two backend health checks
# are driven by per-run code files in $HEALER_WORK, so each AC is a controlled
# set of `--once` ticks.
#
# All three services (forgejo, woodpecker, edge) are registered with live
# allocations, so the #1950 service-reregister pass stays idle and the only
# restarts observed are the endpoint ones.
#
# Verifies the four issue acceptance criteria (AC1-AC5; AC3 is an added
# two-URL scenario). Mapped to the criteria in the issue body:
#   AC1 -> criterion 2: /forge/ down 3 ticks, forgejo HEALTHY
#        -> restart edge (not forgejo)
#   AC2 -> criterion 1: /forge/ down 3 ticks, forgejo UNHEALTHY
#        -> restart forgejo (not edge)
#   AC3  (added) /forge/ + /ci/ down 3 ticks, forgejo healthy +
#        woodpecker unhealthy -> restart edge AND woodpecker-server
#        (2 restarts <= 3 shared budget)
#   AC4 -> criterion 3: /forge/ down, forgejo healthy, edge in cooldown
#        -> record unfixable once, no edge re-restart (fault outside box)
#   AC5 -> criterion 4: /forge/ down then back to 200 -> count reset to 0
#        and outcome {acted:1, cleared:1} appended to the tape
#
# Run via: tools/run-acceptance.sh 1952
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../lib/healer-stubs.sh
source "$REPO_ROOT/tests/lib/healer-stubs.sh"
# Public-endpoint pass (issue #1952): stubs + multiple `--once` ticks per AC.

ac_require_cmd bash jq flock grep mktemp date

HEALER="$REPO_ROOT/bin/healer.sh"
ac_assert_file "$HEALER" "bin/healer.sh must exist"

grep -qF 'HEALER_PUBLIC_URLS' "$HEALER" \
  || ac_fail "must define HEALER_PUBLIC_URLS"
grep -qF 'HEALER_PUBLIC_FAILURES' "$HEALER" \
  || ac_fail "must define HEALER_PUBLIC_FAILURES"
grep -qF 'HEALER_PROBE_TIMEOUT_SECS' "$HEALER" \
  || ac_fail "must define HEALER_PROBE_TIMEOUT_SECS"

# Shared fake curl/nomad + the three registered services.
ac_healer_init "${TMPDIR:-/tmp}/healer-1952.XXXXXX"
ac_healer_public_fixtures

# Run exactly N ticks; probe codes are set/cleared with set_probe_code /
# clear_probe_code between calls. Returns the first non-zero exit code seen.
# Only truncates $STUB_LOG when it does not yet exist, so consecutive
# run_ticks calls on one log accumulate.
run_ticks() {
  local n="$1" state_dir="$2" tape_dir="$3" i rc=0
  mkdir -p "$state_dir" "$tape_dir"
  [ -f "$STUB_LOG" ] || : > "$STUB_LOG"
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    healer_run_once "$state_dir" "$tape_dir" || return 1
  done
  return 0
}

# ── AC 1: /forge/ down 3 ticks, forgejo healthy -> restart edge, not forgejo ──
ac_log "AC1: /forge/ down 3 ticks, forgejo HEALTHY -> restart edge (not forgejo)"
STATE_DIR="$WORK/st-1"; TAPE_DIR="$WORK/tp-1"; STUB_LOG="$WORK/nm-1.log"
set_probe_code forge 502
set_probe_code forgejo 200
clear_probe_code ci; clear_probe_code woodpecker
rc=0; run_ticks 3 "$STATE_DIR" "$TAPE_DIR" || rc=$?
ac_assert_eq "$rc" "0" "AC1 exit 0, got $rc"
ac_assert_eq "$(healer_restart_lines)" "1" "AC1 exactly one restart: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of edge)" "1" "AC1 restart is alloc-edge: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of forgejo)" "0" "AC1 must not restart forgejo (backend healthy)"
ac_assert_eq "$(healer_restarts_of woodpecker-server)" "0" "AC1 must not restart woodpecker"

# ── AC 2: /forge/ down 3 ticks, forgejo unhealthy -> restart forgejo ─────────
ac_log "AC2: /forge/ down 3 ticks, forgejo UNHEALTHY -> restart forgejo (not edge)"
STATE_DIR="$WORK/st-2"; TAPE_DIR="$WORK/tp-2"; STUB_LOG="$WORK/nm-2.log"
set_probe_code forge 502
set_probe_code forgejo 503
clear_probe_code ci; clear_probe_code woodpecker
rc=0; run_ticks 3 "$STATE_DIR" "$TAPE_DIR" || rc=$?
ac_assert_eq "$rc" "0" "AC2 exit 0, got $rc"
ac_assert_eq "$(healer_restart_lines)" "1" "AC2 exactly one restart: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of forgejo)" "1" "AC2 restart is alloc-forgejo: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of edge)" "0" "AC2 must not restart edge (backend unhealthy)"
ac_assert_eq "$(healer_restarts_of woodpecker-server)" "0" "AC2 must not restart woodpecker"

# ── AC 3: both down, forgejo healthy + woodpecker unhealthy -> edge + wp -----
ac_log "AC3: /forge/+ /ci/ down 3 ticks (forgejo healthy, woodpecker unhealthy) -> edge + woodpecker-server"
STATE_DIR="$WORK/st-3"; TAPE_DIR="$WORK/tp-3"; STUB_LOG="$WORK/nm-3.log"
set_probe_code forge 502
set_probe_code ci 502
set_probe_code forgejo 200
set_probe_code woodpecker 503
rc=0; run_ticks 3 "$STATE_DIR" "$TAPE_DIR" || rc=$?
ac_assert_eq "$rc" "0" "AC3 exit 0, got $rc"
ac_assert_eq "$(healer_restarts_of edge)" "1" "AC3 restarts alloc-edge (forge healthy): $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of woodpecker-server)" "1" "AC3 restarts alloc-woodpecker-server (ci unhealthy): $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restart_lines)" "2" "AC3 exactly two restarts (<= 3 budget): $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of forgejo)" "0" "AC3 must not restart forgejo (healthy)"

# ── AC 4: edge in cooldown, backend healthy -> unfixable, no edge re-restart ─
ac_log "AC4: /forge/ down, forgejo healthy, edge in cooldown -> unfixable (no re-restart)"
STATE_DIR="$WORK/st-4"; TAPE_DIR="$WORK/tp-4"; STUB_LOG="$WORK/nm-4.log"
set_probe_code forge 502
set_probe_code forgejo 200
clear_probe_code ci; clear_probe_code woodpecker
# Ticks 1-3: streak reaches 3 on tick 3 -> edge restart (cooldown[edge] set).
# Ticks 4-6: URL still down, edge in cooldown, backend healthy -> unfixable
# is recorded once (tick 4) and no further restart is attempted.
rc=0; run_ticks 6 "$STATE_DIR" "$TAPE_DIR" || rc=$?
ac_assert_eq "$rc" "0" "AC4 exit 0, got $rc"
ac_assert_eq "$(healer_restart_lines)" "1" "AC4 exactly one restart (edge), no re-restart: $(cat "$STUB_LOG")"
ac_assert_eq "$(healer_restarts_of edge)" "1" "AC4 only alloc-edge was restarted: $(cat "$STUB_LOG")"
# state.json must contain the unfixable record for the forge URL
jq -e '(.unfixable // {}) | has("https://self.disinto.ai/forge/")' \
  "$STATE_DIR/state.json" >/dev/null 2>&1 \
  || ac_fail "AC4 state.json must record unfixable for /forge/, got: $(cat "$STATE_DIR/state.json")"

# ── AC 5: /forge/ down then back to 200 -> count reset, outcome cleared ──────
ac_log "AC5: /forge/ down 3 ticks then 200 -> count reset to 0, outcome {acted:1,cleared:1}"
STATE_DIR="$WORK/st-5"; TAPE_DIR="$WORK/tp-5"; STUB_LOG="$WORK/nm-5.log"
set_probe_code forge 502
set_probe_code forgejo 200
clear_probe_code ci; clear_probe_code woodpecker
rc=0; run_ticks 3 "$STATE_DIR" "$TAPE_DIR" || rc=$?
ac_assert_eq "$rc" "0" "AC5 exit 0 after 3 down ticks, got $rc"
# The URL comes back up.
set_probe_code forge 200
rc=0; run_ticks 1 "$STATE_DIR" "$TAPE_DIR" || rc=$?
ac_assert_eq "$rc" "0" "AC5 exit 0 after up tick, got $rc"
# Probe count resets to 0.
ac_assert_eq "$(jq -r --arg u "https://self.disinto.ai/forge/" '(.failures // {}) | .[$u] // 0' "$STATE_DIR/state.json")" \
  "0" "AC5 failure count resets to 0"
# The open proposal was closed and dropped from state.
jq -e '.endpoint_open // {} | (length == 0)' "$STATE_DIR/state.json" \
  || ac_fail "AC5 endpoint_open must be empty after clear: $(cat "$STATE_DIR/state.json")"
# Exactly one {acted:1,cleared:1} outcome was appended to the tape.
ac_assert_eq "$(jq -sc '[.[] | select(.type == "outcome" and .bits.acted == 1 and .bits.cleared == 1)] | length' "$TAPE_DIR/tape.jsonl")" \
  "1" "AC5 exactly one {acted:1,cleared:1} outcome"
ac_pass