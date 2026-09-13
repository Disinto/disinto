#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1314.sh
#
# Issue #1314: research-mode planner. planner/planner-run.sh must select the
# planner formula from PROJECT_KIND (project TOML `kind`, #1294):
#   - absent kind and PROJECT_KIND=software  -> formulas/run-planner.toml
#   - PROJECT_KIND=research                  -> formulas/run-planner-research.toml
# and the research formula must instruct the model to file runs/hosts/
# artifacts issues (at most 3 per run, campaign notes under ops campaigns/,
# no Fold-2 shipping issues). The software path keeps the existing formula.
#
# Verifies (all checks read-only — no forge, no nomad, no repo mutation):
#   1. planner_formula_file() extracted from planner/planner-run.sh returns
#      the run-planner.toml path for absent PROJECT_KIND and for software.
#   2. it returns the run-planner-research.toml path for research.
#   3. the research formula exists, is valid TOML, and its text covers the
#      three filing sources (missing ops/runs/ records vs campaigns, idle
#      hosts below cap in RESOURCES.md, open judgment labels), caps filings
#      at 3 issues per run, routes prerequisite notes to campaigns/, and
#      explicitly forbids Fold-2 shipping issues.
#   4. software path is unchanged in shape: planner-run.sh still loads the
#      selected formula via load_formula_or_profile and still runs the same
#      session lifecycle (agent_run + ops PR walk).
#
# Run via: tools/run-acceptance.sh 1314
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep python3

PLANNER_RUN="$REPO_ROOT/planner/planner-run.sh"
SOFTWARE_FORMULA="$REPO_ROOT/formulas/run-planner.toml"
RESEARCH_FORMULA="$REPO_ROOT/formulas/run-planner-research.toml"

ac_assert_file "$PLANNER_RUN" "planner/planner-run.sh is missing"
ac_assert_file "$SOFTWARE_FORMULA" "formulas/run-planner.toml is missing"
ac_assert_file "$RESEARCH_FORMULA" "formulas/run-planner-research.toml is missing"

# ── 1+2. Behaviour: planner_formula_file() picks by PROJECT_KIND ───────────
# <kind> empty = PROJECT_KIND unset. ac_pick_in_subshell runs the extracted
# function in a throwaway subshell with a fixed fake FACTORY_ROOT (shared
# helper — tests/lib/acceptance-helpers.sh).
FN="$(ac_extract_fn planner_formula_file "$PLANNER_RUN")"
[ -n "$FN" ] || ac_fail "planner_formula_file() not found in planner/planner-run.sh"

SOFTWARE_PATH="/srv/disinto/formulas/run-planner.toml"
RESEARCH_PATH="/srv/disinto/formulas/run-planner-research.toml"

OUT="$(ac_pick_in_subshell "" "$FN" planner_formula_file)"
ac_assert_eq "$OUT" "$SOFTWARE_PATH" \
  "absent PROJECT_KIND: expected $SOFTWARE_PATH, got $OUT"
ac_log "selection: absent PROJECT_KIND -> run-planner.toml"

OUT="$(ac_pick_in_subshell "software" "$FN" planner_formula_file)"
ac_assert_eq "$OUT" "$SOFTWARE_PATH" \
  "PROJECT_KIND=software: expected $SOFTWARE_PATH, got $OUT"
ac_log "selection: PROJECT_KIND=software -> run-planner.toml"

OUT="$(ac_pick_in_subshell "research" "$FN" planner_formula_file)"
ac_assert_eq "$OUT" "$RESEARCH_PATH" \
  "PROJECT_KIND=research: expected $RESEARCH_PATH, got $OUT"
ac_log "selection: PROJECT_KIND=research -> run-planner-research.toml"

# ── 3. Research formula text ────────────────────────────────────────────────
python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$RESEARCH_FORMULA" \
  || ac_fail "formulas/run-planner-research.toml is not valid TOML"
ac_log "research formula: valid TOML"

grep -q "runs/" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not reference ops runs/ records"
grep -q "RESOURCES.md" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not reference RESOURCES.md hosts"
grep -qi "idle hosts below cap" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not cover idle hosts below cap"
grep -q "judgment" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not cover open judgment labels"
grep -q "artifacts/" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not reference ops artifacts/"
grep -q "campaigns/" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not route prerequisite notes to ops campaigns/"
grep -Eq "at most 3 issues (per run|/run)" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not cap filings at 3 issues per run"
grep -q "Do NOT file Fold-2 shipping issues" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not forbid Fold-2 shipping issues"
ac_log "research formula: runs/hosts/artifacts sources, 3-issue cap, no Fold-2 sprints"

# ── 4. Software path has no behaviour change ────────────────────────────────
# Fixed-string greps for literal lines containing $-variable references.
# shellcheck disable=SC2016
grep -qF 'load_formula_or_profile "planner" "$PLANNER_FORMULA"' "$PLANNER_RUN" \
  || ac_fail "planner-run.sh no longer loads the selected formula via load_formula_or_profile"
# shellcheck disable=SC2016
grep -qF 'agent_run --worktree "$WORKTREE" "$PROMPT"' "$PLANNER_RUN" \
  || ac_fail "planner-run.sh session lifecycle (agent_run) changed"
grep -q 'pr_walk_to_merge' "$PLANNER_RUN" \
  || ac_fail "planner-run.sh ops PR walk (pr_walk_to_merge) changed"
ac_log "software path: formula loading and session lifecycle unchanged"

ac_pass
