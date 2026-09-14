#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1335.sh — architect always uses run-architect.toml
#
# Issue #1335 (oak tick-learner sprint, supersedes #1315): the architect no
# longer selects the formula by PROJECT_KIND. Every
# `if [ "${PROJECT_KIND:-software}" = "research" ]` branch in
# architect/architect-run.sh is deleted — the software branch is the only
# path: architect_formula_file() returns
# formulas/run-architect.toml for every kind, the tracking green gate is
# closed + deployed + acceptance rc=0, and the role/pitch text is
# sprint-shaped. The research formula
# formulas/run-architect-research.toml is deleted, and the old switch test
# tests/acceptance/issue-1315.sh is gone (the runner only runs AC for open
# issues; leaving it would lie).
#
# Verifies (all checks read-only — no forge, no nomad, no repo mutation):
#   1. architect/architect-run.sh contains no `run-architect-research`
#      string and no `PROJECT_KIND` string, and is still syntactically
#      valid (bash -n).
#   2. formulas/run-architect.toml exists; formulas/run-architect-research.toml
#      is gone.
#   3. tests/acceptance/issue-1315.sh is gone.
#   4. architect_formula_file() extracted from architect/architect-run.sh
#      returns the run-architect.toml path for absent PROJECT_KIND, for
#      software, AND for research (a research env still loads
#      run-architect.toml).
#   5. The tracking green gate is the software gate: the
#      check_research_subissue_green function is gone and
#      check_subissue_green still requires the deployed label and the
#      acceptance test rc=0.
#   6. The session lifecycle is unchanged: architect-run.sh still loads the
#      formula via load_formula_or_profile and still runs agent_run.
#
# Run via: tools/run-acceptance.sh 1335
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

ARCHITECT_RUN="$REPO_ROOT/architect/architect-run.sh"
SOFTWARE_FORMULA="$REPO_ROOT/formulas/run-architect.toml"
RESEARCH_FORMULA="$REPO_ROOT/formulas/run-architect-research.toml"
OLD_TEST="$REPO_ROOT/tests/acceptance/issue-1315.sh"

ac_assert_file "$ARCHITECT_RUN" "architect/architect-run.sh is missing"
ac_assert_file "$SOFTWARE_FORMULA" "formulas/run-architect.toml is missing"

# 1. No research-formula or PROJECT_KIND references in architect-run.sh;
#    still parses.
ac_log "checking architect-run.sh has no run-architect-research or PROJECT_KIND string"
! grep -q "run-architect-research" "$ARCHITECT_RUN" \
  || ac_fail "architect/architect-run.sh still references run-architect-research"
! grep -q "PROJECT_KIND" "$ARCHITECT_RUN" \
  || ac_fail "architect/architect-run.sh still references PROJECT_KIND"
bash -n "$ARCHITECT_RUN" 2>/dev/null \
  || ac_fail "architect/architect-run.sh fails bash -n"

# 2. Research formula deleted, software formula intact.
ac_log "checking the research formula is gone"
[ ! -e "$RESEARCH_FORMULA" ] \
  || ac_fail "formulas/run-architect-research.toml still exists"

# 3. The old switch test is gone (it asserted the removed switch).
ac_log "checking the issue-1315 switch test is deleted"
[ ! -e "$OLD_TEST" ] \
  || ac_fail "tests/acceptance/issue-1315.sh still exists"

# 4. Behaviour: architect_formula_file() returns run-architect.toml for
#    every PROJECT_KIND — absent, software, and research alike. <kind>
#    empty = PROJECT_KIND unset. ac_pick_in_subshell runs the extracted
#    function in a throwaway subshell with a fixed fake FACTORY_ROOT
#    (shared helper — tests/lib/acceptance-helpers.sh).
ac_log "checking architect_formula_file() returns run-architect.toml for every PROJECT_KIND"
FN="$(ac_extract_fn architect_formula_file "$ARCHITECT_RUN")"
[ -n "$FN" ] || ac_fail "architect_formula_file() not found in architect/architect-run.sh"

SOFTWARE_PATH="/srv/disinto/formulas/run-architect.toml"

OUT="$(ac_pick_in_subshell "" "$FN" architect_formula_file)"
ac_assert_eq "$OUT" "$SOFTWARE_PATH" \
  "absent PROJECT_KIND: expected $SOFTWARE_PATH, got $OUT"
ac_log "selection: absent PROJECT_KIND -> run-architect.toml"

OUT="$(ac_pick_in_subshell "software" "$FN" architect_formula_file)"
ac_assert_eq "$OUT" "$SOFTWARE_PATH" \
  "PROJECT_KIND=software: expected $SOFTWARE_PATH, got $OUT"
ac_log "selection: PROJECT_KIND=software -> run-architect.toml"

OUT="$(ac_pick_in_subshell "research" "$FN" architect_formula_file)"
ac_assert_eq "$OUT" "$SOFTWARE_PATH" \
  "PROJECT_KIND=research: expected $SOFTWARE_PATH, got $OUT"
ac_log "selection: PROJECT_KIND=research -> run-architect.toml"

# 5. The tracking green gate is the software gate.
ac_log "checking the tracking green gate is the software gate"
! grep -q "check_research_subissue_green" "$ARCHITECT_RUN" \
  || ac_fail "architect-run.sh still defines check_research_subissue_green"
# shellcheck disable=SC2016
grep -qF "grep -q '^deployed\$'" "$ARCHITECT_RUN" \
  || ac_fail "check_subissue_green no longer requires the deployed label"
grep -q "tests/acceptance/issue-" "$ARCHITECT_RUN" \
  || ac_fail "check_subissue_green no longer runs the acceptance test"
grep -q "TRACKING_GREEN_DEF=\"closed AND has deployed label AND acceptance test rc=0\"" "$ARCHITECT_RUN" \
  || ac_fail "TRACKING_GREEN_DEF is no longer the software definition"

# 6. Session lifecycle unchanged: formula loading + agent_run.
ac_log "checking the session lifecycle is unchanged"
# shellcheck disable=SC2016
grep -qF 'load_formula_or_profile "architect" "$ARCHITECT_FORMULA"' "$ARCHITECT_RUN" \
  || ac_fail "architect-run.sh no longer loads the formula via load_formula_or_profile"
# shellcheck disable=SC2016
grep -qF 'agent_run --worktree "$WORKTREE" "$prompt"' "$ARCHITECT_RUN" \
  || ac_fail "architect-run.sh session lifecycle (agent_run) changed"

ac_pass
