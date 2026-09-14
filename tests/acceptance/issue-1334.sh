#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1334.sh — planner always uses run-planner.toml
#
# Issue #1334 (oak tick-learner sprint): the planner no longer selects the
# formula by PROJECT_KIND (#1314 removed). The planner always loads
# formulas/run-planner.toml — a research box (PROJECT_KIND=research) runs the
# software planner formula, as intended — the research formula
# formulas/run-planner-research.toml is deleted, and the old switch test
# tests/acceptance/issue-1314.sh is gone (the runner only runs AC for open
# issues; leaving it would lie).
#
# Verifies (all checks read-only — no forge, no nomad, no repo mutation):
#   1. planner/planner-run.sh contains no `run-planner-research` string and
#      is still syntactically valid (bash -n).
#   2. formulas/run-planner.toml exists; formulas/run-planner-research.toml
#      is gone.
#   3. tests/acceptance/issue-1314.sh is gone.
#   4. planner_formula_file() extracted from planner/planner-run.sh returns
#      the run-planner.toml path for absent PROJECT_KIND, for software, AND
#      for research (a research env still loads run-planner.toml).
#   5. the session lifecycle is unchanged: planner-run.sh still loads the
#      formula via load_formula_or_profile and still runs agent_run + the
#      ops PR walk.
#
# Run via: tools/run-acceptance.sh 1334
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash
ac_require_cmd grep

PLANNER_RUN="$REPO_ROOT/planner/planner-run.sh"
SOFTWARE_FORMULA="$REPO_ROOT/formulas/run-planner.toml"
RESEARCH_FORMULA="$REPO_ROOT/formulas/run-planner-research.toml"
OLD_TEST="$REPO_ROOT/tests/acceptance/issue-1314.sh"

ac_assert_file "$PLANNER_RUN" "planner/planner-run.sh is missing"
ac_assert_file "$SOFTWARE_FORMULA" "formulas/run-planner.toml is missing"

# 1. No research-formula references in planner-run.sh; still parses.
ac_log "checking planner-run.sh has no run-planner-research string"
! grep -q "run-planner-research" "$PLANNER_RUN" \
  || ac_fail "planner/planner-run.sh still references run-planner-research"
bash -n "$PLANNER_RUN" 2>/dev/null \
  || ac_fail "planner/planner-run.sh fails bash -n"

# 2. Research formula deleted, software formula intact.
ac_log "checking the research formula is gone"
[ ! -e "$RESEARCH_FORMULA" ] \
  || ac_fail "formulas/run-planner-research.toml still exists"

# 3. The old switch test is gone (it asserted the removed switch).
ac_log "checking the issue-1314 switch test is deleted"
[ ! -e "$OLD_TEST" ] \
  || ac_fail "tests/acceptance/issue-1314.sh still exists"

# 4. Behaviour: planner_formula_file() returns run-planner.toml for every
#    PROJECT_KIND — absent, software, and research alike. <kind> empty =
#    PROJECT_KIND unset. ac_pick_in_subshell runs the extracted function in
#    a throwaway subshell with a fixed fake FACTORY_ROOT (shared helper —
#    tests/lib/acceptance-helpers.sh).
ac_log "checking planner_formula_file() returns run-planner.toml for every PROJECT_KIND"
FN="$(ac_extract_fn planner_formula_file "$PLANNER_RUN")"
[ -n "$FN" ] || ac_fail "planner_formula_file() not found in planner/planner-run.sh"

SOFTWARE_PATH="/srv/disinto/formulas/run-planner.toml"

OUT="$(ac_pick_in_subshell "" "$FN" planner_formula_file)"
ac_assert_eq "$OUT" "$SOFTWARE_PATH" \
  "absent PROJECT_KIND: expected $SOFTWARE_PATH, got $OUT"
ac_log "selection: absent PROJECT_KIND -> run-planner.toml"

OUT="$(ac_pick_in_subshell "software" "$FN" planner_formula_file)"
ac_assert_eq "$OUT" "$SOFTWARE_PATH" \
  "PROJECT_KIND=software: expected $SOFTWARE_PATH, got $OUT"
ac_log "selection: PROJECT_KIND=software -> run-planner.toml"

OUT="$(ac_pick_in_subshell "research" "$FN" planner_formula_file)"
ac_assert_eq "$OUT" "$SOFTWARE_PATH" \
  "PROJECT_KIND=research: expected $SOFTWARE_PATH, got $OUT"
ac_log "selection: PROJECT_KIND=research -> run-planner.toml"

# 5. Session lifecycle unchanged: formula loading + agent_run + PR walk.
# Fixed-string greps for literal lines containing $-variable references.
ac_log "checking the session lifecycle is unchanged"
# shellcheck disable=SC2016
grep -qF 'load_formula_or_profile "planner" "$PLANNER_FORMULA"' "$PLANNER_RUN" \
  || ac_fail "planner-run.sh no longer loads the formula via load_formula_or_profile"
# shellcheck disable=SC2016
grep -qF 'agent_run --worktree "$WORKTREE" "$PROMPT"' "$PLANNER_RUN" \
  || ac_fail "planner-run.sh session lifecycle (agent_run) changed"
grep -q 'pr_walk_to_merge' "$PLANNER_RUN" \
  || ac_fail "planner-run.sh ops PR walk (pr_walk_to_merge) changed"

ac_pass
