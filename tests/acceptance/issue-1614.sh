#!/usr/bin/env bash
# shellcheck disable=SC2154  # rc/out/err_out/HEADER/TMP_DIR set by ac_calib_env (tests/lib/acceptance-helpers.sh)
# =============================================================================
# tests/acceptance/issue-1614.sh
#
# Issue #1614: a loops-pack entry may name several competence bits.
#
# Before #1605 each loop's competence bit was hardcoded; #1605 moved it into
# the pack ($CALIBRATION_LOOPS_FILE) as one `loop = "bit"` assignment per
# loop. #1614 relaxes that value: it may now be either
#
#   - a single double-quoted name,     `loop = "bit"`, or
#   - a TOML array of one or more double-quoted names,
#         `loop = ["bit1", "bit2"]`
#
# A single string stays valid and means a one-element array, so pre-#1614
# packs behave identically. Sample rule (unchanged shape, wider content): a
# pair is a sample when its LAST outcome carries at least one listed bit
# (true/false/1/0); it is a success when any listed bit is true/1, otherwise
# a failure. Any other value shape is an unparsable pack (exit 1, as today).
#
# Acceptance (hermetic — no network, no forge, no agents started, no writes;
# hand-written tmp fixture packs + tape, exactly as the issue asks):
#   1. a multi-bit pack `dev = ["merged", "rejected"]` makes
#        {merged:0, rejected:1} a success,
#        {merged:0}            a failure,
#        {exit_ok:1}           not a sample (bit not listed).
#      n counts only the samples; the row is asserted exactly.
#   2. a single string `dev = "merged"` and the one-element array
#      `dev = ["merged"]` emit identical rows ("a single string stays valid and
#      means a one-element array").
#   3. an unquoted array `dev = [merged]` is an unparsable pack -> non-zero
#      exit with a clear message.
#   4. `bash tests/calibration.bats` passes (regression net for the full table
#      and the unchanged single-string packs).
#   5. `bash tests/acceptance/issue-1614.sh` exits 0 and calls ac_pass.
#
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>). Uses tests/lib/acceptance-helpers.sh helpers.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq awk bats

# Shared calibration environment (TMP_DIR/trap, TOOL, the table HEADER, the
# rc/out/err_out run state, and the per-run pack runner run_calib) — the single
# definition lives in tests/lib/acceptance-helpers.sh so the two per-pack tests
# do not duplicate it file-to-file.
ac_calib_env
bats_rc=0
bats_out=""

# Fixture packs. Multi-bit names two competence bits for dev (the #1614 shape);
# the single/one-element packs are the pre-#1614 form read as a one-element
# array; the unquoted pack must be rejected.
mkdir -p "$TMP_DIR/packs"
cat > "$TMP_DIR/packs/multi-bit.toml" <<'EOF'
dev = ["merged", "rejected"]
EOF
cat > "$TMP_DIR/packs/single-string.toml" <<'EOF'
dev = "merged"
EOF
cat > "$TMP_DIR/packs/one-element.toml" <<'EOF'
dev = ["merged"]
EOF
cat > "$TMP_DIR/packs/unquoted.toml" <<'EOF'
dev = [merged]
EOF

# Shared tape: four dev/fix pairs.
#   d1 last outcome {merged:0, rejected:1} -> sample (rejected listed);
#       success under multi-bit, FAILURE under single/one-element (merged:0).
#   d2 last outcome {merged:0}               -> sample; failure under both.
#   d3 last outcome {exit_ok:1}             -> exit_ok is not listed: never a
#                                             sample under either pack.
#   d4 last outcome {merged:1}               -> sample; success under both.
# Every proposal carries p_success 0.5 and est_dvision 80 so promised/dur_promised
# print for the sampled pairs; durations are 50/70/100/90 so the multi-bit
# sample mean (50+70+90)/3 and the single-string sample mean are both 70.0.
write_tape() {
  local dir="$1"
  cat > "$dir/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"d-1","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.5,"est_cost":0,"est_dvision":80},"decision":"approved","ref":"1614-d1"}
{"type":"outcome","t":"2026-02-01T00:00:30Z","proposal_id":"d-1","bits":{"merged":0,"rejected":1},"numbers":{"duration_s":50},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:01Z","id":"d-2","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.5,"est_cost":0,"est_dvision":80},"decision":"approved","ref":"1614-d2"}
{"type":"outcome","t":"2026-02-01T00:00:40Z","proposal_id":"d-2","bits":{"merged":0},"numbers":{"duration_s":70},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:02Z","id":"d-3","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.5,"est_cost":0,"est_dvision":80},"decision":"approved","ref":"1614-d3"}
{"type":"outcome","t":"2026-02-01T00:00:50Z","proposal_id":"d-3","bits":{"exit_ok":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:03Z","id":"d-4","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.5,"est_cost":0,"est_dvision":80},"decision":"approved","ref":"1614-d4"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"d-4","bits":{"merged":1},"numbers":{"duration_s":90},"children":{},"payloads":[]}
EOF
}


write_tape "$TMP_DIR"

# ── AC 1: multi-bit pack: {merged:0,rejected:1} success, {merged:0} failure,
#        {exit_ok:1} not a sample ─────────────────────────────────────────────
ac_log "AC 1: multi-bit pack makes rejected:1 a success, merged:0 a failure, exit_ok:1 not a sample"
run_calib "$TMP_DIR/packs/multi-bit.toml" "$TMP_DIR"
ac_assert_eq "$rc" "0" "AC 1: multi-bit pack must exit 0 (rc=$rc)"
# Samples d1(success), d2(failure), d4(success) -> n 3, actual 67%,
# promised 50%, error |50-67| = 17, mean (50+70+90)/3 = 70.0,
# dur_promised 80.0, dur_error |80.0-70.0| = 10.0
expected="$HEADER
| dev | fix | 3 | 50% | 67% | 17 | 70.0 | 80.0 | 10.0 |"
ac_assert_eq "$out" "$expected" \
  "AC 1: expected the multi-bit row (n=3 excludes {exit_ok:1}), got: $out"
[[ "$out" == *'| dev | fix | 3 |'* ]] \
  || ac_fail "AC 1: n must be 3 (the {exit_ok:1} pair is not a sample)"
ac_log "AC 1 OK: multi-bit sampling rule"

# ── AC 2: single string == one-element array (backward compatibility) ────────
ac_log "AC 2: single string and one-element array emit identical rows"
run_calib "$TMP_DIR/packs/single-string.toml" "$TMP_DIR"
ac_assert_eq "$rc" "0" "AC 2: single-string pack must exit 0 (rc=$rc)"
# Under a single/one-element `merged` pack, d1 (merged:0) is a FAILURE — the
# rejected:1 bit is not listed — d2 failure, d4 success -> n 3, actual 33%
single_expected="$HEADER
| dev | fix | 3 | 50% | 33% | 17 | 70.0 | 80.0 | 10.0 |"
ac_assert_eq "$out" "$single_expected" \
  "AC 2: single-string must match pre-#1614 rows, got: $out"

run_calib "$TMP_DIR/packs/one-element.toml" "$TMP_DIR"
ac_assert_eq "$rc" "0" "AC 2: one-element array must exit 0 (rc=$rc)"
ac_assert_eq "$out" "$single_expected" \
  "AC 2: one-element array must equal the single-string rows, got: $out"
ac_log "AC 2 OK: a single string is valid and means a one-element array"

# ── AC 3: unquoted array is an unparsable pack -> non-zero exit ─────────────
ac_log "AC 3: unquoted array -> non-zero exit + clear message"
run_calib "$TMP_DIR/packs/unquoted.toml" "$TMP_DIR"
[ "$rc" -ne 0 ] || ac_fail "AC 3: an unquoted array must exit non-zero (rc=$rc)"
case "$err_out" in
  *unparsable*|*pack*)
    ;;
  *) ac_fail "AC 3: unparsable array must print a clear message on stderr, got: $err_out" ;;
esac
ac_log "AC 3 OK: rc=$rc, stderr: $err_out"

# ── AC 4: `bats tests/calibration.bats` passes ───────────────────────────────
ac_log "AC 4: bats tests/calibration.bats passes"
ac_run_bats_suite "$REPO_ROOT/tests/calibration.bats"
ac_assert_eq "$bats_rc" "0" \
  "bats tests/calibration.bats must pass (rc=$bats_rc): $bats_out"
ac_log "AC 4 OK: bats suite green"

ac_pass
