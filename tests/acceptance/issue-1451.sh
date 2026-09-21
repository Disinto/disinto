#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1451.sh
#
# Issue #1451: emit_tape_proposal() in dev/dev-poll.sh passed an empty forecast
# to tape_proposal, so the dev tape carried proposals with no `forecast` field
# (29 proposals, 0 forecast) — Stage 1's only read (#1453) was hollow.
#
# Fix: on every *fresh* pick (not the #1441 re-pick early return), emit
# `{"p_success":0.5,"est_cost":0,"est_dvision":0}` as the forecast argument
# (the same flat prior the planner's emit_planner_proposal() writes); when the
# context is a non-empty object, also record context.forecast_method="prior"
# so the calibration reader can tell a prior apart from measured data. When
# the context degrades to {} (the existing API-failure path), the forecast is
# still written to the proposal, but forecast_method is omitted.
#
# Acceptance (read-only — no live services, no agents started, no pick
# triggered; the emitter is exercised in-process with a stub curl, the same
# extract-and-stub approach as issue-1398/1409/1441/1443):
#   1. a fresh pick appends a proposal whose forecast is the flat prior
#      {"p_success":0.5,"est_cost":0,"est_dvision":0} and whose (non-empty)
#      context records forecast_method="prior"; the project-scoped id file
#      contains exactly that record's id
#   2. a forge API failure degrades to class="dev" / context={} but still
#      appends the record with the forecast (rc 0), forecast_method omitted
#   3. re-pick (#1441) still returns 0 without minting a second proposal
#
# The stub curl (ac_write_curl_stub, tests/lib/acceptance-helpers.sh) stands
# in for the forge; AC_STUB_FAIL=1 makes it fail like an unreachable API.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

TARGET="$REPO_ROOT/dev/dev-poll.sh"

# ── 1. Wiring: dev-poll sources the tape lib and calls the emitter ─────────
# Shared wiring checks (lib helper) — the extracted source is what the
# assertions below run against.
FN_SRC="$(ac_tape_emitter_wiring "$TARGET" emit_tape_proposal \
  'emit_tape_proposal "$READY_ISSUE"')"
[ -n "$FN_SRC" ] || ac_fail "could not extract emit_tape_proposal() from dev-poll.sh"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-1451"   # sentinel — can never clobber a live id file
trap 'rm -rf "$TMP_DIR" \
  /tmp/dev-proposal-id-acceptance-1451-1451 \
  /tmp/dev-proposal-id-acceptance-1451-9998' EXIT

# ── Stub curl: hermetic forge stand-in (no network, no live services) ───────
STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
ac_write_curl_stub "$STUB_BIN"

# The extracted emitter logs through log(); the subshells inherit this
# stand-in so its lines land in the runner's captured output.
log() { echo "poll: $*"; }



# ── 2. Fresh pick: flat-prior forecast + context.forecast_method="prior" ────
# The shared stub (backlog+priority, no size label) yields size_class=M and
# open_prs=3, no backend, so the context is the non-empty object that
# carries forecast_method. area/parent/caused_by must not appear.
TAPE1="$TMP_DIR/tape-happy"
rc=0
out="$(ac_run_tape_emit "$STUB_BIN" "$TAPE1" "$FN_SRC" "0" emit_tape_proposal 1451)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_proposal must return 0 on a fresh pick (got $rc): $out"
ac_assert_file "$TAPE1/tape.jsonl" "no tape record was appended to $TAPE1/tape.jsonl"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "1" \
  "a fresh pick must append exactly one tape line"
LINE="$(head -n 1 "$TAPE1/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1451"
  and .class == "backlog" and .context.open_prs == 3 and .context.size_class == "M"
  and .context.forecast_method == "prior" and (.context | has("area") | not)
  and (.parent | not) and (.caused_by | not)
  and .forecast.p_success == 0.5 and .forecast.est_cost == 0 and .forecast.est_dvision == 0' \
  "$LINE" \
  "fresh pick must append an approved dev-loop proposal whose forecast is the flat prior and whose non-empty context records forecast_method prior"
ID_FILE="/tmp/dev-proposal-id-${PROJECT_NAME}-1451"
[ -f "$ID_FILE" ] || ac_fail "id file $ID_FILE missing after a successful pick"
ac_assert_eq "$(cat "$ID_FILE")" "$(jq -r '.id' <<<"$LINE")" \
  "the project-scoped id file must contain exactly the recorded proposal id"

# ── 3. Re-pick (#1441): second call on the same issue appends nothing ──────
# Same issue + same tape -> the id file exists and is non-empty, so the
# guard reuses the id, logs it, and returns 0 before minting a second uuid
# or appending a second proposal.
rc=0
out2="$(ac_run_tape_emit "$STUB_BIN" "$TAPE1" "$FN_SRC" "0" emit_tape_proposal 1451)" || rc=$?
ac_assert_repick "$rc" "$out2"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "1" \
  "two calls on one issue must leave exactly one tape line (re-pick guard)"

# ── 4. Forge API failure: context={} + forecast present, rc 0 ───────────────
TAPE2="$TMP_DIR/tape-apifail"
rc=0
out3="$(ac_run_tape_emit "$STUB_BIN" "$TAPE2" "$FN_SRC" "1" emit_tape_proposal 9998)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_proposal must return 0 when the forge API fails (got $rc): $out3"
LINE="$(head -n 1 "$TAPE2/tape.jsonl" 2>/dev/null || true)"
[ -n "$LINE" ] || ac_fail "a record must still be appended when the forge API is unreachable"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved"
  and .class == "dev" and .context == {} and .ref == "9998"
  and (.context | has("forecast_method") | not)
  and .forecast.p_success == 0.5 and .forecast.est_cost == 0 and .forecast.est_dvision == 0' \
  "$LINE" \
  "API failure must degrade to class=dev and context={} (forecast_method omitted) while still appending the forecast"

ac_pass
