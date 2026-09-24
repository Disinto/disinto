#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1526.sh
#
# Issue #1526: calibration shows duration forecast error.
#
# Two new columns were appended to tools/calibration.sh's table (fields 9/10,
# existing fields 2–8 untouched and in the same order):
#
#   | loop | class | n | promised | actual | error | mean duration_s | dur_promised | dur_error |
#
#   - dur_promised  mean of the sample pairs' proposal forecast.est_dvision
#                   (seconds) over the pairs whose value is numeric AND greater
#                   than 0, one decimal; 0 (the pre-#1525 stub) and a missing
#                   value are never counted, so the old stubs never masquerade
#                   as a zero-duration forecast. "-" when no sample pair in the
#                   group carries a positive one.
#   - dur_error     |dur_promised - mean duration_s|, one decimal, when both
#                   are present; "-" otherwise.
#
# Acceptance (hermetic — no network, no forge, no agents started, no writes;
# hand-written tmp fixture tapes exercise the tool, exactly as the issue asks):
#   1. two dev/fix pairs, both merged:1, durations 100/50, est_dvision 80/40
#      -> the dev|fix row contains | 60.0 | 15.0 | (mean 60.0, gap to 75.0)
#   2. a third dev/fix pair carrying est_dvision 0 (merged:1, NO duration) does
#      not change dur_promised: it must stay 60.0 (not 40.0) and mean duration
#      must stay 75.0 (not 58.3); n grows to 3
#   3. empty tape -> header row only, rc 0
#   4. `bats tests/calibration.bats` passes (regression net for the full table)
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
HEADER=$'| loop | class | n | promised | actual | error | mean duration_s | dur_promised | dur_error |\n|---|---|---|---|---|---|---|---|---|'

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Global state populated by the sourced helpers: ac_run_tape_tool writes rc/out
# (and TC_DIR), ac_run_bats_suite writes bats_rc/bats_out. Initialised up front
# so the `set -u` guard and every ac_assert_eq reference below are always
# defined (ShellCheck cannot see cross-file global assignment).
rc=0
out=""
bats_rc=0
bats_out=""

# ── Fixture builders ──────────────────────────────────────────────────────────

# AC 1 tape: two dev/fix pairs, both merged:1, durations 100/50,
# est_dvision 80/40. Both carry a numeric p_success (0.5) so promised prints.
write_ac1_tape() {
  cat > "$1/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.5,"est_cost":0,"est_dvision":80},"decision":"approved","ref":"1526-p1"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"p-1","bits":{"merged":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-2","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.5,"est_cost":0,"est_dvision":40},"decision":"approved","ref":"1526-p2"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-2","bits":{"merged":1},"numbers":{"duration_s":50},"children":{},"payloads":[]}
EOF
}

# AC 2 tape: AC 1's two pairs plus a third dev/fix pair whose forecast carries
# the pre-#1525 est_dvision 0 stub and whose last outcome (merged:1) carries
# NO duration_s. The 0 stub must never be counted in dur_promised and the
# missing duration must never be counted as a zero in the mean — both columns
# are unchanged by the extra row.
write_ac2_tape() {
  cat > "$1/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-1","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.5,"est_cost":0,"est_dvision":80},"decision":"approved","ref":"1526-p1"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"p-1","bits":{"merged":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-2","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.5,"est_cost":0,"est_dvision":40},"decision":"approved","ref":"1526-p2"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p-2","bits":{"merged":1},"numbers":{"duration_s":50},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p-3","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.5,"est_cost":0,"est_dvision":0},"decision":"approved","ref":"1526-p3"}
{"type":"outcome","t":"2026-02-01T00:01:01Z","proposal_id":"p-3","bits":{"merged":1},"children":{},"payloads":[]}
EOF
}

# ── AC 1: two positive-forecast pairs -> | 60.0 | 15.0 | ─────────────────────

ac_log "AC 1: two dev/fix pairs (est_dvision 80/40, durations 100/50) -> | 60.0 | 15.0 |"
ac_run_tape_tool tape-ac1 write_ac1_tape "$TOOL"
ac_assert_eq "$rc" "0" "AC 1 fixture must exit 0 (rc=$rc)"

# dur_promised = mean(80, 40) = 60.0; mean duration_s = (100+50)/2 = 75.0;
# dur_error = |60.0 - 75.0| = 15.0. The row must contain | 60.0 | 15.0 |.
expected="$HEADER
| dev | fix | 2 | 50% | 100% | 50 | 75.0 | 60.0 | 15.0 |"
ac_assert_eq "$out" "$expected" \
  "AC 1 must print the dev|fix row ending | 60.0 | 15.0 |, got: $out"
[[ "$out" == *"| 60.0 | 15.0 |"* ]] \
  || ac_fail "AC 1: the dev|fix row must contain the exact cells | 60.0 | 15.0 |"
ac_log "AC 1 OK: dur_promised 60.0, dur_error 15.0"

# ── AC 2: adding a third est_dvision 0 pair must NOT change 60.0 ─────────────

ac_log "AC 2: third pair with est_dvision 0 + no duration leaves dur_promised 60.0 (n=3)"
ac_run_tape_tool tape-ac2 write_ac2_tape "$TOOL"
ac_assert_eq "$rc" "0" "AC 2 fixture must exit 0 (rc=$rc)"

# n grows to 3; promised 50% (three 0.5 forecasts), actual 100% (all merged:1);
# error |50-100| = 50. The 0-stub is excluded from dur_promised (still 60.0,
# not 40.0 = mean(80,40,0)/3) and the missing duration is excluded from the
# mean (still 75.0, not 58.3 = mean(100,50,0)); dur_error stays |60.0-75.0| =
# 15.0.
expected="$HEADER
| dev | fix | 3 | 50% | 100% | 50 | 75.0 | 60.0 | 15.0 |"
ac_assert_eq "$out" "$expected" \
  "AC 2 must keep | 60.0 | 15.0 | after adding an est_dvision 0 pair, got: $out"
[[ "$out" == *"| 60.0 | 15.0 |"* ]] \
  || ac_fail "AC 2: the zero-est_dvision third pair must not change dur_promised to 40.0"
ac_log "AC 2 OK: zero-est_dvision stub and missing duration are never counted"

# ── AC 3: empty tape -> header row only, rc 0 ─────────────────────────────────

ac_log "AC 3: empty tape -> header row only, rc 0"
EMPTY_DIR="$TMP_DIR/tape-0"
ac_run_empty_tape "$EMPTY_DIR" "$TOOL"
ac_assert_eq "$rc" "0" "empty tape must exit 0 (rc=$rc)"
ac_assert_eq "$out" "$HEADER" \
  "AC 3: empty tape must print the header row only, got: $out"
ac_log "AC 3 OK: empty tape -> header only, rc 0"

# ── AC 4: `bats tests/calibration.bats` passes ───────────────────────────────

ac_log "AC 4: bats tests/calibration.bats passes"
ac_run_bats_suite "$REPO_ROOT/tests/calibration.bats"
ac_assert_eq "$bats_rc" "0" "bats tests/calibration.bats must pass (rc=$bats_rc): $bats_out"
ac_log "AC 4 OK: bats suite green"

ac_pass
