#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1336.sh
#
# Issue #1336: the predictor always uses formulas/run-predictor.toml; the
# research formula from #1316 is deleted. Oak instances differ by pack, not
# by project kind, so predictor/predictor-run.sh must not switch on a kind:
#   - the formula helper always echoes formulas/run-predictor.toml
#   - formulas/run-predictor-research.toml is gone
#   - tests/acceptance/issue-1316.sh is gone
#   - predictor-run.sh contains no `run-predictor-research` string
#   - the session lifecycle is unchanged: the selected formula is still
#     loaded via load_formula_or_profile and run via agent_run
#
# Verifies (all checks read-only — no forge, no nomad, no repo mutation):
#   1. predictor-run.sh has no `run-predictor-research` string.
#   2. formulas/run-predictor-research.toml and tests/acceptance/issue-1316.sh
#      no longer exist.
#   3. predictor_formula_file() extracted from predictor/predictor-run.sh
#      returns the run-predictor.toml path (the kind switch is gone, #1338).
#   4. formulas/run-predictor.toml still exists, is valid TOML, declares
#      name "run-predictor", and predictor-run.sh still loads it via
#      load_formula_or_profile and still runs the same session lifecycle
#      (agent_run) with no new polling loop.
#
# Run via: tools/run-acceptance.sh 1336
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep python3

PREDICTOR_RUN="$REPO_ROOT/predictor/predictor-run.sh"
SOFTWARE_FORMULA="$REPO_ROOT/formulas/run-predictor.toml"
RESEARCH_FORMULA="$REPO_ROOT/formulas/run-predictor-research.toml"
OLD_TEST="$REPO_ROOT/tests/acceptance/issue-1316.sh"

ac_assert_file "$PREDICTOR_RUN" "predictor/predictor-run.sh is missing"

# ── 1. predictor-run.sh has no run-predictor-research string ────────────────
grep -q "run-predictor-research" "$PREDICTOR_RUN" \
  && ac_fail "predictor/predictor-run.sh still references run-predictor-research"
ac_log "predictor-run.sh: no run-predictor-research string"

# ── 2. Research formula and its acceptance test are gone ───────────────────
[ ! -e "$RESEARCH_FORMULA" ] \
  || ac_fail "formulas/run-predictor-research.toml still exists"
[ ! -e "$OLD_TEST" ] \
  || ac_fail "tests/acceptance/issue-1316.sh still exists"
ac_log "research formula and issue-1316.sh: gone"

# ── 3. Behaviour: predictor_formula_file() always returns run-predictor.toml
# The kind switch is gone (#1338). ac_pick_in_subshell runs the extracted
# function in a throwaway subshell with a fixed fake FACTORY_ROOT (shared
# helper — tests/lib/acceptance-helpers.sh).
FN="$(ac_extract_fn predictor_formula_file "$PREDICTOR_RUN")"
[ -n "$FN" ] || ac_fail "predictor_formula_file() not found in predictor/predictor-run.sh"

EXPECTED="/srv/disinto/formulas/run-predictor.toml"
OUT="$(ac_pick_in_subshell "$FN" predictor_formula_file)"
ac_assert_eq "$OUT" "$EXPECTED" \
  "expected $EXPECTED, got $OUT"
ac_log "selection: predictor_formula_file -> run-predictor.toml"

# ── 4. Software formula intact; session lifecycle unchanged ────────────────
ac_assert_file "$SOFTWARE_FORMULA" "formulas/run-predictor.toml is missing"
python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$SOFTWARE_FORMULA" \
  || ac_fail "formulas/run-predictor.toml is not valid TOML"
# shellcheck disable=SC2016
grep -qF 'name        = "run-predictor"' "$SOFTWARE_FORMULA" \
  || ac_fail "formulas/run-predictor.toml no longer declares the predictor formula"
ac_log "run-predictor.toml: valid TOML, intact"

# Fixed-string greps for literal lines containing $-variable references.
# shellcheck disable=SC2016
grep -qF 'load_formula_or_profile "predictor" "$PREDICTOR_FORMULA"' "$PREDICTOR_RUN" \
  || ac_fail "predictor-run.sh no longer loads the formula via load_formula_or_profile"
# shellcheck disable=SC2016
grep -qF 'agent_run --worktree "$WORKTREE" "$PROMPT"' "$PREDICTOR_RUN" \
  || ac_fail "predictor-run.sh session lifecycle (agent_run) changed"
ac_log "formula loading and session lifecycle unchanged"

# No new polling loop: predictor-run.sh must not spin its own loop or sleep,
# and the predictor dir must not gain a second executor script.
grep -qE '^[[:space:]]*(while (true|:)|sleep )' "$PREDICTOR_RUN" \
  && ac_fail "predictor-run.sh adds a polling loop or sleep"
EXTRA_SH="$(find "$REPO_ROOT/predictor" -name '*.sh' | grep -cv 'predictor-run.sh' || true)"
[ "$EXTRA_SH" -eq 0 ] || ac_fail "predictor/ gained a new executor script (daemon?)"
ac_log "no new polling loop or daemon"

ac_pass
