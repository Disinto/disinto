#!/usr/bin/env bash
# shellcheck disable=SC2154  # rc/out/err_out/HEADER/TMP_DIR set by ac_calib_env (tests/lib/acceptance-helpers.sh)
# =============================================================================
# tests/acceptance/issue-1605.sh
#
# Issue #1605: calibration reads the loop->competence-bit mapping from a pack
# file instead of hardcoding dev/repair in jq.
#
# The pack is a flat TOML — one `loop = "bit"` assignment per loop — read
# from $CALIBRATION_LOOPS_FILE (default:
# ${OPS_REPO_ROOT:-.../_factory/disinto-ops}/packs/loops.toml). The pack
# decides which loops are samples and names each loop's .bits key. A loop
# absent from the pack is never a sample. A missing or unparsable pack exits
# non-zero with a clear message: there is no fallback to a hardcoded loop->bit
# map.
#
# Acceptance (hermetic — no network, no forge, no agents started, no writes;
# hand-written tmp fixture packs + tape, exactly as the issue asks):
#   1. a pack naming research = "report_present" makes a research row appear
#      without editing calibration.sh (standard dev/repair rows remain).
#   2. a loop absent from the pack produces no row.
#   3. a missing pack file exits non-zero with a clear message.
#   4. `bash tests/acceptance/issue-1605.sh` exits 0 and calls ac_pass.
#
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>). Uses tests/lib/acceptance-helpers.sh helpers.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq awk

# Shared calibration environment (TMP_DIR/trap, TOOL, the table HEADER, the
# rc/out/err_out run state, and the per-run pack runner run_calib) — the single
# definition lives in tests/lib/acceptance-helpers.sh so the two per-pack tests
# do not duplicate it file-to-file.
ac_calib_env

# Fixture packs (loop = "bit"). `with-research` names research so AC 1 can show
# the row appears purely from the pack; `without-research` does not (AC 2).
mkdir -p "$TMP_DIR/packs"
cat > "$TMP_DIR/packs/with-research.toml" <<'EOF'
dev = "merged"
repair = "regression_cleared"
research = "report_present"
EOF
cat > "$TMP_DIR/packs/without-research.toml" <<'EOF'
dev = "merged"
repair = "regression_cleared"
EOF

# Shared tape: two research pairs (report_present 1 then 0 -> actual 50%), one
# dev (merged 1), one repair (regression_cleared 1), and one PLANNER pair whose
# loop is absent from every fixture pack (never a row in AC 1 or 2).
write_tape() {
  local dir="$1"
  cat > "$dir/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"r-1","loop":"research","class":"docs","context":{},"decision":"approved","ref":"1605-r1"}
{"type":"outcome","t":"2026-02-01T00:00:30Z","proposal_id":"r-1","bits":{"report_present":1},"numbers":{"duration_s":30},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:01Z","id":"r-2","loop":"research","class":"docs","context":{},"decision":"approved","ref":"1605-r2"}
{"type":"outcome","t":"2026-02-01T00:00:50Z","proposal_id":"r-2","bits":{"report_present":0},"numbers":{"duration_s":50},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:02Z","id":"d-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1605-d1"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"d-1","bits":{"merged":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:03Z","id":"p-1","loop":"repair","class":"incident","context":{},"decision":"approved","ref":"1605-p1"}
{"type":"outcome","t":"2026-02-01T00:01:50Z","proposal_id":"p-1","bits":{"regression_cleared":1},"numbers":{"duration_s":50},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:04Z","id":"pl-1","loop":"planner","class":"docs","context":{},"decision":"approved","ref":"1605-pl1"}
{"type":"outcome","t":"2026-02-01T00:01:05Z","proposal_id":"pl-1","bits":{"plan_present":1},"numbers":{"duration_s":5},"children":{},"payloads":[]}
EOF
}


write_tape "$TMP_DIR"

# ── AC 1: research row appears when the pack names research (no tool edit) ──
ac_log "AC 1: research row appears via the pack (no calibration.sh edit); planner (absent) -> no row"
run_calib "$TMP_DIR/packs/with-research.toml" "$TMP_DIR"
ac_assert_eq "$rc" "0" "AC 1: with-research pack must exit 0 (rc=$rc)"
# research = 2 pairs (report_present 1 then 0) -> n 2, actual 50%, mean (30+50)/2 = 40.0
# dev -> merged 1 -> n 1, actual 100%, mean 100.0; repair -> regression_cleared 1 -> mean 50.0
expected="$HEADER
| dev | fix | 1 | - | 100% | - | 100.0 | - | - |
| repair | incident | 1 | - | 100% | - | 50.0 | - | - |
| research | docs | 2 | - | 50% | - | 40.0 | - | - |"
ac_assert_eq "$out" "$expected" "AC 1: expected the research/dev/repair rows, got: $out"
[[ "$out" == *'| research | docs |'* ]] || ac_fail "AC 1: the research row must appear when named in the pack"
[[ "$out" == *'| planner | docs |'* ]] && ac_fail "AC 1: planner (absent from the pack) must not appear"
ac_log "AC 1 OK: research row appears without editing the tool"

# ── AC 2: a loop absent from the pack produces no row ────────────────────────
ac_log "AC 2: research absent from the pack -> no research row (planner too)"
run_calib "$TMP_DIR/packs/without-research.toml" "$TMP_DIR"
ac_assert_eq "$rc" "0" "AC 2: without-research pack must exit 0 (rc=$rc)"
expected="$HEADER
| dev | fix | 1 | - | 100% | - | 100.0 | - | - |
| repair | incident | 1 | - | 100% | - | 50.0 | - | - |"
ac_assert_eq "$out" "$expected" "AC 2: expected only dev/repair rows, got: $out"
[[ "$out" == *'| research | docs |'* ]] && ac_fail "AC 2: research must NOT appear when absent from the pack"
ac_log "AC 2 OK: an absent loop is never a sample"

# ── AC 3: a missing pack file exits non-zero with a clear message ────────────
ac_log "AC 3: missing pack file -> non-zero exit + clear message"
run_calib "$TMP_DIR/packs/does-not-exist.toml" "$TMP_DIR"
[ "$rc" -ne 0 ] || ac_fail "AC 3: a missing loops pack file must exit non-zero (rc=$rc)"
case "$err_out" in
  *missing*|*pack*)
    ;;
  *) ac_fail "AC 3: missing pack must print a clear message on stderr, got: $err_out" ;;
esac
ac_log "AC 3 OK: rc=$rc, stderr: $err_out"

ac_pass
