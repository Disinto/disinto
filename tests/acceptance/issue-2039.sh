#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2039.sh
#
# Issue #2039: feat(tools): the first grade above 0.5 tells the owner to write
# rejection rules.
#
# Contract under test (tools/grade-threshold.sh, wired into the gardener right
# before the claim-loop proposals block):
#   * Marker ${TAPE_DIR}/gate/rejection-rules-told: when it exists, exit 0 and
#     print nothing.
#   * Otherwise the first record in tape order with type == "grade" and a
#     numeric value > 0.5 (malformed lines skipped; a missing tape is "none")
#     queues exactly one notice for the owner via lib/notice.sh, mentioning the
#     value, the proposal id and "rejection rules", then creates the marker.
#   * A failed queue exits 1 and writes no marker, so the notice is retried.
#
# Acceptance (hermetic — no network, no forge, no agent; temp TAPE_DIR and
# NOTICES_DIR per scenario):
#   AC1: grades 0.5 and 0.5 only -> rc 0, no notice, no marker.
#   AC2: add a 0.75 grade (who effect-scale, proposal p-7) -> rc 0, exactly one
#        notice holding 0.75, p-7 and "rejection rules"; marker exists.
#   AC3: rerun queues nothing; a new 1.0 grade with the marker present queues
#        nothing either.
#   AC4: a tape whose last line is torn still finds the earlier 0.9 (owner
#        grade) and queues once.
#   AC5: a notices dir that cannot be written returns 1 with no marker (retry).
#   AC6: gardener-run.sh calls the tool before the "# Claim-loop proposals
#        (#1641)" comment; bash -n passes on both files; the tool is executable.
#
# Run via: tools/run-acceptance.sh 2039
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep
ac_assert_file "$REPO_ROOT/tools/grade-threshold.sh" "tools/grade-threshold.sh is missing"
ac_assert_file "$REPO_ROOT/lib/notice.sh" "lib/notice.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/gardener-run.sh" "gardener/gardener-run.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# grade_grade <proposal_id> <value> <who> — one tape-grade line.
grade_line() {
  printf '{"type":"grade","t":"2026-11-05T00:00:00Z","proposal_id":"%s","value":%s,"when":"at_outcome","who":"%s"}\n' \
    "$1" "$2" "$3"
}

# run_tool <tape_dir> <notices_dir> — run the tool hermetically with the
# scenario's TAPE_DIR/NOTICES_DIR. stdout -> OUT, stderr -> ERR, status -> RC.
run_tool() {
  RC=0
  OUT=""
  ERR=""
  (
    export TAPE_DIR="$1" NOTICES_DIR="$2"
    bash "$REPO_ROOT/tools/grade-threshold.sh"
  ) >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null)"
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null)"
}

# txt_count <dir> — number of *.txt files directly in dir (0 if no dir).
txt_count() {
  find "$1" -maxdepth 1 -name '*.txt' 2>/dev/null | wc -l | tr -d ' '
}

# ── AC1: grades at 0.5, not above it: nothing queues, no marker ──────────────
ac_log "AC1: two 0.5 grades — rc 0, no notice, no marker"
T1="$TMP_DIR/tape-1"
mkdir -p "$T1"
{
  grade_line p-1 0.5 effect-scale
  grade_line p-2 0.5 owner
  printf '{"type":"proposal","t":"2026-11-04T00:00:00Z","id":"p-1","loop":"sprint","class":"internal"}\n'
} >"$T1/tape.jsonl"
run_tool "$T1" "$TMP_DIR/notices-1"
ac_assert_eq "$RC" "0" "no grade above 0.5 must exit 0 (got $RC): $ERR"
ac_assert_eq "$(txt_count "$TMP_DIR/notices-1")" "0" "no notice may be queued (got $(txt_count "$TMP_DIR/notices-1"))"
[ ! -e "$T1/gate/rejection-rules-told" ] || ac_fail "no marker may exist when nothing queued"

ac_log "AC1b: a missing tape is 'none' — rc 0, no notice"
T1B="$TMP_DIR/tape-1b"
mkdir -p "$T1B"
run_tool "$T1B" "$TMP_DIR/notices-1b"
ac_assert_eq "$RC" "0" "a missing tape must exit 0 (got $RC): $ERR"
ac_assert_eq "$(txt_count "$TMP_DIR/notices-1b")" "0" "no notice may be queued (got $(txt_count "$TMP_DIR/notices-1b"))"
[ ! -e "$T1B/gate" ] || ac_fail "no gate dir or marker may exist when nothing queued"

# ── AC2: the first grade above 0.5 queues one notice and marks the told state ─
ac_log "AC2: a 0.75 grade (effect-scale, p-7) — rc 0, one notice, marker exists"
T2="$TMP_DIR/tape-2"
mkdir -p "$T2"
{
  grade_line p-1 0.5 effect-scale
  grade_line p-2 0.5 owner
  grade_line p-7 0.75 effect-scale
  grade_line p-8 1.0 owner
} >"$T2/tape.jsonl"
NOTICES2="$TMP_DIR/notices-2"
run_tool "$T2" "$NOTICES2"
ac_assert_eq "$RC" "0" "a grade above 0.5 must exit 0 (got $RC): $ERR"
ac_assert_eq "$(txt_count "$NOTICES2")" "1" "exactly one notice must be queued (got $(txt_count "$NOTICES2"))"
NOTICE="$(cat "$(find "$NOTICES2" -maxdepth 1 -name '*.txt')" 2>/dev/null)"
for needle in "0.75" "p-7" "rejection rules"; do
  case "$NOTICE" in
    *"$needle"*) ;;
    *) ac_fail "the notice must mention '$needle' (got: $NOTICE)" ;;
  esac
done
ac_assert_file "$T2/gate/rejection-rules-told" "the marker gate/rejection-rules-told must exist"
case "$OUT" in
  *"grade-threshold"*|*"told the owner"*) ;;
  *) ac_fail "the tool must log one line when it queues the notice (got: $OUT)" ;;
esac

# ── AC3: once told, never told again — even when a newer grade lands ─────────
ac_log "AC3: rerun queues nothing"
run_tool "$T2" "$NOTICES2"
ac_assert_eq "$RC" "0" "the marked rerun must exit 0 (got $RC): $ERR"
ac_assert_eq "$(txt_count "$NOTICES2")" "1" "the rerun must queue no new notice (got $(txt_count "$NOTICES2"))"
ac_assert_eq "$OUT" "" "the marked run must print nothing (got: $OUT)"

ac_log "AC3b: a new 1.0 grade with the marker present queues nothing"
grade_line p-9 1.0 owner >>"$T2/tape.jsonl"
run_tool "$T2" "$NOTICES2"
ac_assert_eq "$RC" "0" "the marked run must exit 0 (got $RC): $ERR"
ac_assert_eq "$(txt_count "$NOTICES2")" "1" "the new grade must not queue a second notice (got $(txt_count "$NOTICES2"))"
ac_assert_eq "$OUT" "" "the marked run must print nothing (got: $OUT)"

# ── AC4: a torn last line is skipped, the earlier 0.9 is still found ──────────
ac_log "AC4: torn last line — the earlier 0.9 owner grade queues once"
T4="$TMP_DIR/tape-4"
mkdir -p "$T4"
{
  grade_line p-3 0.25 effect-scale
  grade_line p-4 0.9 owner
  printf '{"type":"grade","t":"2026-11-05T00:00:00'
} >"$T4/tape.jsonl"
NOTICES4="$TMP_DIR/notices-4"
run_tool "$T4" "$NOTICES4"
ac_assert_eq "$RC" "0" "a torn tape line must not be fatal (got $RC): $ERR"
ac_assert_eq "$(txt_count "$NOTICES4")" "1" "exactly one notice must be queued (got $(txt_count "$NOTICES4"))"
NOTICE4="$(cat "$(find "$NOTICES4" -maxdepth 1 -name '*.txt')" 2>/dev/null)"
case "$NOTICE4" in
  *"0.9"*) ;;
  *) ac_fail "the notice must name the 0.9 grade (got: $NOTICE4)" ;;
esac
ac_assert_file "$T4/gate/rejection-rules-told" "the marker must exist after a successful queue"

# ── AC5: an unwritable notices dir fails with rc 1 and no marker (retry) ─────
ac_log "AC5: the queue fails — rc 1, no marker, so the notice is retried"
T5="$TMP_DIR/tape-5"
mkdir -p "$T5"
grade_line p-6 0.75 effect-scale >"$T5/tape.jsonl"
BLOCKER="$TMP_DIR/blocker"
touch "$BLOCKER"
run_tool "$T5" "$BLOCKER/notices"
ac_assert_eq "$RC" "1" "a notice that cannot be queued must exit 1 (got $RC): $ERR"
[ ! -e "$T5/gate/rejection-rules-told" ] \
  || ac_fail "the marker must NOT be written when the queue failed (retry next run)"

# ── AC6: wiring in gardener-run.sh and syntax ────────────────────────────────
ac_log "AC6: gardener-run.sh calls the tool before the claim-loop block; bash -n passes"
GARDENER="$REPO_ROOT/gardener/gardener-run.sh"
GT_LINE=$(grep -n 'tools/grade-threshold.sh' "$GARDENER" | head -n1 | cut -d: -f1)
CLAIM_LINE=$(grep -n '# Claim-loop proposals (#1641)' "$GARDENER" | head -n1 | cut -d: -f1)
[ -n "$GT_LINE" ] || ac_fail "gardener-run.sh must call tools/grade-threshold.sh"
[ -n "$CLAIM_LINE" ] || ac_fail "gardener-run.sh must keep the claim-loop proposals comment"
[ "$GT_LINE" -lt "$CLAIM_LINE" ] \
  || ac_fail "grade-threshold.sh (line $GT_LINE) must sit before the claim-loop proposals comment (line $CLAIM_LINE)"
bash -n "$GARDENER" || ac_fail "bash -n gardener/gardener-run.sh failed"
bash -n "$REPO_ROOT/tools/grade-threshold.sh" || ac_fail "bash -n tools/grade-threshold.sh failed"
[ -x "$REPO_ROOT/tools/grade-threshold.sh" ] || ac_fail "tools/grade-threshold.sh must be executable"

echo PASS
exit 0
