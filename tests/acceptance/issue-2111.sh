#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2111.sh
#
# Issue #2111: tools/rollout.sh reads the canary's evidence lines
# (lib/rollout-evidence.sh, #2106) into one rollout verdict.
#
#   rollout_watch FILE COMMIT SINCE NOW SOAK_S TAKE_POLLS
#     prints one JSON object:
#       {"verdict":"promote"|"wait"|"rollback",
#        "reason":<"" unless rollback>,
#        "smoke":<1 when the take's smoke is 0, else 0>,
#        "polls":<count of the commit's polls>,
#        "soak_s":<NOW - the take's t, or 0 with no take>}
#     Rules, first match wins (lines with t < SINCE are ignored):
#       1. take with smoke != 0            -> rollback, smoke
#       2. a poll with rc != 0             -> rollback, rc
#       3. no take, others >= TAKE_POLLS   -> rollback, not-taken
#       4. take, last poll after it names another commit -> rollback, left
#       5. no take, soak not met, no polls -> wait
#       6. work: total due > 0, total done 0 -> rollback, work
#       7. otherwise                       -> promote
#   Run directly: prints "usage: tools/rollout.sh tick" to stderr, exits 2.
#
# Acceptance:
#   1. take of C at 1100 (smoke 0), polls of C at 1400 and 2900 (rc 0),
#      NOW 3000, SOAK 1800, TAKE_POLLS 2 -> promote, polls 2, soak_s 1900,
#      smoke 1.
#   2. the same fixture at NOW 2000 -> wait.
#   3. a take with smoke 1 -> rollback / smoke, smoke 0.
#   4. a poll of C with rc 2 -> rollback / rc.
#   5. no take, polls of another commit at 1100 and 1500 -> rollback /
#      not-taken; only the first of them -> wait.
#   6. the promote fixture plus a poll of another commit at 2950 ->
#      rollback / left.
#   7. the promote fixture plus a work line of C with due 2, done 0 ->
#      rollback / work; with done 1 -> promote.
#   8. lines with t before SINCE do not count; a missing FILE -> wait.
#   9. `bash tools/rollout.sh` prints the usage line and exits 2;
#      `bash -n tools/rollout.sh` passes.
#
# Hermetic: fixture JSONL files in a temp dir, jq only. No forge, no git,
# no network.
#
# Acceptance: `bash tests/acceptance/issue-2111.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq

TOOL="$REPO_ROOT/tools/rollout.sh"
ac_assert_file "$TOOL" "tools/rollout.sh is missing"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/issue-2111.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

C="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
D="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SINCE=1000
SOAK_S=1800
TAKE_POLLS=2

# ── fixture line writers (the shapes lib/rollout-evidence.sh appends) ────────
take_line() {
  printf '{"t":%s,"kind":"take","job":"canary","ref":"canary","commit":"%s","smoke":%s}\n' \
    "$1" "$2" "$3"
}
poll_line() {
  printf '{"t":%s,"kind":"poll","job":"canary","ref":"canary","commit":"%s","role":"review","rc":%s}\n' \
    "$1" "$2" "$3"
}
work_line() {
  printf '{"t":%s,"kind":"work","job":"review","commit":"%s","role":"review","due":%s,"done":%s,"failed":0}\n' \
    "$1" "$2" "$3" "$4"
}

# Run rollout_watch by sourcing the tool in a subshell ($0 is a dummy so the
# direct-run guard does not fire). Stores the status in RC and the combined
# stdout/stderr in OUT.
run_watch() {
  RC=0
  # shellcheck disable=SC2034
  OUT="$(bash -c '
    source "$1"
    rollout_watch "$2" "$3" "$4" "$5" "$6" "$7"
  ' _ "$TOOL" "$@")" || RC=$?
}

# ── the promote fixture: take of C at 1100, polls of C at 1400 and 2900 ──────
PROMOTE="$WORK/promote.jsonl"
{
  take_line 1100 "$C" 0
  poll_line 1400 "$C" 0
  poll_line 2900 "$C" 0
} >"$PROMOTE"

# AC1: soak met -> promote, polls 2, soak_s 1900, smoke 1.
run_watch "$PROMOTE" "$C" "$SINCE" 3000 "$SOAK_S" "$TAKE_POLLS"
ac_assert_eq "$RC" 0 "AC1 rollout_watch failed: $OUT"
ac_assert_jq '.verdict == "promote" and .reason == "" and .polls == 2
             and .soak_s == 1900 and .smoke == 1' \
  "$OUT" "AC1 held canary must promote with polls 2, soak_s 1900, smoke 1, got: $OUT"

# AC2: the same fixture before the soak ends -> wait.
run_watch "$PROMOTE" "$C" "$SINCE" 2000 "$SOAK_S" "$TAKE_POLLS"
ac_assert_eq "$RC" 0 "AC2 rollout_watch failed: $OUT"
ac_assert_jq '.verdict == "wait" and .reason == "" and .polls == 2
             and .soak_s == 900 and .smoke == 1' \
  "$OUT" "AC2 before the soak must wait, got: $OUT"

# AC3: smoke failed on the take -> rollback / smoke, smoke 0.
SMOKE="$WORK/smoke.jsonl"
{
  take_line 1100 "$C" 1
  poll_line 1400 "$C" 0
} >"$SMOKE"
run_watch "$SMOKE" "$C" "$SINCE" 3000 "$SOAK_S" "$TAKE_POLLS"
ac_assert_eq "$RC" 0 "AC3 rollout_watch failed: $OUT"
ac_assert_jq '.verdict == "rollback" and .reason == "smoke" and .smoke == 0' \
  "$OUT" "AC3 a failing smoke must rollback with reason smoke and smoke 0, got: $OUT"

# AC4: a poll of C exits nonzero -> rollback / rc.
RC2="$WORK/poll-rc.jsonl"
{
  take_line 1100 "$C" 0
  poll_line 1400 "$C" 2
} >"$RC2"
run_watch "$RC2" "$C" "$SINCE" 3000 "$SOAK_S" "$TAKE_POLLS"
ac_assert_eq "$RC" 0 "AC4 rollout_watch failed: $OUT"
ac_assert_jq '.verdict == "rollback" and .reason == "rc" and .polls == 1' \
  "$OUT" "AC4 a nonzero poll rc must rollback with reason rc, got: $OUT"

# AC5: no take; another commit polled TAKE_POLLS times -> rollback / not-taken;
# only one such poll -> wait.
NOTTAKEN="$WORK/not-taken.jsonl"
{
  poll_line 1100 "$D" 0
  poll_line 1500 "$D" 0
} >"$NOTTAKEN"
run_watch "$NOTTAKEN" "$C" "$SINCE" 3000 "$SOAK_S" "$TAKE_POLLS"
ac_assert_eq "$RC" 0 "AC5 rollout_watch failed: $OUT"
ac_assert_jq '.verdict == "rollback" and .reason == "not-taken" and .polls == 0
             and .soak_s == 0 and .smoke == 0' \
  "$OUT" "AC5 TAKE_POLLS polls of another commit without a take must rollback not-taken, got: $OUT"

ONE="$WORK/not-taken-one.jsonl"
poll_line 1100 "$D" 0 >"$ONE"
run_watch "$ONE" "$C" "$SINCE" 3000 "$SOAK_S" "$TAKE_POLLS"
ac_assert_eq "$RC" 0 "AC5 rollout_watch failed: $OUT"
ac_assert_jq '.verdict == "wait" and .reason == ""' \
  "$OUT" "AC5 fewer than TAKE_POLLS polls of another commit must wait, got: $OUT"

# AC6: the promote fixture plus a poll of another commit after the take ->
# rollback / left.
LEFT="$WORK/left.jsonl"
{
  take_line 1100 "$C" 0
  poll_line 1400 "$C" 0
  poll_line 2900 "$C" 0
  poll_line 2950 "$D" 0
} >"$LEFT"
run_watch "$LEFT" "$C" "$SINCE" 3000 "$SOAK_S" "$TAKE_POLLS"
ac_assert_eq "$RC" 0 "AC6 rollout_watch failed: $OUT"
ac_assert_jq '.verdict == "rollback" and .reason == "left"' \
  "$OUT" "AC6 a poll of another commit after the take must rollback left, got: $OUT"

# AC7: due work with nothing done -> rollback / work; one done -> promote.
WORKLINE="$WORK/work.jsonl"
{
  take_line 1100 "$C" 0
  poll_line 1400 "$C" 0
  poll_line 2900 "$C" 0
  work_line 1500 "$C" 2 0
} >"$WORKLINE"
run_watch "$WORKLINE" "$C" "$SINCE" 3000 "$SOAK_S" "$TAKE_POLLS"
ac_assert_eq "$RC" 0 "AC7 rollout_watch failed: $OUT"
ac_assert_jq '.verdict == "rollback" and .reason == "work"' \
  "$OUT" "AC7 due work with nothing done must rollback work, got: $OUT"

WORKDONE="$WORK/work-done.jsonl"
{
  take_line 1100 "$C" 0
  poll_line 1400 "$C" 0
  poll_line 2900 "$C" 0
  work_line 1500 "$C" 2 1
} >"$WORKDONE"
run_watch "$WORKDONE" "$C" "$SINCE" 3000 "$SOAK_S" "$TAKE_POLLS"
ac_assert_eq "$RC" 0 "AC7 rollout_watch failed: $OUT"
ac_assert_jq '.verdict == "promote" and .reason == ""' \
  "$OUT" "AC7 work with one done must still promote, got: $OUT"

# AC8: lines with t before SINCE do not count; a missing FILE gives wait.
BEFORE="$WORK/before-since.jsonl"
{
  take_line 900 "$C" 1
  poll_line 900 "$D" 2
  take_line 1100 "$C" 0
  poll_line 1400 "$C" 0
  poll_line 2900 "$C" 0
} >"$BEFORE"
run_watch "$BEFORE" "$C" "$SINCE" 3000 "$SOAK_S" "$TAKE_POLLS"
ac_assert_eq "$RC" 0 "AC8 rollout_watch failed: $OUT"
ac_assert_jq '.verdict == "promote" and .reason == "" and .polls == 2
             and .soak_s == 1900 and .smoke == 1' \
  "$OUT" "AC8 lines before SINCE must be ignored (the 900-line take/smoke/rc do not apply), got: $OUT"

MISSING="$WORK/does-not-exist.jsonl"
run_watch "$MISSING" "$C" "$SINCE" 3000 "$SOAK_S" "$TAKE_POLLS"
ac_assert_eq "$RC" 0 "AC8 rollout_watch failed on a missing FILE: $OUT"
ac_assert_jq '.verdict == "wait" and .reason == "" and .polls == 0
             and .soak_s == 0 and .smoke == 0' \
  "$OUT" "AC8 a missing FILE must give wait, got: $OUT"

# AC9: run directly -> usage line on stderr, exit 2; bash -n passes.
rc=0
err="$(bash "$TOOL" 2>&1)" || rc=$?
ac_assert_eq "$rc" 2 "running tools/rollout.sh directly must exit 2, got $rc"
ac_assert_eq "$err" "usage: tools/rollout.sh tick" \
  "running tools/rollout.sh directly must print the usage line, got: $err"

rc=0
bash -n "$TOOL" || rc=$?
ac_assert_eq "$rc" 0 "bash -n tools/rollout.sh must pass"

ac_pass
