#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1322.sh
#
# Issue #1322: supervisor recipes for experiment runs (bash, not Opus).
# preflight.sh must emit a "## Research Runs" section when the ops run
# ledger (${OPS_REPO_ROOT}/runs, #1297) exists — in-flight count (rows with
# no `ended` or empty `exit`), per-run ages, artifacts disk usage %, and the
# oldest open `judgment`-labeled issue's age in hours (or `none`) — and omit
# the section entirely when runs/ is absent. recipes.yaml gains three
# `action: incident` recipes wired to the new section, and
# evaluate-recipes.sh must still parse recipes.yaml and fire them (new rule
# judgment_age_h_gt).
#
# Verifies (hermetic — a throwaway ops root in a mktemp dir only; the
# extracted __preflight_research_runs function is driven in a subshell with
# stubbed forge_api/date, so no forge, no live repo mutation):
#   1. preflight.sh defines __preflight_research_runs and the main block
#      calls it (wiring).
#   2. With a fixture ops root (runs/ + artifacts/), the function prints the
#      section: In-flight: 2, per-run "Nmin old" lines for in-flight rows
#      only, Artifacts Disk %, Oldest judgment: 5h (#12).
#   3. With an ops root lacking runs/ (or OPS_REPO_ROOT unset), the function
#      prints nothing (omission, not a failure).
#   4. recipes.yaml carries the three recipes (artifacts-disk P1,
#      run-heartbeat-stale P2, judgment-stale P3), each action: incident on
#      the "Research Runs" section, and evaluate-recipes.sh implements the
#      judgment_age_h_gt rule.
#   5. Where yq is available, evaluate-recipes.sh still parses recipes.yaml:
#      a fixture preflight fires exactly the three new recipes (all
#      incident), and an empty preflight fires none.
#
# Run via: tools/run-acceptance.sh 1322
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq date df awk sed mktemp

PREFLIGHT="$REPO_ROOT/supervisor/preflight.sh"
RECIPES="$REPO_ROOT/supervisor/recipes.yaml"
EVALUATOR="$REPO_ROOT/supervisor/evaluate-recipes.sh"

ac_assert_file "$PREFLIGHT" "supervisor/preflight.sh is missing"
ac_assert_file "$RECIPES" "supervisor/recipes.yaml is missing"
ac_assert_file "$EVALUATOR" "supervisor/evaluate-recipes.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── 1. Wiring: the section function exists and the main block calls it ──────
_section_fn="$(ac_extract_fn __preflight_research_runs "$PREFLIGHT")"
[ -n "$_section_fn" ] || ac_fail "preflight.sh does not define __preflight_research_runs"
grep -qE '^[[:space:]]*__preflight_research_runs[[:space:]]*$' "$PREFLIGHT" \
  || ac_fail "preflight.sh main block never calls __preflight_research_runs"

# ── 2+3. Function behaviour against a throwaway ops root ────────────────────
# The function's clock and forge access are stubbed: `date` answers a fixed
# epoch (fixture timestamps are encoded as rel:<seconds-ago>) and forge_api
# returns a canned judgment list, so output is deterministic on any host
# (busybox or GNU).
run_rr() {
  # $1 = ops root ("" = unset), $2 = judgment JSON
  RR_OPS="${1:-}" RR_JUDG="$2" RR_NOW=1750000000 RR_FN="$_section_fn" bash -c '
    set -u
    export OPS_REPO_ROOT="$RR_OPS"
    eval "$RR_FN"
    forge_api() { printf "%s\n" "$RR_JUDG"; }
    date() {
      if [ "$1" = "-d" ]; then
        off="${2#rel:}"
        if [ -n "$off" ]; then
          printf "%s\n" "$(( RR_NOW - off ))"
        else
          printf "0\n"
        fi
      else
        printf "%s\n" "$RR_NOW"
      fi
    }
    __preflight_research_runs
  ' 2>&1
}

OPS="$TMP_DIR/ops"
mkdir -p "$OPS/runs" "$OPS/artifacts"
printf '{"id":"run-old","started":"rel:5700"}\n' > "$OPS/runs/run-old.json"
printf '{"id":"run-new","started":"rel:600"}\n' > "$OPS/runs/run-new.json"
printf '{"id":"run-done","started":"rel:90000","ended":"rel:80000","exit":0}\n' > "$OPS/runs/run-done.json"

JUDG_JSON='[{"number":12,"created_at":"rel:18000"},{"number":13,"created_at":"rel:1800"}]'

_out="$(run_rr "$OPS" "$JUDG_JSON")" || ac_fail "__preflight_research_runs exited non-zero"

printf '%s\n' "$_out" | grep -q '^## Research Runs$' \
  || ac_fail "section header missing from output: $_out"
printf '%s\n' "$_out" | grep -q '^In-flight: 2$' \
  || ac_fail "in-flight count is not 2: $(printf '%s\n' "$_out" | grep '^In-flight:' || true)"
_old_age="$(printf '%s\n' "$_out" | sed -n 's/^  run-old: \([0-9][0-9]*\)min old$/\1/p')"
[ "$_old_age" = "95" ] || ac_fail "run-old age is ${_old_age:-missing}, want 95min old"
_new_age="$(printf '%s\n' "$_out" | sed -n 's/^  run-new: \([0-9][0-9]*\)min old$/\1/p')"
[ "$_new_age" = "10" ] || ac_fail "run-new age is ${_new_age:-missing}, want 10min old"
case "$_out" in
  *"run-done"*) ac_fail "finished run run-done is listed as in-flight" ;;
esac
printf '%s\n' "$_out" | grep -qE '^Artifacts Disk: [0-9]+% used$' \
  || ac_fail "Artifacts Disk line missing or malformed: $_out"
_judg_age="$(printf '%s\n' "$_out" | sed -n 's/^Oldest judgment: \([0-9][0-9]*\)h (#12)$/\1/p')"
[ "$_judg_age" = "5" ] || ac_fail "oldest judgment age is ${_judg_age:-missing}, want 5h (#12)"

# Absent ledger → the section is omitted entirely (and not a failure)
OPS_NORUNS="$TMP_DIR/ops-noruns"
mkdir -p "$OPS_NORUNS"
_out_noruns="$(run_rr "$OPS_NORUNS" "$JUDG_JSON")" \
  || ac_fail "__preflight_research_runs exited non-zero (no runs dir)"
[ -z "$_out_noruns" ] || ac_fail "section printed although runs/ is absent: $_out_noruns"
_out_unset="$(run_rr "" "$JUDG_JSON")" \
  || ac_fail "__preflight_research_runs exited non-zero (OPS_REPO_ROOT unset)"
[ -z "$_out_unset" ] || ac_fail "section printed although OPS_REPO_ROOT is unset: $_out_unset"

# ── 4. recipes.yaml: three incident recipes wired to the new section ────────
# Exact block comparison (name, severity, section, rule, threshold, action in
# one shot per recipe). Parsed with awk — no yq dependency, so this also runs
# on the busybox CI runner.
recipe_block() {
  awk -v name="$1" '
    inblk && /^  - name: / { exit }
    $0 == "  - name: " name { inblk = 1 }
    inblk { print }
  ' "$RECIPES"
}

_expected='  - name: artifacts-disk
    severity: P1
    detect:
      source: preflight
      section: "Research Runs"
      rule: disk_pct_gt
      threshold: 80
    action: incident'
[ "$(recipe_block artifacts-disk)" = "$_expected" ] \
  || ac_fail "artifacts-disk recipe block is not P1/disk_pct_gt/80/incident on Research Runs"
_expected='  - name: run-heartbeat-stale
    severity: P2
    detect:
      source: preflight
      section: "Research Runs"
      rule: any_older_than_min
      threshold: 70
    action: incident'
[ "$(recipe_block run-heartbeat-stale)" = "$_expected" ] \
  || ac_fail "run-heartbeat-stale recipe block is not P2/any_older_than_min/70/incident on Research Runs"
_expected='  - name: judgment-stale
    severity: P3
    detect:
      source: preflight
      section: "Research Runs"
      rule: judgment_age_h_gt
      threshold: 4
    action: incident'
[ "$(recipe_block judgment-stale)" = "$_expected" ] \
  || ac_fail "judgment-stale recipe block is not P3/judgment_age_h_gt/4/incident on Research Runs"

grep -q "eval_judgment_age_h_gt" "$EVALUATOR" \
  || ac_fail "evaluate-recipes.sh does not implement the judgment_age_h_gt rule"

# ── 5. evaluate-recipes.sh still parses recipes.yaml (needs yq) ─────────────
if command -v yq >/dev/null 2>&1; then
  cat > "$TMP_DIR/preflight-fixture.txt" <<'EOF'
## Research Runs
In-flight: 1
  run-old: 95min old
Artifacts Disk: 85% used
Oldest judgment: 5h (#12)
EOF

  _err="$TMP_DIR/eval-stderr.txt"
  _fired="$(bash "$EVALUATOR" "$RECIPES" "$TMP_DIR/preflight-fixture.txt" 2>"$_err")" \
    || ac_fail "evaluate-recipes.sh failed to parse recipes.yaml"
  if [ -s "$_err" ]; then
    ac_fail "evaluate-recipes.sh warned: $(head -n 1 "$_err")"
  fi
  jq -e '(.fired | map(.name) | sort) == ["artifacts-disk","judgment-stale","run-heartbeat-stale"]' \
    <<<"$_fired" >/dev/null \
    || ac_fail "expected exactly artifacts-disk, run-heartbeat-stale, judgment-stale to fire; got: $_fired"
  jq -e '[.fired[] | select(.action != "incident")] | length == 0' \
    <<<"$_fired" >/dev/null \
    || ac_fail "fired Research Runs recipes must all be action: incident"

  : > "$TMP_DIR/preflight-empty.txt"
  _fired_empty="$(bash "$EVALUATOR" "$RECIPES" "$TMP_DIR/preflight-empty.txt" 2>/dev/null)" \
    || ac_fail "evaluate-recipes.sh failed on an empty preflight"
  jq -e '.fired | length == 0' <<<"$_fired_empty" >/dev/null \
    || ac_fail "no Research Runs section present -> no recipe should fire"
else
  ac_log "yq not on this host — skipping live evaluate-recipes.sh run (structural recipe checks above still apply)"
fi

ac_pass
