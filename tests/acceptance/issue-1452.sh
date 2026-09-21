#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1452.sh
#
# Issue #1452: the dev outcome (#1399) recorded only review_rounds, so
# calibration's mean duration_s was `-` for the dev loop even though
# formula-session outcomes carry the field. The fix adds the wall-clock
# pick→terminal span to the dev outcome:
#
#   1. a fresh pick (emit_tape_proposal) writes the pick's epoch
#      (`date -u +%s`) to the sibling /tmp/dev-proposal-started-
#      ${PROJECT_NAME}-<issue>, on the fresh-pick path only — the #1441
#      re-pick early return leaves it alone, so the duration spans the
#      issue's whole life, not just one attempt
#   2. emit_tape_outcome reads that file when present and it parses as an
#      integer epoch, appending numbers.duration_s (now - start, integer
#      seconds, clamped ≥ 0) alongside review_rounds; a missing or junk
#      file → duration_s omitted (never 0)
#
# Acceptance (read-only — no live services, no agents started, no pick
# triggered; the emitters are exercised in-process with a stub curl, the
# same extract-and-stub approach as issue-1398/1399/1441/1451):
#   1. a fresh pick writes the sibling started epoch file next to the id
#      file
#   2. emit_tape_outcome with a valid started file appends
#      numbers.duration_s as a number alongside review_rounds
#   3. a missing (or junk) started file → numbers is exactly
#      {"review_rounds":<n>}, rc 0
#   4. a future-started epoch → duration_s clamps to 0 (never negative)
#   5. re-pick (#1441) does not reset the started file
#
# The stub curl (ac_write_curl_stub, tests/lib/acceptance-helpers.sh) stands
# in for the forge; AC_STUB_FAIL=1 makes it fail like an unreachable API.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk jq date

TARGET="$REPO_ROOT/dev/dev-poll.sh"

# ── 1. Wiring: dev-poll sources the tape lib and calls both emitters ────────
# Shared wiring checks (lib helper) — the extracted source is what the
# assertions below run against.
FN_PROP="$(ac_tape_emitter_wiring "$TARGET" emit_tape_proposal \
  'emit_tape_proposal "$READY_ISSUE"')"
[ -n "$FN_PROP" ] || ac_fail "could not extract emit_tape_proposal() from dev-poll.sh"

FN_OUT="$(ac_tape_emitter_wiring "$TARGET" emit_tape_outcome \
  'emit_tape_outcome "$ISSUE_NUM" "$HAS_PR" 1 1')"
[ -n "$FN_OUT" ] || ac_fail "could not extract emit_tape_outcome() from dev-poll.sh"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-1452"   # sentinel — can never clobber a live /tmp file
trap 'rm -rf "$TMP_DIR" \
  /tmp/dev-proposal-id-acceptance-1452-* \
  /tmp/dev-proposal-started-acceptance-1452-*' EXIT

# ── Stub curl: hermetic forge stand-in (no network, no live services) ───────
STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
ac_write_curl_stub "$STUB_BIN"

# The extracted emitters log through log(); the subshells inherit this
# stand-in so those lines land in the runner's captured output.
log() { echo "poll: $*"; }

# ── 2. Fresh pick: the started epoch file is written next to the id file ────
# and holds an integer unix epoch; the id file holds the recorded proposal id.
TAPE_PROP="$TMP_DIR/tape-prop"
rc=0
out="$(ac_run_tape_emit "$STUB_BIN" "$TAPE_PROP" "$FN_PROP" "0" emit_tape_proposal 1452)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_proposal must return 0 on a fresh pick (got $rc): $out"
ac_assert_eq "$(wc -l < "$TAPE_PROP/tape.jsonl")" "1" \
  "a fresh pick must append exactly one tape line"
PROP_ID="$(jq -r '.id' <(head -n 1 "$TAPE_PROP/tape.jsonl"))"
ID_FILE="/tmp/dev-proposal-id-${PROJECT_NAME}-1452"
[ -f "$ID_FILE" ] || ac_fail "id file $ID_FILE missing after a successful pick"
ac_assert_eq "$(cat "$ID_FILE")" "$PROP_ID" \
  "the project-scoped id file must contain exactly the recorded proposal id"
STARTED_FILE="/tmp/dev-proposal-started-${PROJECT_NAME}-1452"
[ -f "$STARTED_FILE" ] || ac_fail "started file $STARTED_FILE missing after a successful pick"
STARTED_EPOCH="$(cat "$STARTED_FILE")"
[[ "$STARTED_EPOCH" =~ ^[0-9]+$ ]] \
  || ac_fail "the started file must hold an integer unix epoch, got: $STARTED_EPOCH"

# ── 3. Valid started file: outcome carries duration_s (now − start, ≥ 0) ────
NOW_BEFORE="$(date -u +%s)"
rc=0
out2="$(ac_run_tape_emit "$STUB_BIN" "$TAPE_PROP" "$FN_OUT" "0" emit_tape_outcome 1452 42 1 1)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_outcome must return 0 on success (got $rc): $out2"
ac_assert_eq "$(wc -l < "$TAPE_PROP/tape.jsonl")" "2" \
  "merging a dev PR must append exactly one outcome line to the proposal line"
LINE="$(sed -n 2p "$TAPE_PROP/tape.jsonl")"
# numbers must be exactly {review_rounds, duration_s} — duration_s a number
# (integer seconds by construction), non-negative, review_rounds from the
# stub (2 REQUEST_CHANGES).
ac_assert_jq '.type == "outcome" and .proposal_id == "'"$PROP_ID"'" and
  .bits == {"merged":1,"ci_green":1} and .numbers.review_rounds == 2 and
  (.numbers.duration_s | type) == "number" and
  .numbers.duration_s >= 0 and
  (.numbers | keys) == ["duration_s","review_rounds"]' \
  "$LINE" \
  "a valid started file must add numbers.duration_s as a number alongside review_rounds"

# duration_s must be the wall-clock span pick→outcome: now_at_outcome −
# STARTED_EPOCH for some now_at_outcome between NOW_BEFORE and NOW_AFTER
# (the subshell runs between the two stamps).
NOW_AFTER="$(date -u +%s)"
D="$(jq -r '.numbers.duration_s' <<<"$LINE")"
lo=$(( NOW_BEFORE - STARTED_EPOCH ))
[ $lo -lt 0 ] && lo=0
hi=$(( NOW_AFTER - STARTED_EPOCH ))
if [[ $D -lt $lo || $D -gt $hi ]]; then
  ac_fail "duration_s $D should equal now − started (allowed range [$lo, $hi])"
fi

# ── 4. Missing started file: numbers = {review_rounds} only, rc 0, record ────
# ── still appended ────────────────────────────────────────────────────────────
TAPE_NOSTART="$TMP_DIR/tape-no-start"
printf '%s' "pid-no-start-9998" > "/tmp/dev-proposal-id-${PROJECT_NAME}-9998"
rc=0
out3="$(ac_run_tape_emit "$STUB_BIN" "$TAPE_NOSTART" "$FN_OUT" "0" emit_tape_outcome 9998 43 1 1)" || rc=$?
ac_assert_eq "$rc" "0" "a missing started file must not fail the terminal-state handling (got $rc): $out3"
ac_assert_eq "$(wc -l < "$TAPE_NOSTART/tape.jsonl")" "1" "a record must still be appended without a started file"
LINE="$(head -n 1 "$TAPE_NOSTART/tape.jsonl")"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-no-start-9998" and
  .bits == {"merged":1,"ci_green":1} and
  .numbers == {"review_rounds":2}' \
  "$LINE" \
  "a missing started file must leave numbers = {review_rounds} only (duration omitted, never 0)"

# ── 5. Junk started file (non-integer) → same: omitted, rc 0 ────────────────
TAPE_JUNK="$TMP_DIR/tape-junk-start"
printf '%s' "pid-junk-9999" > "/tmp/dev-proposal-id-${PROJECT_NAME}-9999"
printf '%s' "not-an-epoch" > "/tmp/dev-proposal-started-${PROJECT_NAME}-9999"
rc=0
out4="$(ac_run_tape_emit "$STUB_BIN" "$TAPE_JUNK" "$FN_OUT" "0" emit_tape_outcome 9999 44 1 1)" || rc=$?
ac_assert_eq "$rc" "0" "a junk started file must not fail the terminal-state handling (got $rc): $out4"
LINE="$(head -n 1 "$TAPE_JUNK/tape.jsonl")"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-junk-9999" and
  .bits == {"merged":1,"ci_green":1} and
  .numbers == {"review_rounds":2}' \
  "$LINE" \
  "a non-integer started file must leave numbers = {review_rounds} only"

# ── 6. Future-started epoch (clock skew): duration clamps to 0 ──────────────
TAPE_FUTURE="$TMP_DIR/tape-future-start"
FUTURE=$(( $(date -u +%s) + 3600 ))
printf '%s' "pid-future-9996" > "/tmp/dev-proposal-id-${PROJECT_NAME}-9996"
printf '%s' "$FUTURE" > "/tmp/dev-proposal-started-${PROJECT_NAME}-9996"
rc=0
out5="$(ac_run_tape_emit "$STUB_BIN" "$TAPE_FUTURE" "$FN_OUT" "0" emit_tape_outcome 9996 45 1 1)" || rc=$?
ac_assert_eq "$rc" "0" "a future started epoch must not fail the terminal-state handling (got $rc): $out5"
LINE="$(head -n 1 "$TAPE_FUTURE/tape.jsonl")"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-future-9996" and
  .bits == {"merged":1,"ci_green":1} and
  .numbers == {"review_rounds":2,"duration_s":0}' \
  "$LINE" \
  "a future started epoch must clamp duration_s to 0 (never negative)"

# ── 7. Re-pick (#1441): the started epoch is not reset ──────────────────────
TAPE_REPICK="$TMP_DIR/tape-repick"
rc=0
out6="$(ac_run_tape_emit "$STUB_BIN" "$TAPE_REPICK" "$FN_PROP" "0" emit_tape_proposal 9997)" || rc=$?
ac_assert_eq "$rc" "0" "first pick must return 0 (got $rc): $out6"
STARTED_FILE_REPICK="/tmp/dev-proposal-started-${PROJECT_NAME}-9997"
FIRST_STARTED="$(cat "$STARTED_FILE_REPICK")"
rc=0
out7="$(ac_run_tape_emit "$STUB_BIN" "$TAPE_REPICK" "$FN_PROP" "0" emit_tape_proposal 9997)" || rc=$?
ac_assert_repick "$rc" "$out7"
ac_assert_eq "$(wc -l < "$TAPE_REPICK/tape.jsonl")" "1" \
  "two calls on one issue must leave exactly one tape line (re-pick guard)"
SECOND_STARTED="$(cat "$STARTED_FILE_REPICK")"
ac_assert_eq "$SECOND_STARTED" "$FIRST_STARTED" \
  "re-pick must not reset the started epoch (got $SECOND_STARTED, want $FIRST_STARTED)"

ac_pass
