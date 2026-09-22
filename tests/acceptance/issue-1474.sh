#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1474.sh
#
# Issue #1474: fix(tape): formula session closes the run and does not write an
# outcome.
#
# Before: formula_session_end appended a tape_outcome (bits.exit_ok, numbers
# with duration_s + tokens, transcript payload) in addition to the closing
# tape_run. The run record already carries `status`; an exit_ok bit on a
# separate outcome was run status stuffed into the competence channel, and
# calibration read an unfinished dev pick as a failed merge.
#
# After: formula_session_end no longer calls tape_outcome. It still closes the
# run (a second tape_run append: ended + status completed|failed, attempts
# unchanged) and puts the session cost on that closing run's `cost` object:
# duration_s (integer seconds, >= 0), tokens_in/tokens_out when the
# transcript's final usage row carries them, and transcript = the tape_payload
# hash when the store succeeds (key omitted on failure).
#
# Acceptance (hermetic — no live services, no agents started, no network;
# formula_session_start/end are exercised in a throwaway subshell against
# fixture TAPE_DIR/PAYLOAD_DIR, exactly as tests/lib-formula-tape.bats does;
# no live-state mutation):
#   1. formula_session_end 0 appends a closing run with status=completed and
#      cost.duration_s a number (>= 0)
#   2. no type=outcome line is appended for the formula session
#   3. exit non-zero → closing run status=failed, still no outcome
#   4. with a transcript carrying usage, cost.tokens_in/tokens_out are set
#      and cost.transcript equals the tape_payload hash (payload copied)
#   5. an unwritable TAPE_DIR → formula_session_end still returns 0 (warning
#      logged), so the organ never fails on a tape failure
#   6. bats tests/lib-formula-tape.bats passes (regression net for the full
#      cost-shape + edge cases)
#
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>). Uses tests/lib/acceptance-helpers.sh helpers.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq
ac_require_cmd bats

TARGET="$REPO_ROOT/lib/formula-session.sh"
ac_assert_file "$TARGET" "lib/formula-session.sh must exist"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Driver: source lib/formula-session.sh in a throwaway subshell and drive
# formula_session_start + formula_session_end against caller-owned
# TAPE_DIR/PAYLOAD_DIR. TAPE_PROPOSAL_ID is unset so the session keys on its
# own fresh ULID (the canonical open-run + closing-run pair, exactly two
# records — a minimal proposal is only appended when a caller supplies its
# own TAPE_PROPOSAL_ID, which the default organ runners do not). $1 = exit
# code handed to formula_session_end, $4 = optional transcript file (empty →
# harness diagnostics default, which we never populate here).
# Prints the subshell's combined output (warnings); exit status is the driver's.
# ─────────────────────────────────────────────────────────────────────────────
formula_driver() {
  local rc="${1:-0}" tape_dir="${2:-}" payload_dir="${3:-}" transcript="${4:-}"
  local driver
  driver="$(mktemp "${TMP_DIR}/drv.XXXXXX.sh")"
  cat > "$driver" <<EOF
set -euo pipefail
# Stands in for lib/env.sh's log() (the real organ runners source env.sh
# first). The driver must not be a no-op or the unwritable-TAPE_DIR AC
# (which checks the logged warning) would see nothing.
log() { printf 'WARN %s\n' "\$*" >&2; }
unset TAPE_PROPOSAL_ID
export AGENT_HARNESS=claude LOG_AGENT=acceptance
source "$REPO_ROOT/lib/formula-session.sh"
export TAPE_DIR="$tape_dir" PAYLOAD_DIR="$payload_dir"
formula_session_start "acceptance-organ"
formula_session_end $rc "$transcript"
EOF
  bash "$driver" 2>&1
}

# ── AC 1 + 2: exit 0 → closing run status=completed, cost.duration_s number;
# no outcome ────────────────────────────────────────────────────────────────────
T1="$TMP_DIR/tape-0"; P1="$TMP_DIR/payload-0"
rc=0
out="$(formula_driver 0 "$T1" "$P1")" || rc=$?
ac_assert_eq "$rc" "0" "exit-0 session must return 0 (got $rc): $out"
ac_assert_file "$T1/tape.jsonl" "exit-0 session must append a tape record: $T1/tape.jsonl"
jq -es 'length == 2' "$T1/tape.jsonl" >/dev/null 2>&1 \
  || ac_fail "exit-0 session must append exactly 2 records (open + closing run), got $(wc -l < "$T1/tape.jsonl")"
jq -es '.[0].type == "run" and .[0].status == null and .[0].ended == null' "$T1/tape.jsonl" \
  >/dev/null 2>&1 \
  || ac_fail "first record must be the open run (status/ended omitted)"
jq -es '.[1].type == "run" and .[1].status == "completed" and .[1].ended' "$T1/tape.jsonl" \
  >/dev/null 2>&1 \
  || ac_fail "closing run (last record) must have status=completed and ended set"
jq -es '.[1].cost.duration_s | type == "number"' "$T1/tape.jsonl" \
  >/dev/null 2>&1 || ac_fail "closing run cost.duration_s must be a number"
jq -es '.[1].cost.duration_s >= 0' "$T1/tape.jsonl" \
  >/dev/null 2>&1 || ac_fail "closing run cost.duration_s must be >= 0"
jq -es '(map(select(.type == "outcome")) | length) == 0' "$T1/tape.jsonl" \
  >/dev/null 2>&1 \
  || ac_fail "exit-0 session must append no type=outcome record"

# ── AC 3: exit non-zero → status=failed, still no outcome ────────────────────
T2="$TMP_DIR/tape-1"; P2="$TMP_DIR/payload-1"
rc=0
out="$(formula_driver 1 "$T2" "$P2")" || rc=$?
ac_assert_eq "$rc" "0" "exit-non-zero session must still return 0 (got $rc): $out"
jq -es 'length == 2' "$T2/tape.jsonl" \
  >/dev/null 2>&1 \
  || ac_fail "exit-1 session must append exactly 2 records (open + closing run)"
jq -es '.[1].status == "failed" and .[1].ended' "$T2/tape.jsonl" \
  >/dev/null 2>&1 \
  || ac_fail "exit-1 closing run (last record) must have status=failed and ended set"
jq -es '(map(select(.type == "outcome")) | length) == 0' "$T2/tape.jsonl" \
  >/dev/null 2>&1 \
  || ac_fail "exit-1 session must append no type=outcome record"

# ── AC 4: transcript with usage → cost tokens + transcript payload hash ─────
T3="$TMP_DIR/tape-cost"; P3="$TMP_DIR/payload-cost"
t3="$TMP_DIR/transcript.json"
printf '%s\n' \
  '{"type":"assistant","message":{"id":"m1"}}' \
  '{"type":"result","subtype":"success","usage":{"input_tokens":123,"output_tokens":45}}' \
  > "$t3"
h3="$(sha256sum "$t3" | cut -d' ' -f1)"
rc=0
out="$(formula_driver 0 "$T3" "$P3" "$t3")" || rc=$?
ac_assert_eq "$rc" "0" "transcript session must return 0 (got $rc): $out"
jq -es '.[1].cost.tokens_in == 123 and .[1].cost.tokens_out == 45' "$T3/tape.jsonl" \
  >/dev/null 2>&1 \
  || ac_fail "cost must carry tokens_in=123 and tokens_out=45 from the transcript"
jq -es --arg h "$h3" '.[1].cost.transcript == $h' "$T3/tape.jsonl" \
  >/dev/null 2>&1 \
  || ac_fail "cost.transcript must equal the transcript tape_payload hash ($h3)"
[ -f "$P3/$h3" ] || ac_fail "transcript payload must be stored at $P3/$h3"
diff -q "$t3" "$P3/$h3" || ac_fail "stored transcript payload must match the source transcript"

# ── AC 5: unwritable TAPE_DIR → still return 0, warning logged ───────────────
touch "$TMP_DIR/blocker"
T5="$TMP_DIR/blocker/tape"; P5="$TMP_DIR/payload-5"
rc=0
out="$(formula_driver 0 "$T5" "$P5")" || rc=$?
ac_assert_eq "$rc" "0" "unwritable TAPE_DIR must not fail the session (got $rc): $out"
case "$out" in
  *"WARNING"*) ;;
  *) ac_fail "unwritable TAPE_DIR must log a WARNING, got: $out" ;;
esac
[ ! -f "$T5/tape.jsonl" ] || ac_fail "no tape record may be written when TAPE_DIR is unwritable"

# ── AC 6: the bats regression net passes ─────────────────────────────────────
bats "$REPO_ROOT/tests/lib-formula-tape.bats" 2>&1 \
  || ac_fail "bats tests/lib-formula-tape.bats failed"

ac_pass
