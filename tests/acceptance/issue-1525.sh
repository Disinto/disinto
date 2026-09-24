#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1525.sh
#
# Issue #1525: catalog_forecount writes est_dvision from mean duration_s.
#
# Contract: on the counts path only (n >= CATALOG_FORECAST_MIN_N, default 5,
# and `actual` an integer percent), est_dvision is the row's `mean duration_s`
# (field 8) when that cell is a number, else 0. est_cost stays 0, p_success stays
# actual/100, method stays counts. Off the counts path (n too small, unsampled,
# or no row) the flat prior applies: est_dvision stays 0, method prior.
#
# Acceptance (hermetic — no network, no forge, no agents started): the
# function is exercised in-process by sourcing lib/catalog-forecast.sh in a
# throwaway subshell and calling `catalog_forecast dev backlog` against three
# hand-written catalog fixtures:
#   1. n=16 actual=63% mean=100.0 -> counts, p_success 0.63, est_dvision 100
#   2. n=16 actual=63% mean=-      -> counts, p_success 0.63, est_dvision 0
#   3. n=4  actual=63% mean=100.0 -> prior,  p_success 0.5,  est_dvision 0
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd jq

ac_assert_file "$REPO_ROOT/lib/catalog-forecast.sh" \
  "lib/catalog-forecast.sh must exist"
grep -n 'catalog_forecast' "$REPO_ROOT/lib/catalog-forecast.sh" >/dev/null \
  || ac_fail "lib/catalog-forecast.sh must define catalog_forecast"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Catalog fixtures: counts-with-mean, counts-unsampled-mean, n-too-small ──
CAT_ROOT="$TMP_DIR/catalog"
mkdir -p "$CAT_ROOT"

# n=16 (>=5), actual=63%, mean=100.0 -> counts, est_dvision=100.
cat > "$CAT_ROOT/cal_mean100.md" <<'CAT'
| loop | class | n | promised | actual | error | mean duration_s |
|---|---|---|---|---|---|---|
| dev | backlog | 16 | 50% | 63% | 13 | 100.0 |
CAT

# n=16 (>=5), actual=63%, mean=- -> counts, est_dvision stays 0.
cat > "$CAT_ROOT/cal_meanminus.md" <<'CAT'
| loop | class | n | promised | actual | error | mean duration_s |
|---|---|---|---|---|---|---|
| dev | backlog | 16 | 50% | 63% | 13 | - |
CAT

# n=4 (< MIN_N 5) -> prior, est_dvision stays 0 (n-check gates it out).
cat > "$CAT_ROOT/cal_toosmall.md" <<'CAT'
| loop | class | n | promised | actual | error | mean duration_s |
|---|---|---|---|---|---|---|
| dev | backlog | 4 | 50% | 63% | 13 | 100.0 |
CAT

# ── run_forecast <CATALOG> ─────────────────────────────────────────────────────
# Run the catalog forecast lib's `catalog_forecast dev backlog` in a throwaway
# subshell. Emits two parseable lines:
#   FORECAST:<json>
#   METHOD:<counts|prior>
# CATALOG_FILE is set per invocation. Note the lib's CATALOG_FORECAST_METHOD export
# only survives if `catalog_forecast` runs in the (same) subshell — NOT via
# $(...) command substitution. So the JSON is written to a file and the method
# is read in the subshell, avoiding the $(...) export trap.
run_forecast() {
  local catalog="$1" jsonf="$TMP_DIR/.forecast.json"
  (
    export CATALOG_FILE="$catalog"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/lib/catalog-forecast.sh"
    catalog_forecast dev backlog > "$jsonf"
    printf 'FORECAST:%s\nMETHOD:%s\n' "$(cat "$jsonf")" "$CATALOG_FORECAST_METHOD"
  ) 2>&1
}

# ── Case 1: counts, numeric mean 100.0 -> est_dvision 100, p_success 0.63 ────
out="$(run_forecast "$CAT_ROOT/cal_mean100.md")"
forecast_json="$(printf '%s\n' "$out" | sed -n '/^FORECAST:/{s/^FORECAST://;p}')"
method1="$(printf '%s\n' "$out" | sed -n '/^METHOD:/{s/^METHOD://;p}')"
[ -n "$forecast_json" ] || ac_fail "case 1: forecast JSON empty (out=$out)"
ac_assert_jq '.p_success == 0.63 and .est_cost == 0 and .est_dvision == 100' \
  "$forecast_json" "case 1 (n=16, actual=63%, mean=100.0): est_dvision=100, p_success=0.63, est_cost=0"
ac_assert_eq "$method1" "counts" "case 1: method=counts"

# ── Case 2: counts, unsampled mean (-) -> est_dvision stays 0 ─────────────────
out="$(run_forecast "$CAT_ROOT/cal_meanminus.md")"
forecast_json="$(printf '%s\n' "$out" | sed -n '/^FORECAST:/{s/^FORECAST://;p}')"
method2="$(printf '%s\n' "$out" | sed -n '/^METHOD:/{s/^METHOD://;p}')"
[ -n "$forecast_json" ] || ac_fail "case 2: forecast JSON empty (out=$out)"
ac_assert_jq '.p_success == 0.63 and .est_cost == 0 and .est_dvision == 0' \
  "$forecast_json" "case 2 (n=16, actual=63%, mean=-): est_dvision=0, p_success=0.63, est_cost=0"
ac_assert_eq "$method2" "counts" "case 2: method=counts"

# ── Case 3: n too small -> prior, est_dvision stays 0 ─────────────────────────
out="$(run_forecast "$CAT_ROOT/cal_toosmall.md")"
forecast_json="$(printf '%s\n' "$out" | sed -n '/^FORECAST:/{s/^FORECAST://;p}')"
method3="$(printf '%s\n' "$out" | sed -n '/^METHOD:/{s/^METHOD://;p}')"
[ -n "$forecast_json" ] || ac_fail "case 3: forecast JSON empty (out=$out)"
ac_assert_jq '.p_success == 0.5 and .est_cost == 0 and .est_dvision == 0' \
  "$forecast_json" "case 3 (n=4, mean=100.0): prior est_dvision=0, p_success=0.5"
ac_assert_eq "$method3" "prior" "case 3: method=prior (n < MIN_N)"

ac_pass
