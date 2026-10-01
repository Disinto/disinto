#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1629.sh
#
# Issue #1629: parse the sprint block of a milestone description.
#
# A sprint is a Forgejo milestone; its description carries a small sprint
# block (class / effect / expect / soak / [rests_on]). lib/sprint-block.sh
# provides four functions (no callers yet) that read it.
#
# Functions (sourced; no callers yet):
#   sprint_field TEXT KEY
#     -> value of the first line of TEXT matching ^KEY:[[:space:]]*(.*)$,
#        leading/trailing whitespace removed. No match: nothing, rc 0.
#   sprint_duration_seconds VALUE
#     -> VALUE in seconds (7d -> 604800, 48h -> 172800); anything else 0.
#   sprint_soak_seconds TEXT
#     -> sprint_duration_seconds of the soak value; no soak line -> 0.
#   sprint_expect_met VALUE EXPECT
#     -> rc 0 met / rc 1 not met / rc 2 VALUE or EXPECT malformed. EXPECT
#        is an operator (>= <= > < ==) + a space + a number; VALUE is a number
#        (integer or decimal, may be negative). Compared with awk, not bash
#        integer tests.
#
# Hermetic: no network, no forge, no agent — fixture strings only, the lib
# sourced in a throwaway subshell (same pattern as issue-1618.sh).
#
# Acceptance: `bash tests/acceptance/issue-1629.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash awk
ac_assert_file "$REPO_ROOT/lib/sprint-block.sh" "lib/sprint-block.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# run_block <func> <args...> — source lib/sprint-block.sh in a throwaway
# subshell and call <func> with the args. stdout -> $OUT, stderr -> $ERR,
# exit status -> $RC.
run_block() {
  local fn="$1"; shift
  RC=0 OUT="" ERR=""
  (
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/sprint-block.sh"
    "$fn" "$@"
  ) >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null)"
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null)"
}

# The four-line block the acceptance criteria refer to.
BLOCK=$'class: deploy\neffect: probes/foo.sh\nexpect: >= 3\nsoak: 7d'

# The parser is quiet on the happy path; every field call below must stay
# stderr-clean (ERR is the captured stderr of the most recent run_block).

# ── AC1: sprint_field reads the class and expect fields ───────────────────────
ac_log "AC1: sprint_field reads the class and expect fields"
run_block sprint_field "$BLOCK" class
ac_assert_eq "$OUT" "deploy" \
  "sprint_field class must print 'deploy' (got '$OUT') [stderr: $ERR]"
[ -z "$ERR" ] || ac_fail "sprint_field class must not print stderr (got: $ERR)"
ac_assert_eq "$RC" "0" "sprint_field class must return 0 (rc=$RC)"
run_block sprint_field "$BLOCK" expect
ac_assert_eq "$OUT" ">= 3" \
  "sprint_field expect must print '>= 3' (got '$OUT') [stderr: $ERR]"
[ -z "$ERR" ] || ac_fail "sprint_field expect must not print stderr (got: $ERR)"
ac_assert_eq "$RC" "0" "sprint_field expect must return 0 (rc=$RC)"

# ── AC2: a missing key prints nothing and returns 0 ───────────────────────────
ac_log "AC2: a missing key prints nothing and returns 0"
run_block sprint_field "$BLOCK" nope
ac_assert_eq "$OUT" "" \
  "missing key must print nothing (got '$OUT')"
ac_assert_eq "$RC" "0" "missing key must return 0 (rc=$RC)"

# ── AC3: sprint_soak_seconds 604800 / 172800 / 0 (soon) / 0 (no line) ────────
ac_log "AC3: sprint_soak_seconds"
run_block sprint_soak_seconds "$BLOCK"
ac_assert_eq "$OUT" "604800" \
  "7d soak must print 604800 (got '$OUT')"
run_block sprint_soak_seconds $'class: internal\nsoak: 48h'
ac_assert_eq "$OUT" "172800" \
  "48h soak must print 172800 (got '$OUT')"
run_block sprint_soak_seconds $'class: internal\nsoak: soon'
ac_assert_eq "$OUT" "0" "soon soak must print 0 (got '$OUT')"
run_block sprint_soak_seconds $'class: internal\neffect: none'
ac_assert_eq "$OUT" "0" "missing soak line must print 0 (got '$OUT')"

# ── AC4: sprint_expect_met met / not met / malformed ──────────────────────────
ac_log "AC4: sprint_expect_met"
run_block sprint_expect_met 5 ">= 3"
ac_assert_eq "$RC" "0" \
  "sprint_expect_met 5 '>= 3' must return 0 (rc=$RC)"
[ -z "$OUT" ] || ac_fail "sprint_expect_met 5 '>= 3' must print nothing (out: $OUT)"
run_block sprint_expect_met 0.12 "<= 0.2"
ac_assert_eq "$RC" "0" \
  "sprint_expect_met 0.12 '<= 0.2' must return 0 (rc=$RC)"
[ -z "$OUT" ] || ac_fail "sprint_expect_met 0.12 '<= 0.2' must print nothing (out: $OUT)"
run_block sprint_expect_met 2 ">= 3"
ac_assert_eq "$RC" "1" \
  "sprint_expect_met 2 '>= 3' must return 1 (rc=$RC)"
run_block sprint_expect_met abc ">= 3"
ac_assert_eq "$RC" "2" \
  "sprint_expect_met abc '>= 3' must return 2 (rc=$RC)"
run_block sprint_expect_met 1 "about 3"
ac_assert_eq "$RC" "2" \
  "sprint_expect_met 1 'about 3' must return 2 (rc=$RC)"

ac_pass "issue #1629: parse the sprint block of a milestone description"
