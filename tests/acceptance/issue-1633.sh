#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1633.sh
#
# Issue #1633: feat(lib): organ sessions without a proposal write no tape run.
#
# Before: formula_session_start (lib/formula-session.sh) keyed the tape run on
# $TAPE_PROPOSAL_ID when set, else on the run's own fresh ULID. Organ sessions
# that serve no proposal (gardener, supervisor, dev runs predating the pick
# step) thus wrote runs that pair with nothing — orphan runs making up about
# half of the tape.
#
# After: runs exist only under a proposal. formula_session_start appends no
# tape run and leaves _FORMULA_TAPE_ACTIVE at 0 when TAPE_PROPOSAL_ID is
# empty (formula_session_end is already a no-op in that case); the cost is
# still recorded in ${DISINTO_LOG_DIR}/metrics/agent-runs.jsonl by
# lib/agent-metrics.sh (#1101). With a proposal id, the open + closing run
# pair is written as before.
#
# Acceptance (hermetic — no live services, no agents started, no network;
# formula_session_start/end are exercised in a throwaway subshell against
# fixture TAPE_DIR/PAYLOAD_DIR, exactly as tests/lib-formula-tape.bats does;
# no live-state mutation):
#   1. TAPE_PROPOSAL_ID unset → start then end appends nothing to the tape,
#      rc 0, session silent
#   2. TAPE_PROPOSAL_ID=p1 → start then end appends exactly one open and one
#      closing run for p1 (open: ended/status omitted; closing: status
#      completed), no proposal minted
#   3. The "else the run ULID" fallback is gone: the lib header states runs
#      exist only under a proposal, and formula_session_start's body keeps
#      no run-ULID proposal assignment (and guards TAPE_PROPOSAL_ID before
#      the tape_run call)
#   4. With a proposal, a missing/unwritable tape directory → start + end
#      still rc 0 with the WARNING logged
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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Driver: source lib/formula-session.sh in a throwaway subshell and drive
# formula_session_start + formula_session_end against caller-owned
# TAPE_DIR/PAYLOAD_DIR. $1 (optional) = TAPE_PROPOSAL_ID to export in the
# subshell (empty = unset, so the session has no proposal to key the run on).
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
# first). Must not be a no-op — the unwritable-TAPE_DIR AC checks the
# warning a tape append would log.
log() { printf 'AC %s\n' "\$*" >&2; }
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

# ── AC 1: TAPE_PROPOSAL_ID unset → start then end appends nothing ──────────
T1="$TMP_DIR/tape-noprop"; P1="$TMP_DIR/payload-noprop"
rc=0
out="$(prop_driver "" 0 "$T1" "$P1")" || rc=$?
ac_assert_eq "$rc" "0" "no-proposal session must return 0 (got $rc): $out"
[ -n "$out" ] && ac_fail "no-proposal session must stay silent (got: $out)"
[ -f "$T1/tape.jsonl" ] && ac_fail "no-proposal session must append no tape record (found $T1/tape.jsonl)"
ac_log "AC 1 OK: no TAPE_PROPOSAL_ID → start+end append nothing to the tape"

# ── AC 2: TAPE_PROPOSAL_ID=p1 → exactly one open and one closing run ───────
T2="$TMP_DIR/tape-p1"; P2="$TMP_DIR/payload-p1"
rc=0
out="$(prop_driver "p1" 0 "$T2" "$P2")" || rc=$?
ac_assert_eq "$rc" "0" "p1 session must return 0 (got $rc): $out"
ac_assert_file "$T2/tape.jsonl" "p1 session must append a tape record: $T2/tape.jsonl"
ac_assert_eq "$(wc -l < "$T2/tape.jsonl")" "2" \
  "p1 session must append exactly 2 records (open + closing run), got $(wc -l < "$T2/tape.jsonl")"
jq -es '(map(select(.type == "proposal")) | length) == 0' "$T2/tape.jsonl" \
  >/dev/null 2>&1 \
  || ac_fail "p1 session must mint no proposal record (start must not read the tape or append a proposal)"
jq -es '
      (length == 2)
      and (.[0].type == "run")
      and (.[0].proposal_id == "p1")
      and ((.[0] | has("ended")) | not)
      and ((.[0] | has("status")) | not)
      and (.[0].organ == "acceptance-organ")
      and (.[0].attempts == 1)
      and (.[0].cost == {})
      and (.[1].type == "run")
      and (.[1].proposal_id == "p1")
      and (.[1].started == .[0].started)
      and (.[1].attempts == 1)
      and ((.[1].cost.duration_s | type) == "number")
      and (.[1].status == "completed")
    ' "$T2/tape.jsonl" >/dev/null 2>&1 \
  || ac_fail "p1 session must yield exactly one open run and one closing run keyed on p1 (status completed)"
ac_log "AC 2 OK: TAPE_PROPOSAL_ID=p1 → open + closing run for p1"

# ── AC 3: the "else the run ULID" fallback is gone from the lib headers
# ──────────────────────────────────────────────────────────────────────────────
if grep -q 'else the run ULID' "$TARGET"; then
  ac_fail "lib/formula-session.sh still documents the 'else the run ULID' proposal fallback"
fi
grep -q 'runs exist only under a proposal' "$TARGET" \
  || ac_fail "lib/formula-session.sh must state that runs exist only under a proposal"
fn_body="$(awk '
    $0 == "formula_session_start() {" { infn = 1; next }
    infn && /^}$/ { exit }
    infn { print }
  ' "$TARGET")"
[ -n "$fn_body" ] || ac_fail "could not extract the formula_session_start body from $TARGET"
if [[ "$fn_body" == *'\${TAPE_PROPOSAL_ID:-$run_id}'* ]]; then
  ac_fail "formula_session_start must keep no run-ULID proposal assignment (still references \${TAPE_PROPOSAL_ID:-\$run_id})"
fi
guard_line="$(grep -n 'TAPE_PROPOSAL_ID' <<<"$fn_body" | head -1 | cut -d: -f1)"
tape_line="$(grep -n 'tape_run' <<<"$fn_body" | head -1 | cut -d: -f1)"
[ -n "$guard_line" ] && [ -n "$tape_line" ] \
  || ac_fail "formula_session_start must check TAPE_PROPOSAL_ID and call tape_run"
[ "$guard_line" -lt "$tape_line" ] \
  || ac_fail "the TAPE_PROPOSAL_ID guard must precede the tape_run call in formula_session_start"
ac_log "AC 3 OK: run-ULID fallback gone from lib/formula-session.sh; guard precedes tape_run"

# ── AC 4: with a proposal, missing/unwritable tape directory → start + end
# still rc 0, WARNING logged ──────────────────────────────────────────────────
touch "$TMP_DIR/blocker"
T4="$TMP_DIR/blocker/tape"; P4="$TMP_DIR/payload-p1-blocker"
rc=0
out="$(prop_driver "p1" 1 "$T4" "$P4")" || rc=$?
ac_assert_eq "$rc" "0" "unwritable tape directory must not fail the session (got $rc): $out"
case "$out" in
  *"WARNING"*) ;;
  *) ac_fail "unwritable tape directory must log a WARNING, got: $out" ;;
esac
[ ! -f "$T4/tape.jsonl" ] || ac_fail "no tape record may be written when the tape directory is missing/unwritable"
ac_log "AC 4 OK: unwritable tape directory with a proposal → rc 0, WARNING logged"

# ── AC 5: the bats regression net passes ────────────────────────────────────
bats "$REPO_ROOT/tests/lib-formula-tape.bats" 2>&1 \
  || ac_fail "bats tests/lib-formula-tape.bats failed"
ac_log "AC 5 OK: tests/lib-formula-tape.bats passes"

ac_pass
