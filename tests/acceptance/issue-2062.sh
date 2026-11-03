#!/usr/bin/env bash
# shellcheck disable=SC2154  # bats_rc/bats_out set by ac_run_bats_suite (tests/lib/acceptance-helpers.sh)
# =============================================================================
# tests/acceptance/issue-2062.sh
#
# Issue #2062: calibration rows are per (loop, class, model)
#
# tools/calibration.sh (#1393, extended #1451/#1473/#1525/#1526/#1605/#1614/
# #1649) grouped every sample pair by (loop, class), pooling rows served by
# different models into one line: on the live tape the dev/backlog row mixed
# 123 Qwen3.8-27B samples with 78 Grok 4.7 samples and 11 model-less ones, so
# its promised/actual/error was an artifact. #2059 built the proposal-id ->
# served-model map (tools/tape-model.sh) and #2061 made stuck samples carry
# the model; this issue groups on it: a model change starts a new row by
# itself. The table gains a `model` cell after `class`; a proposal with no
# model-bearing run and no backend prints `-`.
#
# Hermetic: no network, no forge, no agents, no writes. Per-scenario tmp
# TAPE_DIRs, fixture packs, fixed CALIBRATION_NOW.
#
# Acceptance:
#   AC1  dev/backlog: p1 merged:1 with a dsh/grok-4.7 run, p2 merged:1 and
#        p3 merged:0 with dsh/unsloth/Qwen3.8-27B runs, p4 merged:1 with no
#        run and no backend -> exactly three data rows, sorted by model
#        ("-", then grok-4.7, then unsloth/Qwen3.8-27B): n 1/1/2 and
#        actual 100%/100%/50%
#   AC2  stuck pack dev = 48 and a 72 h-old no-outcome p5 whose run is
#        dsh/grok-4.7 -> the grok-4.7 row reads n 2, actual 50%; the other
#        rows are unchanged
#   AC3  line 1 is the ten-column header and line 2 has ten `---|`
#   AC4  bash -n tools/calibration.sh passes; bats tests/calibration.bats
#        and tests/acceptance/issue-1649.sh pass
#
# Run via: tools/run-acceptance.sh 2062
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
ac_assert_file "$REPO_ROOT/tools/tape-model.sh" "tools/tape-model.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Fixture packs (hermetic, no ops repo involved) ────────────────────────────
PACKS="$TMP_DIR/packs"
mkdir -p "$PACKS"
cat > "$PACKS/loops.toml" <<'EOF'
dev = "merged"
EOF
cat > "$PACKS/stuck.toml" <<'EOF'
dev = 48
EOF

# Fixed clock: 2026-02-12 00:00:00 UTC. The stuck candidate p5 is 72 h old
# (2026-02-09), past the 48 h horizon.
export CALIBRATION_NOW="2026-02-12T00:00:00Z"
export CALIBRATION_LOOPS_FILE="$PACKS/loops.toml"

TOOL="$REPO_ROOT/tools/calibration.sh"
# Exact output of the tool's header + separator row (ten columns, #2062).
HEADER=$'| loop | class | model | n | promised | actual | error | mean duration_s | dur_promised | dur_error |\n|---|---|---|---|---|---|---|---|---|---|'

# run_calib_2062 <stuck-file> <tape-dir> — run calibration with the fixture
# loops pack, the given stuck pack and clock, and TAPE_DIR; stdout -> $OUT,
# stderr -> $ERR, exit status -> $RC. The tool's stdout never leaks onto the
# test's stdout, so the last stdout line stays PASS / FAIL: <reason>.
run_calib_2062() {
  local stuck="$1" dir="$2"
  RC=0
  OUT="$(CALIBRATION_STUCK_FILE="$stuck" CALIBRATION_NOW="$CALIBRATION_NOW" \
        TAPE_DIR="$dir" bash "$TOOL" 2> "$TMP_DIR/err.txt")" || RC=$?
  ERR="$(cat "$TMP_DIR/err.txt" 2>/dev/null || true)"
}

# The base tape: p1 (grok-4.7 run, merged), p2 + p3 (unsloth/Qwen3.8-27B runs,
# merged 1 and 0), p4 (merged, no run, no backend). No stuck pack in play.
write_base_tape() {
  local dir="$1"
  printf '%s\n' \
    '{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p1","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2062-p1"}' \
    '{"type":"run","t":"2026-02-01T00:00:30Z","proposal_id":"p1","agent":"dsh/grok-4.7"}' \
    '{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p1","bits":{"merged":1},"children":{},"payloads":[]}' \
    '{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p2","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2062-p2"}' \
    '{"type":"run","t":"2026-02-01T00:00:30Z","proposal_id":"p2","agent":"dsh/unsloth/Qwen3.8-27B"}' \
    '{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p2","bits":{"merged":1},"children":{},"payloads":[]}' \
    '{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p3","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2062-p3"}' \
    '{"type":"run","t":"2026-02-01T00:00:30Z","proposal_id":"p3","agent":"dsh/unsloth/Qwen3.8-27B"}' \
    '{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p3","bits":{"merged":0},"children":{},"payloads":[]}' \
    '{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p4","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2062-p4"}' \
    '{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p4","bits":{"merged":1},"children":{},"payloads":[]}' >> "$dir/tape.jsonl"
}

# ── AC 1: one row per model; the model-less proposal gets its own "-" row ─────

ac_log "AC 1: p1 grok-4.7, p2+p3 Qwen3.8-27B, p4 model-less -> three rows, per (loop, class, model)"
TC="$TMP_DIR/tape-models"
mkdir -p "$TC"
: > "$TC/tape.jsonl"
write_base_tape "$TC"
run_calib_2062 "$TMP_DIR/none.toml" "$TC"
ac_assert_eq "$RC" "0" "AC 1: must exit 0 (rc=$RC, err: $ERR)"
expected="$HEADER
| dev | backlog | - | 1 | - | 100% | - | - | - | - |
| dev | backlog | grok-4.7 | 1 | - | 100% | - | - | - | - |
| dev | backlog | unsloth/Qwen3.8-27B | 2 | - | 50% | - | - | - | - |"
ac_assert_eq "$OUT" "$expected" \
  "AC 1: expected three model rows in order (-, grok-4.7, unsloth/Qwen3.8-27B), got: $OUT"
data_rows="$(printf '%s\n' "$OUT" | tail -n +3 | grep -c '' || true)"
ac_assert_eq "$data_rows" "3" "AC 1: exactly three data rows expected (got $data_rows): $OUT"
ac_log "AC 1 OK: rows split by the model that served the run"

# ── AC 2: a stuck sample joins its proposal's model row ───────────────────────

ac_log "AC 2: stuck pack dev=48 + 72 h-old no-outcome p5 with a grok-4.7 run -> grok row n 2 actual 50%"
TC="$TMP_DIR/tape-stuck"
mkdir -p "$TC"
: > "$TC/tape.jsonl"
write_base_tape "$TC"
printf '%s\n' \
  '{"type":"proposal","t":"2026-02-09T00:00:00Z","id":"p5","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2062-p5"}' \
  '{"type":"run","t":"2026-02-09T00:00:30Z","proposal_id":"p5","agent":"dsh/grok-4.7"}' >> "$TC/tape.jsonl"
run_calib_2062 "$PACKS/stuck.toml" "$TC"
ac_assert_eq "$RC" "0" "AC 2: must exit 0 (rc=$RC, err: $ERR)"
expected="$HEADER
| dev | backlog | - | 1 | - | 100% | - | - | - | - |
| dev | backlog | grok-4.7 | 2 | - | 50% | - | - | - | - |
| dev | backlog | unsloth/Qwen3.8-27B | 2 | - | 50% | - | - | - | - |"
ac_assert_eq "$OUT" "$expected" \
  "AC 2: expected the stuck p5 folded into the grok-4.7 row (n 2 actual 50%), got: $OUT"
ac_log "AC 2 OK: stuck samples carry the model of their proposal (#2061)"

# ── AC 3: the header itself ────────────────────────────────────────────────────

ac_log "AC 3: line 1 is the ten-column header, line 2 has ten ---| cells"
TC="$TMP_DIR/tape-header"
mkdir -p "$TC"
: > "$TC/tape.jsonl"
run_calib_2062 "$TMP_DIR/none.toml" "$TC"
line1="$(printf '%s\n' "$OUT" | head -n 1)"
line2="$(printf '%s\n' "$OUT" | sed -n 2p)"
ac_assert_eq "$line1" '| loop | class | model | n | promised | actual | error | mean duration_s | dur_promised | dur_error |' \
  "AC 3: line 1 must be the ten-column header, got: $line1"
ac_assert_eq "$line2" '|---|---|---|---|---|---|---|---|---|---|' \
  "AC 3: line 2 must carry ten ---| separators, got: $line2"
ac_log "AC 3 OK: header carries the model column"

# ── AC 4: lint + regression suites pass ────────────────────────────────────────

ac_log "AC 4: bash -n tools/calibration.sh"
bash -n "$REPO_ROOT/tools/calibration.sh" || ac_fail "AC 4: bash -n failed on tools/calibration.sh"

ac_log "AC 4: bats tests/calibration.bats"
command -v bats >/dev/null 2>&1 || ac_fail "AC 4: bats is required to run tests/calibration.bats"
ac_run_bats_suite "$REPO_ROOT/tests/calibration.bats"
ac_assert_eq "$bats_rc" "0" "AC 4: bats tests/calibration.bats must pass (rc=$bats_rc): $bats_out"

ac_log "AC 4: tests/acceptance/issue-1649.sh"
ac1649_rc=0
ac1649_out="$(bash "$REPO_ROOT/tests/acceptance/issue-1649.sh" 2>&1)" || ac1649_rc=$?
ac_assert_eq "$ac1649_rc" "0" "AC 4: tests/acceptance/issue-1649.sh must pass (rc=$ac1649_rc): $ac1649_out"

ac_log "AC 4 OK: syntax, bats suite and issue-1649 acceptance all pass"

ac_pass
