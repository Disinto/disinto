#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1461.sh
#
# Issue #1461: emit_tape_proposal (dev-poll) must write p_success from the ops
# catalog's measured counts (lib/catalog-forecast.sh) instead of the flat
# prior, and record the method used in context.forecast_method.
#
# Contract:
#   - A fresh pick calls `catalog_forecast dev "<class>"` and uses its JSON
#     as the forecast arg. When a row's n >= CATALOG_FORECAST_MIN_N (default 5)
#     AND its `actual` is an integer percent, the record carries
#     p_success=<actual/100> (JSON number) and context.forecast_method="counts";
#     otherwise the flat prior p_success=0.5 and context.forecast_method="prior".
#     The API-failure path (context={}) still writes the forecast JSON but
#     omits forecast_method. Never fail the pick (rc 0).
#   - est_cost/est_dvision stay 0. No WAL read, no queue ranking.
#
# Acceptance (read-only — no live services, no agents started, no pick
# triggered; the emitter is exercised in-process with a stub curl, the same
# extract-and-stub approach as issue-1398):
#   1. catalog row n=16 actual=63% -> p_success 0.63, forecast_method=counts
#   2. catalog row n=4 (below MIN_N 5) -> p_success 0.5, forecast_method=prior
#   3. catalog row actual=- (unsampled) -> p_success 0.5, forecast_method=prior
#   4. catalog file absent -> pick still rc 0; p_success 0.5, forecast_method=prior
#   5. API failure (context={}) -> forecast still written (0.5), method omitted
#   6. fresh pick's recorded forecast on the proposal record (forecast_method
#      = counts, p_success = 0.63) — the counts path exercised end-to-end
#
# The shared ac_run_tape_emit only sources lib/tape.sh (where the old tests
# rely on the flat prior), so it leaves catalog_forecast undefined and the
# `command -v catalog_forecast` guard degrades to the prior. This test sources
# BOTH lib/tape.sh and lib/catalog-forecast.sh via a local runner so the counts
# path is actually exercised.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd jq

TARGET="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$TARGET" "dev/dev-poll.sh must exist"

# ── Wiring: dev-poll sources the catalog-forecast lib and uses it ──────────
grep -qE '^source .*lib/catalog-forecast\.sh' "$TARGET" \
  || ac_fail "dev-poll.sh must source lib/catalog-forecast.sh"
grep -q 'catalog_forecast dev' "$TARGET" \
  || ac_fail "dev-poll.sh must call catalog_forecast in emit_tape_proposal"
grep -q 'CATALOG_FORECAST_METHOD' "$TARGET" \
  || ac_fail "dev-poll.sh must read CATALOG_FORECAST_METHOD for the context"
# The flat-prior literal must no longer be the unconditional forecast source
# (the prior now only appears as the `command -v` fallback).
ac_extract_fn emit_tape_proposal "$TARGET" >/dev/null \
  || ac_fail "could not extract emit_tape_proposal() from dev-poll.sh"

FN_SRC="$(ac_extract_fn emit_tape_proposal "$TARGET")"
[ -n "$FN_SRC" ] || ac_fail "could not extract emit_tape_proposal() from dev-poll.sh"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-1461"   # sentinel — can never clobber a live id file
trap 'rm -rf "$TMP_DIR" \
  /tmp/dev-proposal-id-acceptance-1461-1461 \
  /tmp/dev-proposal-id-acceptance-1461-1462 \
  /tmp/dev-proposal-id-acceptance-1461-1463 \
  /tmp/dev-proposal-id-acceptance-1461-1464 \
  /tmp/dev-proposal-id-acceptance-1461-1465' EXIT

# ── Catalog fixtures: one good row, one n-too-small, one unsampled ─────────
CAT_ROOT="$TMP_DIR/catalog"
mkdir -p "$CAT_ROOT"

# Good row: n=16 (>=5), actual=63% -> counts, p_success 0.63.
cat > "$CAT_ROOT/cal_counts.md" <<'CAT'
| loop | class | n | promised | actual | error | mean duration_s |
|---|---|---|---|---|---|---|
| dev | backlog | 16 | 50% | 63% | 13 | 100.0 |
CAT

# n=4 (< MIN_N 5), actual is a valid percent -> prior (n-check gates it out).
cat > "$CAT_ROOT/cal_toosmall.md" <<'CAT'
| loop | class | n | promised | actual | error | mean duration_s |
|---|---|---|---|---|---|---|
| dev | backlog | 4 | 50% | 63% | 13 | 100.0 |
CAT

# n=16 (>=5), actual=- (unsampled) -> prior (actual-check gates it out).
cat > "$CAT_ROOT/cal_nosample.md" <<'CAT'
| loop | class | n | promised | actual | error | mean duration_s |
|---|---|---|---|---|---|---|
| dev | backlog | 16 | 50% | - | 13 | 100.0 |
CAT

# ── Hermetic forge stub + log() stand-in (run_emit sources two libs) ────────
ac_stub_bin_and_log "$TMP_DIR/bin"

# ── run_emit <TAPE_DIR> <issue> [fail] ───────────────────────────────────────
# Run the extracted emitter in a throwaway subshell: stub curl first on PATH,
# the ac_stub_env sentinels (plus FORGE_API), AND both lib/tape.sh and
# lib/catalog-forecast.sh (unlike ac_run_tape_emit, which sources only tape.sh
# so the counts path can't be exercised). CATALOG_FILE is inherited from the
# caller (exported by the test). fail=1 degrades the stub like an unreachable API.
run_emit() {
  local tape_dir="$1" issue="$2" fail="${3:-0}"
  (
    ac_stub_env "$STUB_BIN" "$tape_dir"
    export FORGE_API="https://forge.example/api/v1"
    # shellcheck disable=SC1090,SC1091
    source "$REPO_ROOT/lib/tape.sh"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/lib/catalog-forecast.sh"
    eval "$FN_SRC"
    if [ "$fail" = "1" ]; then
      export AC_STUB_FAIL=1
    fi
    emit_tape_proposal "$issue"
  ) 2>&1
}

# ── 1. Counts path: n=16, actual=63% -> p_success 0.63, method=counts ──────
export CATALOG_FILE="$CAT_ROOT/cal_counts.md"
TAPE1="$TMP_DIR/tape-counts"
rc=0
out="$(run_emit "$TAPE1" 1461)" || rc=$?
ac_assert_eq "$rc" "0" "counts pick must return 0 (got $rc): $out"
ac_assert_file "$TAPE1/tape.jsonl" "no tape record was appended to $TAPE1/tape.jsonl"
LINE="$(head -n 1 "$TAPE1/tape.jsonl" 2>/dev/null)"
[ -n "$LINE" ] || ac_fail "a record must be appended on the counts path"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .class == "backlog" and .decision == "approved" and .ref == "1461" and .context.open_prs == 3 and .context.size_class == "M" and .context.forecast_method == "counts" and (.context | has("area") | not) and (.parent | not) and (.caused_by | not) and .forecast.p_success == 0.63 and .forecast.est_cost == 0 and .forecast.est_dvision == 100' "$LINE" "counts path: forecast from catalog (p_success 0.63, est_dvision from mean duration_s), forecast_method=counts, no flat-prior override"
ID_FILE="/tmp/dev-proposal-id-${PROJECT_NAME}-1461"
[ -f "$ID_FILE" ] || ac_fail "id file $ID_FILE missing after a successful counts pick"
ac_assert_eq "$(cat "$ID_FILE")" "$(jq -r '.id' <<<"$LINE")" \
  "the project-scoped id file must contain exactly the recorded proposal id"

# ── 2. n too small (n=4 < MIN_N 5) -> flat prior, method=prior ──────────────
export CATALOG_FILE="$CAT_ROOT/cal_toosmall.md"
TAPE2="$TMP_DIR/tape-toosmall"
rc=0
out="$(run_emit "$TAPE2" 1462)" || rc=$?
ac_assert_eq "$rc" "0" "n-too-small pick must return 0 (got $rc): $out"
LINE="$(head -n 1 "$TAPE2/tape.jsonl" 2>/dev/null)"
[ -n "$LINE" ] || ac_fail "a record must be appended when n is below MIN_N"
ac_assert_jq \
  '.type == "proposal" and .context.forecast_method == "prior" and .forecast.p_success == 0.5' \
  "$LINE" \
  "a row with n below CATALOG_FORECAST_MIN_N must fall back to the flat prior"

# ── 3. actual unsampled (actual=-) -> flat prior, method=prior ──────────────
export CATALOG_FILE="$CAT_ROOT/cal_nosample.md"
TAPE3="$TMP_DIR/tape-nosample"
rc=0
out="$(run_emit "$TAPE3" 1463)" || rc=$?
ac_assert_eq "$rc" "0" "unsampled pick must return 0 (got $rc): $out"
LINE="$(head -n 1 "$TAPE3/tape.jsonl" 2>/dev/null)"
[ -n "$LINE" ] || ac_fail "a record must be appended when actual is -"
ac_assert_jq \
  '.type == "proposal" and .context.forecast_method == "prior" and .forecast.p_success == 0.5' \
  "$LINE" \
  "a row with unsampled actual (-) must fall back to the flat prior"

# ── 4. Catalog file absent -> pick still rc 0; prior ─────────────────────────
export CATALOG_FILE="$TMP_DIR/does-not-exist.md"
TAPE4="$TMP_DIR/tape-absent"
rc=0
out="$(run_emit "$TAPE4" 1464)" || rc=$?
ac_assert_eq "$rc" "0" "a missing catalog must not fail the pick (got $rc): $out"
LINE="$(head -n 1 "$TAPE4/tape.jsonl" 2>/dev/null)"
[ -n "$LINE" ] || ac_fail "a record must be appended when the catalog file is missing"
ac_assert_jq \
  '.type == "proposal" and .context.forecast_method == "prior" and .forecast.p_success == 0.5' \
  "$LINE" \
  "a missing catalog file must fall back to the flat prior and still append"

# ── 5. API failure -> context={}, forecast still written, method omitted ────
export CATALOG_FILE="$CAT_ROOT/cal_counts.md"
TAPE5="$TMP_DIR/tape-apifail"
rc=0
out="$(run_emit "$TAPE5" 1465 1)" || rc=$?
ac_assert_eq "$rc" "0" "API-failure pick must return 0 (got $rc): $out"
LINE="$(head -n 1 "$TAPE5/tape.jsonl" 2>/dev/null)"
[ -n "$LINE" ] || ac_fail "a record must be appended when the forge API is unreachable"
ac_assert_jq '.type == "proposal" and .class == "dev" and .context == {} and .forecast != null and .forecast.p_success == 0.5 and (.context | has("forecast_method") | not)' "$LINE" "API failure: context={}, forecast still written, forecast_method omitted (class dev)"

ac_pass
