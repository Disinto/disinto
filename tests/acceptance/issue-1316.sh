#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1316.sh
#
# Issue #1316: research-mode predictor. predictor/predictor-run.sh must select
# the predictor formula from PROJECT_KIND (project TOML `kind`, #1294):
#   - absent kind and PROJECT_KIND=software  -> formulas/run-predictor.toml
#   - PROJECT_KIND=research                  -> formulas/run-predictor-research.toml
# and the research formula must instruct the model to read the run ledger
# (ops/runs/), artifact payloads (ops/artifacts/), RESOURCES.md host caps,
# and open judgment issues — with predictions still filed
# `prediction/unreviewed`. The software path keeps the existing formula.
# No new polling loop: both kinds run on the existing predictor cadence.
#
# Verifies (all checks read-only — no forge, no nomad, no repo mutation):
#   1. predictor_formula_file() extracted from predictor/predictor-run.sh
#      returns the run-predictor.toml path for absent PROJECT_KIND and for
#      software.
#   2. it returns the run-predictor-research.toml path for research.
#   3. the research formula exists, is valid TOML, and its text covers the
#      five operational weakness classes (host down, cap starved, artifact
#      missing, llama lease exceeded, judgment sitting) and names ops/runs/,
#      ops/artifacts/, RESOURCES.md caps, and judgment labels as inputs,
#      with predictions filed `prediction/unreviewed`.
#   4. software path is unchanged in shape: formulas/run-predictor.toml
#      still exists with its software content, and predictor-run.sh still
#      loads the selected formula via load_formula_or_profile and still runs
#      the same session lifecycle (agent_run) with no new polling loop.
#
# Run via: tools/run-acceptance.sh 1316
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

ac_assert_file "$PREDICTOR_RUN" "predictor/predictor-run.sh is missing"
ac_assert_file "$SOFTWARE_FORMULA" "formulas/run-predictor.toml is missing"
ac_assert_file "$RESEARCH_FORMULA" "formulas/run-predictor-research.toml is missing"

# ── 1+2. Behaviour: predictor_formula_file() picks by PROJECT_KIND ────────
# <kind> empty = PROJECT_KIND unset. ac_pick_in_subshell runs the extracted
# function in a throwaway subshell with a fixed fake FACTORY_ROOT (shared
# helper — tests/lib/acceptance-helpers.sh).
FN="$(ac_extract_fn predictor_formula_file "$PREDICTOR_RUN")"
[ -n "$FN" ] || ac_fail "predictor_formula_file() not found in predictor/predictor-run.sh"

SOFTWARE_PATH="/srv/disinto/formulas/run-predictor.toml"
RESEARCH_PATH="/srv/disinto/formulas/run-predictor-research.toml"

OUT="$(ac_pick_in_subshell "" "$FN" predictor_formula_file)"
ac_assert_eq "$OUT" "$SOFTWARE_PATH" \
  "absent PROJECT_KIND: expected $SOFTWARE_PATH, got $OUT"
ac_log "selection: absent PROJECT_KIND -> run-predictor.toml"

OUT="$(ac_pick_in_subshell "software" "$FN" predictor_formula_file)"
ac_assert_eq "$OUT" "$SOFTWARE_PATH" \
  "PROJECT_KIND=software: expected $SOFTWARE_PATH, got $OUT"
ac_log "selection: PROJECT_KIND=software -> run-predictor.toml"

OUT="$(ac_pick_in_subshell "research" "$FN" predictor_formula_file)"
ac_assert_eq "$OUT" "$RESEARCH_PATH" \
  "PROJECT_KIND=research: expected $RESEARCH_PATH, got $OUT"
ac_log "selection: PROJECT_KIND=research -> run-predictor-research.toml"

# ── 3. Research formula text ────────────────────────────────────────────────
python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$RESEARCH_FORMULA" \
  || ac_fail "formulas/run-predictor-research.toml is not valid TOML"
ac_log "research formula: valid TOML"

grep -q "runs/" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not reference the ops runs/ ledger"
grep -q "artifacts/" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not reference ops artifacts/ payloads"
grep -q "RESOURCES.md" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not reference RESOURCES.md host caps"
grep -q "cap:" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not name the host cap field"
grep -q "judgment" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not cover open judgment labels"
grep -qi "llama lease" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not cover the llama lease weakness"
grep -qi "host down" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not cover the host-down weakness"
grep -qi "cap starved" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not cover the cap-starved weakness"
grep -qi "artifact missing" "$RESEARCH_FORMULA" \
  || ac_fail "research formula does not cover the artifact-missing weakness"
grep -q "prediction/unreviewed" "$RESEARCH_FORMULA" \
  || ac_fail "research formula predictions are not filed prediction/unreviewed"
ac_log "research formula: ledger/artifacts/caps/judgment inputs, five weakness classes"

# ── 4. Software path has no behaviour change; no new polling loop ──────────
python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$SOFTWARE_FORMULA" \
  || ac_fail "formulas/run-predictor.toml is not valid TOML"
# shellcheck disable=SC2016
grep -qF 'name        = "run-predictor"' "$SOFTWARE_FORMULA" \
  || ac_fail "formulas/run-predictor.toml no longer declares the software predictor"
ac_log "software formula: unchanged"

# Fixed-string greps for literal lines containing $-variable references.
# shellcheck disable=SC2016
grep -qF 'load_formula_or_profile "predictor" "$PREDICTOR_FORMULA"' "$PREDICTOR_RUN" \
  || ac_fail "predictor-run.sh no longer loads the selected formula via load_formula_or_profile"
# shellcheck disable=SC2016
grep -qF 'agent_run --worktree "$WORKTREE" "$PROMPT"' "$PREDICTOR_RUN" \
  || ac_fail "predictor-run.sh session lifecycle (agent_run) changed"
ac_log "software path: formula loading and session lifecycle unchanged"

# No new polling loop: predictor-run.sh must not spin its own loop or sleep,
# and the predictor dir must not gain a second executor script.
grep -qE '^[[:space:]]*(while (true|:)|sleep )' "$PREDICTOR_RUN" \
  && ac_fail "predictor-run.sh adds a polling loop or sleep"
EXTRA_SH="$(find "$REPO_ROOT/predictor" -name '*.sh' | grep -cv 'predictor-run.sh' || true)"
[ "$EXTRA_SH" -eq 0 ] || ac_fail "predictor/ gained a new executor script (daemon?)"
ac_log "no new polling loop or daemon"

ac_pass
