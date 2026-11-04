#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2100.sh
#
# Issue #2100: remove the artifacts-disk recipe until research runs exist.
#
#   supervisor/recipes.yaml — the artifacts-disk recipe (P1, disk_pct_gt 80 on
#   the "Research Runs" section, #1322) is deleted. The comment left under the
#   Research Runs header names the reason (artifacts/ is empty; on a shared
#   volume the percentage is the neighbours' usage) and the restore path (the
#   research kind, #1293, with a `Disk owner:` line so disk_pct_gt skips usage
#   that is not the factory's, #2077). run-heartbeat-stale (P2) and
#   judgment-stale (P3) keep their exact wiring.
#   formulas/run-supervisor.toml — the "Artifacts disk > 80%" line is gone.
#   supervisor/preflight.sh — untouched: it still prints the Artifacts Disk
#   line, so restoring the recipe later needs no preflight work.
#   supervisor/AGENTS.md — the research-run sentence no longer names a P1 tier.
#
# Hermetic: fixture preflight text plus a throwaway ops root; no forge, no
# live box. Run via: tools/run-acceptance.sh 2100
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq awk grep sed cat mktemp date df

RECIPES="$REPO_ROOT/supervisor/recipes.yaml"
EVALUATOR="$REPO_ROOT/supervisor/evaluate-recipes.sh"
PREFLIGHT="$REPO_ROOT/supervisor/preflight.sh"
FORMULA="$REPO_ROOT/formulas/run-supervisor.toml"
AGENTS_MD="$REPO_ROOT/supervisor/AGENTS.md"
TEST_1322="$REPO_ROOT/tests/acceptance/issue-1322.sh"

for f in "$RECIPES" "$EVALUATOR" "$PREFLIGHT" "$FORMULA" "$AGENTS_MD" "$TEST_1322"; do
  ac_assert_file "$f" "required file is missing: ${f#"$REPO_ROOT"/}"
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── AC1: the recipe is gone from recipes.yaml ───────────────────────────────
ac_log 'AC1: recipes.yaml carries no artifacts-disk recipe'
_hits="$(grep -c 'name: artifacts-disk' "$RECIPES" || true)"
ac_assert_eq "$_hits" "0" "AC1: artifacts-disk must be deleted from recipes.yaml (#2100); grep -c found $_hits"

# Nothing may run disk_pct_gt against the Research Runs section any more: the
# figure is df of ${OPS_REPO_ROOT}/artifacts on a volume the box shares.
_offenders="$(awk '
  /^  - name: / {
    if (sec == "\"Research Runs\"" && rule == "disk_pct_gt") print name
    name = $2; sec = ""; rule = ""; next
  }
  /^      section: / { sec = $2 }
  /^      rule: / { rule = $2 }
  END { if (sec == "\"Research Runs\"" && rule == "disk_pct_gt") print name }
' "$RECIPES")"
[ -z "$_offenders" ] \
  || ac_fail "AC1: a recipe still runs disk_pct_gt on Research Runs: $_offenders"

# The replacement comment must name both issue numbers and the Disk owner fix.
_comment="$(awk '
  /^  # .*Research Runs/ { inblk = 1; next }
  inblk && /^  - name: / { exit }
  inblk && /^  #/ { print }
' "$RECIPES")"
for needle in '#2100' '#1293' '#2077' 'Disk owner:'; do
  case "$_comment" in
    *"$needle"*) ;;
    *) ac_fail "AC1: the Research Runs comment must name $needle (#2100); got: $_comment" ;;
  esac
done

# ── AC2: the two survivors keep their exact wiring ──────────────────────────
ac_log 'AC2: run-heartbeat-stale and judgment-stale still carry their #1322 wiring'
recipe_of() {
  awk -v want="$1" '
    /^  - name: / {
      if (inblk) { exit }
      inblk = ($0 == "  - name: " want)
    }
    inblk { print }
  ' "$RECIPES"
}

for _pair in 'run-heartbeat-stale P2 any_older_than_min 70' \
             'judgment-stale P3 judgment_age_h_gt 4'; do
  read -r _name _sev _rule _thr <<< "$_pair"
  _block="$(recipe_of "$_name")"
  [ -n "$_block" ] || ac_fail "AC2: recipe $_name is missing from recipes.yaml"
  ac_assert_eq "$(printf '%s\n' "$_block" | head -n 1)" "  - name: $_name" \
    "AC2: $_name block must start with its name line"
  printf '%s\n' "$_block" | grep -q "^    severity: $_sev$" \
    || ac_fail "AC2: $_name severity must stay $_sev, block was: $_block"
  printf '%s\n' "$_block" | grep -q '^      section: "Research Runs"$' \
    || ac_fail "AC2: $_name must still detect on the Research Runs section"
  printf '%s\n' "$_block" | grep -q "^      rule: $_rule$" \
    || ac_fail "AC2: $_name rule must stay $_rule"
  printf '%s\n' "$_block" | grep -q "^      threshold: $_thr$" \
    || ac_fail "AC2: $_name threshold must stay $_thr"
  printf '%s\n' "$_block" | grep -q '^    action: incident$' \
    || ac_fail "AC2: $_name action must stay incident"
  printf '%s\n' "$_block" | grep -q '^      source: preflight$' \
    || ac_fail "AC2: $_name source must stay preflight"
done

# ── AC3: evaluate-recipes.sh fires exactly the two (needs yq) ────────────────
if command -v yq >/dev/null 2>&1; then
  ac_log 'AC3: evaluate-recipes.sh on a Research Runs fixture'
  cat > "$WORK/preflight-fixture.txt" <<'EOF'
## Research Runs
In-flight: 1
  run-old: 95min old
Oldest judgment: 5h (#12)
Artifacts Disk: 85% used
EOF

  _stderr="$WORK/eval-stderr.txt"
  _rc=0
  _fired="$(bash "$EVALUATOR" "$RECIPES" "$WORK/preflight-fixture.txt" 2>"$_stderr")" || _rc=$?
  ac_assert_eq "$_rc" "0" "AC3: evaluate-recipes.sh must still parse recipes.yaml: $(head -n 1 "$_stderr")"
  if [ -s "$_stderr" ]; then
    ac_fail "AC3: evaluate-recipes.sh warned: $(head -n 1 "$_stderr")"
  fi
  ac_assert_jq '(.fired | map(.name) | sort) == ["judgment-stale","run-heartbeat-stale"]' \
    "$_fired" "AC3: only run-heartbeat-stale and judgment-stale may fire; got: $_fired"
  ac_assert_jq '[.fired[] | select(.severity == "P1")] | length == 0' \
    "$_fired" "AC3: the removed artifacts-disk recipe must not fire as a P1: $_fired"

  : > "$WORK/preflight-blank.txt"
  _rc=0
  _fired_blank="$(bash "$EVALUATOR" "$RECIPES" "$WORK/preflight-blank.txt" 2>/dev/null)" || _rc=$?
  ac_assert_eq "$_rc" "0" "AC3: evaluate-recipes.sh must survive an empty preflight"
  ac_assert_jq '.fired | length == 0' "$_fired_blank" \
    "AC3: an empty preflight must fire nothing; got: $_fired_blank"
else
  ac_log 'AC3 skipped: yq is not on this host (structural checks above still apply)'
fi

# ── AC4: the formula and the doc no longer list the P1 artifacts tier ────────
ac_log 'AC4: run-supervisor.toml has no Artifacts disk line; AGENTS.md names the removal'
if grep -qF 'Artifacts disk > 80%' "$FORMULA"; then
  ac_fail "AC4: formulas/run-supervisor.toml must drop the Artifacts disk > 80% line (#2100)"
fi
grep -qF 'In-flight research run older than 70 min' "$FORMULA" \
  || ac_fail "AC4: the formula must keep the P2 in-flight run finding (#1322)"
grep -qF 'Oldest open judgment-labeled issue older than 4 h' "$FORMULA" \
  || ac_fail "AC4: the formula must keep the P3 judgment finding (#1322)"

grep -qF 'P1 artifacts-disk recipe is' "$AGENTS_MD" \
  || ac_fail "AC4: supervisor/AGENTS.md must document that artifacts-disk is removed (#2100)"
grep -qF 'removed until research runs exist, #2100' "$AGENTS_MD" \
  || ac_fail "AC4: supervisor/AGENTS.md must name the removal reason and #2100"
if grep -qF 'P1 artifacts disk > 80%' "$AGENTS_MD"; then
  ac_fail "AC4: supervisor/AGENTS.md must not still list the P1 artifacts disk tier"
fi
grep -qF 'artifacts disk %' "$AGENTS_MD" \
  || ac_fail "AC4: supervisor/AGENTS.md must still say preflight reports artifacts disk %"

# ── AC5: preflight.sh still reports the artifacts disk percentage ────────────
ac_log 'AC5: preflight.sh still emits the Artifacts Disk line (untouched)'
RR_FN="$(ac_extract_fn __preflight_research_runs "$PREFLIGHT")"
[ -n "$RR_FN" ] || ac_fail "AC5: preflight.sh must still define __preflight_research_runs"
grep -qE '^[[:space:]]*__preflight_research_runs[[:space:]]*$' "$PREFLIGHT" \
  || ac_fail "AC5: preflight.sh main block must still call __preflight_research_runs"
grep -qF 'Disk owner:' "$PREFLIGHT" \
  || ac_fail "AC5: preflight.sh must still carry the Disk owner line (#2077)"

OPS="$WORK/ops-root"
mkdir -p "$OPS/runs" "$OPS/artifacts"
_started="$(date -u -d "@$(( $(date +%s) - 5700 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"id":"run-old","started":"%s"}\n' "$_started" > "$OPS/runs/run-old.json"

_rr_out="$(RR_OPS="$OPS" RR_FN="$RR_FN" bash -c '
  set -u
  OPS_REPO_ROOT="$RR_OPS"
  eval "$RR_FN"
  forge_api() { printf "%s\n" "[]"; }
  __preflight_research_runs
' 2>&1)" || ac_fail "AC5: __preflight_research_runs exited non-zero: $_rr_out"

printf '%s\n' "$_rr_out" | grep -qE '^Artifacts Disk: [0-9]+% used$' \
  || ac_fail "AC5: preflight must still print an Artifacts Disk line; got: $_rr_out"

# ── AC6: syntax, and the #1322 acceptance test still passes ──────────────────
ac_log 'AC6: bash -n on the evaluator; issue-1322.sh still passes'
bash -n "$EVALUATOR" || ac_fail "AC6: evaluate-recipes.sh must parse with bash -n"
bash -n "$PREFLIGHT" || ac_fail "AC6: preflight.sh must parse with bash -n"
bash "$TEST_1322" >/dev/null || ac_fail "AC6: tests/acceptance/issue-1322.sh must still pass after the removal"

ac_pass
