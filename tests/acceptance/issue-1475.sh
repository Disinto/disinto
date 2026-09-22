#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1475.sh
#
# Issue #1475: fix(tape): formula_session_start does not read the tape or
# mint a proposal.
#
# Before: formula_session_start was the only organ that parsed
# tape.jsonl. When TAPE_PROPOSAL_ID was set and the id was missing it
# `jq`-ed the tape and minted a minimal tape_proposal with loop=formula,
# decision=auto — neither value is in the schema (loops are
# dev/test/production/research/repair; decision is
# approved/discussed/rejected). Start was reading the tape to act, and an
# unknown caller proposal became a fabricated proposal row instead of an
# orphan run.
#
# After: formula_session_start uses $TAPE_PROPOSAL_ID as the run's proposal
# id when set (or the run ULID when unset), and only appends the OPEN
# tape_run record. It never reads tape.jsonl and never calls tape_proposal.
# A missing proposal row is an orphan run, not a new proposal. The
# sanctioned tape reader is calibration, which reads to report.
#
# Acceptance (hermetic — no live services, no agents started, no network;
# formula_session_start/end are exercised in a throwaway subshell against
# fixture TAPE_DIR/PAYLOAD_DIR, exactly as tests/lib-formula-tape.bats does;
# no live-state mutation):
#   1. TAPE_PROPOSAL_ID=prop-42 and an empty tape → one open run, zero
#      proposal records, no loop=formula
#   2. formula_session_start does not read tape.jsonl: its body references
#      neither jq nor tape_proposal
#   3. lib/tape.sh header no longer says nothing reads the tape, and states
#      calibration reads to report / no organ reads to act
#   4. rc 0 when the tape directory is missing/unwritable (start + end)
#   5. bats tests/lib-formula-tape.bats passes (regression net for the full
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
ac_require_cmd awk

TARGET="$REPO_ROOT/lib/formula-session.sh"
ac_assert_file "$TARGET" "lib/formula-session.sh must exist"
TAPE_LIB="$REPO_ROOT/lib/tape.sh"
ac_assert_file "$TAPE_LIB" "lib/tape.sh must exist"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Driver: source lib/formula-session.sh in a throwaway subshell and drive
# formula_session_start + formula_session_end against caller-owned
# TAPE_DIR/PAYLOAD_DIR. $2 (optional) = TAPE_PROPOSAL_ID to export in the
# subshell (empty = unset, so the session keys on its own fresh ULID).
# $4 = exit code handed to formula_session_end. Prints the subshell's
# combined output (warnings); exit status is the driver's.
# ─────────────────────────────────────────────────────────────────────────────
prop_driver() {
  local proposal="${1:-}" rc="${2:-0}" tape_dir="$3" payload_dir="$4"
  local driver prop_line
  driver="$(mktemp "${TMP_DIR}/drv.XXXXXX.sh")"
  if [ -n "$proposal" ]; then
    prop_line="export TAPE_PROPOSAL_ID=$proposal"
  else
    prop_line="unset TAPE_PROPOSAL_ID"
  fi
  cat > "$driver" <<EOF
set -euo pipefail
# Stands in for lib/env.sh's log() (the real organ runners source env.sh
# first). The driver must not be a no-op or the missing-TAPE_DIR AC
# (which checks the logged warning) would see nothing.
log() { printf 'WARN %s\n' "\$*" >&2; }
unset TAPE_PROPOSAL_ID
export AGENT_HARNESS=claude LOG_AGENT=acceptance
source "$REPO_ROOT/lib/formula-session.sh"
export TAPE_DIR="$tape_dir" PAYLOAD_DIR="$payload_dir"
$prop_line
formula_session_start "acceptance-organ"
formula_session_end $rc
EOF
  bash "$driver" 2>&1
}

# ── AC 1: TAPE_PROPOSAL_ID=prop-42 + empty tape → one open run, zero
# proposal records, no loop=formula ──────────────────────────────────────────
T1="$TMP_DIR/tape-42"; P1="$TMP_DIR/payload-42"
rc=0
out="$(prop_driver "prop-42" 0 "$T1" "$P1")" || rc=$?
ac_assert_eq "$rc" "0" "prop-42 session must return 0 (got $rc): $out"
ac_assert_file "$T1/tape.jsonl" "prop-42 session must append a tape record: $T1/tape.jsonl"
ac_assert_eq "$(wc -l < "$T1/tape.jsonl")" "2" \
  "prop-42 session must append exactly 2 records (open + closing run), got $(wc -l < "$T1/tape.jsonl")"
jq -es '(map(select(.type == "proposal")) | length) == 0' "$T1/tape.jsonl" \
  >/dev/null 2>&1 \
  || ac_fail "prop-42 with empty tape must mint no proposal records (start must not read the tape or append a proposal)"
jq -es '
      (map(select(.type == "run")) | length) == 2
      and (.[0].proposal_id == "prop-42")
      and ((.[0] | has("ended")) | not)
      and ((.[0] | has("status")) | not)
      and (.[1].proposal_id == "prop-42")
      and (.[1].status == "completed")
    ' "$T1/tape.jsonl" >/dev/null 2>&1 \
  || ac_fail "prop-42 session must yield exactly one open run and one closing run keyed on prop-42"
jq -es '(map(select(.loop == "formula")) | length) == 0' "$T1/tape.jsonl" \
  >/dev/null 2>&1 \
  || ac_fail "no loop=formula record may be produced (out of schema)"

# ── AC 2: formula_session_start must not read the tape (no jq over
# tape.jsonl, no tape_proposal) — static check of the function body ────────
fn_body="$(awk '
    $0 == "formula_session_start() {" { infn = 1; next }
    infn && /^}$/ { exit }
    infn { print }
  ' "$TARGET")"
[ -n "$fn_body" ] || ac_fail "could not extract the formula_session_start body from $TARGET"
if grep -Eq 'jq|tape_proposal' <<<"$fn_body"; then
  ac_fail "formula_session_start must not read the tape or mint a proposal (body references jq/tape_proposal)"
fi
ac_log "AC 2 OK: formula_session_start body references neither jq nor tape_proposal"

# ── AC 3: lib/tape.sh header corrected — no 'nothing reads the tape',
# calibration reads to report, no organ reads to act ─────────────────────────
if grep -q 'nothing reads the tape' "$TAPE_LIB"; then
  ac_fail "lib/tape.sh still claims nothing reads the tape"
fi
grep -q 'calibration reads the tape to report' "$TAPE_LIB" \
  || ac_fail "lib/tape.sh must state calibration reads the tape to report"
grep -q 'no organ reads the tape to act' "$TAPE_LIB" \
  || ac_fail "lib/tape.sh must state no organ reads the tape to act"
ac_log "AC 3 OK: lib/tape.sh header corrected"

# ── AC 4: missing/unwritable tape directory → start + end still rc 0 ───────
touch "$TMP_DIR/blocker"
T4="$TMP_DIR/blocker/tape"; P4="$TMP_DIR/payload-42-missing"
rc=0
out="$(prop_driver "prop-42" 0 "$T4" "$P4")" || rc=$?
ac_assert_eq "$rc" "0" "missing tape directory must not fail the session (got $rc): $out"
case "$out" in
  *"WARNING"*) ;;
  *) ac_fail "missing tape directory must log a WARNING, got: $out" ;;
esac
[ ! -f "$T4/tape.jsonl" ] || ac_fail "no tape record may be written when the tape directory is missing/unwritable"

# ── AC 5: the bats regression net passes ────────────────────────────────────
bats "$REPO_ROOT/tests/lib-formula-tape.bats" 2>&1 \
  || ac_fail "bats tests/lib-formula-tape.bats failed"

ac_pass
