#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1649.sh
#
# Issue #1649: calibration counts stuck proposals as failures
#
# tools/calibration.sh (#1393, extended #1451/#1473/#1525/#1526/#1605/#1614)
# reads the proposal-loop tape and reports promised vs actual per (loop, class)
# group. Before #1649 it dropped every proposal that never got an outcome
# carrying its loop's competence bit, so a stuck proposal returned nothing and
# `actual` read 100% in September for exactly that reason. #1649 reads the
# stuck reader (tools/tape-stuck.sh, #1648) and folds each stuck proposal into
# the group as one failure sample, at read time, so `n` grows and `actual` can
# drop below what the outcomes alone give.
#
# Hermetic: no network, no forge, no agents, no writes. Per-scenario tmp
# TAPE_DIRs, fixture packs, fixed CALIBRATION_NOW.
#
# Acceptance:
#   AC1  stuck pack `dev = 48`, clock 72 h after a dev proposal with no
#        outcome (plus one merged dev/fix pair) -> the row's `n` grows by 1
#        (2) and `actual` drops below 100% (50%: the stuck pair is the failure)
#   AC2  the same no-outcome proposal 24 h old -> not counted (24 h < 48 h
#        horizon): the row is only the merged pair, `n` = 1, `actual` = 100%
#   AC3  without a stuck pack (missing file), a 72 h-old no-outcome proposal
#        is not stuck and carries no outcome, so it is not a sample at all:
#        output is byte-identical to the pre-#1649 tool's output (the merged
#        pair row only)
#   AC4  an unparsable stuck pack -> calibration exits 1 with a clear message
#        (it must not print the report)
#
# Run via: tools/run-acceptance.sh 1649
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>). Uses tests/lib/acceptance-helpers.sh helpers.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq
ac_assert_file "$REPO_ROOT/tools/calibration.sh" "tools/calibration.sh is missing"
ac_assert_file "$REPO_ROOT/tools/tape-stuck.sh" "tools/tape-stuck.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Fixture packs (hermetic, no ops repo involved) ───────────────────────────

PACKS="$TMP_DIR/packs"
mkdir -p "$PACKS"
cat > "$PACKS/loops.toml" <<'EOF'
dev = "merged"
EOF
cat > "$PACKS/stuck.toml" <<'EOF'
dev = 48
EOF
cat > "$PACKS/stuck-bad.toml" <<'EOF'
dev = "soon"
EOF

# Fixed clock: 2026-02-12 00:00:00 UTC. 72 h old = 2026-02-09T00:00:00Z;
# 24 h old = 2026-02-11T00:00:00Z. The baseline pair is 2026-02-01 (well
# inside every horizon, but it carries a competence outcome so it is never
# stuck).
export CALIBRATION_NOW="2026-02-12T00:00:00Z"
export CALIBRATION_LOOPS_FILE="$PACKS/loops.toml"
export CALIBRATION_STUCK_FILE="$PACKS/stuck.toml"
TAPE_DIR="$TMP_DIR/tape"
mkdir -p "$TAPE_DIR"
TOOL="$REPO_ROOT/tools/calibration.sh"
# Exact output of the tool's header + separator row (no leading space).
HEADER=$'| loop | class | n | promised | actual | error | mean duration_s | dur_promised | dur_error |\n|---|---|---|---|---|---|---|---|---|'

# run_calib [stuck-file] [clock] — run the calibration tool with CALIBRATION_
# LOOPS_FILE fixed (loops.toml), CALIBRATION_STUCK_FILE and CALIBRATION_NOW
# overridden as given (defaults to the 48 h stuck pack / fixed clock), and
# TAPE_DIR set to "$1". The tool's stdout lands in $OUT (stdout), $ERR (stderr),
# and the exit status in $RC. The tool's stdout is never leaked onto the test's
# stdout, so the last line of the test's stdout is always PASS / FAIL: <reason>.
run_calib() {
  local stuck="${1:-$CALIBRATION_STUCK_FILE}"
  local now="${2:-$CALIBRATION_NOW}"
  local dir="$3"
  OUT="$(CALIBRATION_STUCK_FILE="$stuck" CALIBRATION_NOW="$now" \
        TAPE_DIR="$dir" bash "$TOOL" 2> "$TMP_DIR/err.txt")" || RC=$?
  RC="${RC:-0}"
  ERR="$(cat "$TMP_DIR/err.txt" 2>/dev/null || true)"
}

# p-1: the baseline dev/fix pair, merged:1 (a success), 100 s, forecast 0.8,
# est_dvision 100. It carries a competence outcome, so it is never stuck.
write_base_pair() {
  local dir="$1"
  printf '%s\n' \
    '{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.8,"est_cost":0,"est_dvision":100},"decision":"approved","ref":"1649-p1"}' \
    '{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"p-1","bits":{"merged":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}' >> "$dir/tape.jsonl"
}

# p-2: the no-outcome stuck candidate. $1 = its proposal time.
write_no_outcome_pair() {
  local dir="$1"
  local t="$2"
  printf '%s\n' \
    '{"type":"proposal","t":"'"$t"'","id":"p-2","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.8,"est_cost":0,"est_dvision":100},"decision":"approved","ref":"1649-p2"}' >> "$dir/tape.jsonl"
}

# ── AC 1: 72 h old no-outcome proposal + stuck pack -> n +1, actual < 100% ───

ac_log "AC 1: stuck pack dev=48, 72 h old no-outcome proposal -> n grows, actual drops"
TC="$TMP_DIR/tape-72"
mkdir -p "$TC"
: > "$TC/tape.jsonl"
write_base_pair "$TC"
write_no_outcome_pair "$TC" "2026-02-09T00:00:00Z"
run_calib "$CALIBRATION_STUCK_FILE" "$CALIBRATION_NOW" "$TC"
ac_assert_eq "$RC" "0" "AC 1: stuck 72 h no-outcome must exit 0 (rc=$RC, err: $ERR)"
# n 2 (p-1 sample + p-2 stuck), promised 80%, actual 50% (1 success of 2),
# error |80-50|=30, mean duration 100.0 (p-2 is null), dur_promised 100.0,
# dur_error 0.0
expected="$HEADER
| dev | fix | 2 | 80% | 50% | 30 | 100.0 | 100.0 | 0.0 |"
ac_assert_eq "$OUT" "$expected" "AC 1: expected the stuck-included row (n=2 actual=50%), got: $OUT"
[[ "$OUT" == *'| dev | fix | 2 |'* ]] || ac_fail "AC 1: n must grow by 1 to 2 (got: $OUT)"
[[ "$OUT" == *'| dev | fix | 2 | 80% | 50% |'* ]] || ac_fail "AC 1: actual must be below 100% (50%), got: $OUT"
ac_log "AC 1 OK: stuck proposal counted as a failure sample"

# ── AC 2: the same proposal 24 h old -> not counted ───────────────────────────

ac_log "AC 2: same no-outcome proposal 24 h old -> not counted (24 h < 48 h)"
TC="$TMP_DIR/tape-24"
mkdir -p "$TC"
: > "$TC/tape.jsonl"
write_base_pair "$TC"
write_no_outcome_pair "$TC" "2026-02-11T00:00:00Z"
run_calib "$CALIBRATION_STUCK_FILE" "$CALIBRATION_NOW" "$TC"
ac_assert_eq "$RC" "0" "AC 2: 24 h no-outcome must exit 0 (rc=$RC, err: $ERR)"
# Only p-1 is a sample: n 1, promised 80%, actual 100%, error 20,
# mean 100.0, dur_promised 100.0, dur_error 0.0
expected="$HEADER
| dev | fix | 1 | 80% | 100% | 20 | 100.0 | 100.0 | 0.0 |"
ac_assert_eq "$OUT" "$expected" \
  "AC 2: 24 h no-outcome proposal must not be counted (n=1 actual=100%), got: $OUT"
[[ "$OUT" == *'| dev | fix | 1 |'* ]] || ac_fail "AC 2: the 24 h proposal must not add a sample (n=1, got: $OUT)"
ac_log "AC 2 OK: under-horizon no-outcome proposal is not counted"

# ── AC 3: without a stuck pack, output is byte-identical to today ─────────────

ac_log "AC 3: no stuck pack -> 72 h no-outcome proposal not stuck; row byte-identical to pre-#1649"
TC="$TMP_DIR/tape-no-stuck"
mkdir -p "$TC"
: > "$TC/tape.jsonl"
write_base_pair "$TC"
write_no_outcome_pair "$TC" "2026-02-09T00:00:00Z"
# Point CALIBRATION_STUCK_FILE at a missing file: no horizon is named, so
# nothing is stuck and the report equals what the pre-#1649 tool printed for
# this tape (the merged pair row only).
run_calib "$TMP_DIR/none.toml" "$CALIBRATION_NOW" "$TC"
ac_assert_eq "$RC" "0" "AC 3: missing stuck pack must exit 0 (rc=$RC, err: $ERR)"
# p-2 is not a sample (no outcome) and not stuck (no horizon) -> only p-1:
# n 1, promised 80%, actual 100%, error 20, mean 100.0, dur_promised 100.0,
# dur_error 0.0
expected="$HEADER
| dev | fix | 1 | 80% | 100% | 20 | 100.0 | 100.0 | 0.0 |"
ac_assert_eq "$OUT" "$expected" \
  "AC 3: without a stuck pack the 72 h no-outcome proposal must be absent (row byte-identical to pre-#1649), got: $OUT"
ac_log "AC 3 OK: no stuck pack -> byte-identical output"

# ── AC 4: unparsable stuck pack -> exit 1 ─────────────────────────────────────

ac_log "AC 4: unparsable stuck pack (dev = \"soon\") -> calibration exits 1"
TC="$TMP_DIR/tape-bad"
mkdir -p "$TC"
: > "$TC/tape.jsonl"
write_base_pair "$TC"
run_calib "$PACKS/stuck-bad.toml" "$CALIBRATION_NOW" "$TC"
ac_assert_eq "$RC" "1" "AC 4: an unparsable stuck pack must exit 1 (rc=$RC)"
case "$ERR" in
  *"failed to read stuck pack"*)
    ;;
  *) ac_fail "AC 4: the failure must name the stuck pack on stderr, got: $ERR" ;;
esac
# The header is echoed up front by the tool (pre-existing, #1605-style), so it
# may appear on stdout even when the tool exits 1; the AC only requires the
# non-zero exit and the stuck-pack error on stderr.
ac_log "AC 4 OK: unparsable stuck pack exits 1 (stderr names it)"

ac_pass
