#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1453.sh
#
# Issue #1453: calibration.sh's stdout table was missing the model's promise.
# Now it reports promised vs actual:
#
#   | loop | class | n | promised | actual | error | mean duration_s |
#
#   promised = mean of the proposals' forecast.p_success (integer %) over the
#              pairs that carry a numeric one; "-" when no pair in the group
#              carries one (old-tape rows, no forecast).
#   actual   = share of pairs with outcome bits.merged true/1, integer %
#              (unchanged from before)
#   error    = |promised - actual| in percentage points when promised is
#              present; "-" otherwise
#   n, mean duration_s unchanged; pairs without a forecast still count in
#   n and actual (old-tape rows are not dropped).
#
# The forecast lives on the PROPOSAL record (forecast.p_success), joined to the
# outcome via proposal_id — the same pairing as before (last outcome per
# proposal id, in tape order).
#
# Acceptance (read-only — no live services, no agents started, no state
# mutation; a hand-written tmp fixture tape exercises the tool, exactly as the
# issue asks):
#   1. a fixture with forecasts prints promised/actual/error as percents
#      (exact table row asserted)
#   2. a group with no forecast prints "-" for promised and error, and still
#      prints n and actual (old-tape rows not dropped)
#   3. empty tape: header row only, rc 0
#   4. `bats tests/calibration.bats` passes (the bats suite is the
#      regression net for the full table + edge cases)
#
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>). Uses tests/lib/acceptance-helpers.sh helpers.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq awk grep bats

TOOL="$REPO_ROOT/tools/calibration.sh"

# ── Shared table constants ────────────────────────────────────────────────────
# Exact output of the tool's header + separator row (no leading space).
HEADER=$'| loop | class | n | promised | actual | error | mean duration_s |\n|---|---|---|---|---|---|---|'

# Expected row for the forecast fixture: mean(0.5,0.7)=60%, 1/2 merged=50%,
# error |60-50|=10, mean duration (100+50)/2=75.0:
EXPECTED_FC_ROW=$'| dev | fix | 2 | 60% | 50% | 10 | 75.0 |'

# Expected row for the no-forecast group (1 pair, merged, dur 100):
EXPECTED_NA_ROW=$'| dev | fix | 1 | - | 100% | - | 100.0 |'

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Fixture builders ─────────────────────────────────────────────────────────

# A tape with forecasts: two dev/fix pairs.
#   p-1 forecast 0.5, merged, dur 100
#   p-2 forecast 0.7, not merged, dur 50
write_fixture_forecast() {
  cat > "$1/tape.jsonl" <<EOF
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.5,"est_cost":0,"est_dvision":0},"decision":"approved","ref":"1453-p1"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"p-1","bits":{"merged":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-02T00:00:00Z","id":"p-2","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.7,"est_cost":0,"est_dvision":0},"decision":"approved","ref":"1453-p2"}
{"type":"outcome","t":"2026-02-02T00:00:30Z","proposal_id":"p-2","bits":{"merged":0},"numbers":{"duration_s":50},"children":{},"payloads":[]}
EOF
}

# A tape with NO forecasts: one dev/fix pair, merged, dur 100. Old-tape row.
write_fixture_no_forecast() {
  cat > "$1/tape.jsonl" <<EOF
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"q-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1453-q1"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"q-1","bits":{"merged":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
EOF
}

# ── AC 1: fixture with forecasts → promised/actual/error as percents ─────────

ac_log "AC 1: forecast fixture → promised/actual/error percents"
TC_DIR="$TMP_DIR/tape-fc"
mkdir -p "$TC_DIR"
write_fixture_forecast "$TC_DIR"

rc=0
out="$(TAPE_DIR="$TC_DIR" bash "$TOOL")" || rc=$?
ac_assert_eq "$rc" "0" "forecast fixture must exit 0 (rc=$rc)"

# Full output must be header + separator + the single dev/fix data row.
expected="$HEADER
$EXPECTED_FC_ROW"
ac_assert_eq "$out" "$expected" \
  "forecast fixture must print header + 'n=2 promised=60% actual=50% error=10 mean=75.0', got: $out"

ac_log "AC 1 OK: forecast fixture reports promised/actual/error"

# ── AC 2: group with no forecast → '-' for promised/error, n/actual kept ─────

ac_log "AC 2: no-forecast group → '-' for promised/error, n+actual kept"
TC_DIR="$TMP_DIR/tape-na"
mkdir -p "$TC_DIR"
write_fixture_no_forecast "$TC_DIR"

rc=0
out="$(TAPE_DIR="$TC_DIR" bash "$TOOL")" || rc=$?
ac_assert_eq "$rc" "0" "no-forecast fixture must exit 0 (rc=$rc)"

expected="$HEADER
$EXPECTED_NA_ROW"
ac_assert_eq "$out" "$expected" \
  "no-forecast group must print header + 'n=1 promised=- actual=100% error=- mean=100.0', got: $out"

ac_log "AC 2 OK: old-tape rows keep n+actual, show '-' for promised/error"

# ── AC 3: empty tape → header row only, rc 0 ─────────────────────────────────

ac_log "AC 3: empty tape → header row only, rc 0"
TC_DIR="$TMP_DIR/tape-empty"
mkdir -p "$TC_DIR"
: > "$TC_DIR/tape.jsonl"

rc=0
out="$(TAPE_DIR="$TC_DIR" bash "$TOOL")" || rc=$?
ac_assert_eq "$rc" "0" "empty tape must exit 0 (rc=$rc)"
ac_assert_eq "$out" "$HEADER" \
  "empty tape must print the header row only, got: $out"

ac_log "AC 3 OK: empty tape → header only, rc 0"

# ── AC 4: `bats tests/calibration.bats` passes ───────────────────────────────

ac_log "AC 4: bats tests/calibration.bats passes"
# The bats suite is the regression net for the full table (multi-group,
# malformed-line skip, last-outcome-wins, sorting, read-only). It writes only
# to its own tmp workdir. bats exits 0 when every test passes.
bats_rc=0
bats_out="$(bats "$REPO_ROOT/tests/calibration.bats" 2>&1)" || bats_rc=$?
ac_assert_eq "$bats_rc" "0" "bats tests/calibration.bats must pass (rc=$bats_rc): $bats_out"

ac_log "AC 4 OK: bats suite green"

ac_pass
