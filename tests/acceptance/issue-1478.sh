#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1478.sh
#
# Issue #1478: fix(dev): write run.attempts from the branch attempt count
#
# Before: every tape run record was hardcoded to attempts=1 (the literal 1 in
# lib/formula-session.sh). The design says retries keep their branch attempt
# count: dev-poll names each retry branch fix/issue-N-<k>, so k+1 (1-based) is
# the tape's attempts.
#
# After:
#   - dev-agent.sh exports TAPE_RUN_ATTEMPTS from the branch-count block:
#     a 1-based integer (ATTEMPT+1 when ATTEMPT is a non-negative integer;
#     1 for recovery mode or a failed ls-remote that left no count). It never
#     fails the pick. The export sits after the branch-count block and before
#     formula_session_start "dev".
#   - lib/formula-session.sh resolves _FORMULA_TAPE_ATTEMPTS as
#     ${TAPE_RUN_ATTEMPTS:-1}, falling back to 1 when the value is not an
#     integer >= 1. Both the open run and the closing run carry that value.
#     No git calls in formula-session.
#
# Acceptance (hermetic — no live services, no agents started, no network;
# formula_session_start/end are exercised in a throwaway subshell against
# fixture TAPE_DIR/PAYLOAD_DIR, exactly as issue-1474/1475 do; the
# dev-agent export block is extracted and run in a subshell with a sentinel
# PROJECT_NAME, exactly as issue-1440 does; the AC-3 static wiring check is
# the same line-order assertion issue-1440 uses for TAPE_PROPOSAL_ID):
#   1. TAPE_RUN_ATTEMPTS=3 → open and closing run attempts equal 3, rc 0
#   2. TAPE_RUN_ATTEMPTS unset, junk, 0, or negative → attempts 1, rc 0
#      (junk/0/negative are non-integers-or-below-1; a failed ls-remote is
#      the same as unset → 1)
#   3. dev-agent.sh exports TAPE_RUN_ATTEMPTS before formula_session_start
#      "dev" (and after the branch-count block that sets ATTEMPT)
#   4. extracted ATTEMPT export block: non-negative ATTEMPT → export ATTEMPT+1;
#      unset/empty/junk ATTEMPT → export 1, rc 0 (recovery mode / failed
#      ls-remote never fail the pick)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq awk
ac_require_cmd bats

DEV_AGENT="$REPO_ROOT/dev/dev-agent.sh"
FORMULA_SESSION="$REPO_ROOT/lib/formula-session.sh"
ac_assert_file "$DEV_AGENT" "dev/dev-agent.sh must exist"
ac_assert_file "$FORMULA_SESSION" "lib/formula-session.sh must exist"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Driver: source lib/formula-session.sh in a throwaway subshell and drive
# formula_session_start + formula_session_end against caller-owned
# TAPE_DIR/PAYLOAD_DIR. $1 = TAPE_RUN_ATTEMPTS value to export in the subshell
# (empty = unset). $2 = exit code handed to formula_session_end.
# ─────────────────────────────────────────────────────────────────────────────
driver() {
  local attempts="${1:-}" rc="${2:-0}" tape_dir="$3" payload_dir="$4"
  local driver_file prop_line
  driver_file="$(mktemp "${TMP_DIR}/drv.XXXXXX.sh")"
  if [ -n "$attempts" ]; then
    prop_line="export TAPE_RUN_ATTEMPTS=$attempts"
  else
    prop_line="unset TAPE_RUN_ATTEMPTS"
  fi
  cat > "$driver_file" <<EOF
set -euo pipefail
# Stands in for lib/env.sh's log() (the real organ runners source env.sh
# first). The driver must not be a no-op or the warning AC would see nothing.
log() { printf 'AC %s\n' "\$*" >&2; }
export AGENT_HARNESS=claude LOG_AGENT=acceptance
source "$REPO_ROOT/lib/formula-session.sh"
export TAPE_DIR="$tape_dir" PAYLOAD_DIR="$payload_dir"
$prop_line
formula_session_start "acceptance-organ"
formula_session_end $rc
EOF
  bash "$driver_file" 2>&1
}

# ── AC 1: TAPE_RUN_ATTEMPTS=3 → open and closing run attempts equal 3, rc 0 ─
T1="$TMP_DIR/tape-3"; P1="$TMP_DIR/payload-3"
rc=0
out="$(driver 3 0 "$T1" "$P1")" || rc=$?
ac_assert_eq "$rc" "0" \
  "TAPE_RUN_ATTEMPTS=3 session must return 0 (got $rc): $out"
ac_assert_file "$T1/tape.jsonl" "TAPE_RUN_ATTEMPTS=3 session must append a tape record: $T1/tape.jsonl"
ac_assert_eq "$(wc -l < "$T1/tape.jsonl")" "2" \
  "session must append exactly 2 records (open + closing run), got $(wc -l < "$T1/tape.jsonl")"
jq -es '
    (length == 2)
    and (.[0].type == "run")
    and ((.[0] | has("ended")) | not)
    and ((.[0] | has("status")) | not)
    and (.[0].attempts == 3)
    and (.[1].type == "run")
    and (.[1].proposal_id == .[0].proposal_id)
    and (.[1].attempts == 3)
    and (.[1].status == "completed")
' "$T1/tape.jsonl" >/dev/null 2>&1 \
  || ac_fail "with TAPE_RUN_ATTEMPTS=3 both the open and closing run must carry attempts=3: $out"
ac_log "AC 1 OK: TAPE_RUN_ATTEMPTS=3 → open and closing run attempts equal 3"

# ── AC 2: unset / junk / 0 / negative → attempts 1, rc 0 ────────────────────
for val in "" "junk" "0" "-3"; do
  T2="$TMP_DIR/tape-junk-${val:-empty}"
  P2="$TMP_DIR/payload-junk-${val:-empty}"
  rc=0
  out="$(driver "$val" 0 "$T2" "$P2")" || rc=$?
  ac_assert_eq "$rc" "0" "TAPE_RUN_ATTEMPTS='${val:-<unset>}' session must return 0 (got $rc): $out"
  ac_assert_file "$T2/tape.jsonl" "session must append a tape record for '${val:-<unset>}'"
  jq -es '
      (length == 2)
      and (.[0].attempts == 1)
      and (.[1].attempts == 1)
  ' "$T2/tape.jsonl" >/dev/null 2>&1 \
    || ac_fail "with TAPE_RUN_ATTEMPTS='${val:-<unset>}', both runs must fall back to attempts=1: $out"
done
ac_log "AC 2 OK: unset/junk/0/negative TAPE_RUN_ATTEMPTS → attempts 1, rc 0"

# ── AC 3: wiring — TAPE_RUN_ATTEMPTS export precedes formula_session_start
# "dev" in dev-agent.sh ────────────────────────────────────────────────────────
grep -qF 'export TAPE_RUN_ATTEMPTS' "$DEV_AGENT" \
  || ac_fail "dev-agent.sh must export TAPE_RUN_ATTEMPTS"
grep -qF '_formula_tape_attempts' "$FORMULA_SESSION" \
  || ac_fail "lib/formula-session.sh must resolve the attempt count (missing _formula_tape_attempts)"
grep -qF 'TAPE_RUN_ATTEMPTS' "$FORMULA_SESSION" \
  || ac_fail "lib/formula-session.sh must read TAPE_RUN_ATTEMPTS"
export_line="$(grep -nF 'export TAPE_RUN_ATTEMPTS' "$DEV_AGENT" | head -n 1 | cut -d: -f1)"
start_line="$(grep -nF 'formula_session_start "dev"' "$DEV_AGENT" | head -n 1 | cut -d: -f1)"
[ -n "$export_line" ] || ac_fail "could not find the TAPE_RUN_ATTEMPTS export line"
[ -n "$start_line" ] || ac_fail "could not find formula_session_start \"dev\""
[ "$export_line" -lt "$start_line" ] \
  || ac_fail "TAPE_RUN_ATTEMPTS export (line $export_line) must precede formula_session_start \"dev\" (line $start_line)"
ac_log "AC 3 OK: TAPE_RUN_ATTEMPTS export precedes formula_session_start \"dev\""

# ── AC 4: extract the TAPE_RUN_ATTEMPTS export block from dev-agent.sh and
# run it in a subshell with a sentinel PROJECT_NAME.
# ────────────────────────────────────────────────────────────────────────────
# Use grep to find the line number of the unique assignment, then awk to
# extract from that line to the next column-0 'fi'.
ASSIGN_LINE="$(grep -nF 'ATTEMPT:0:0}' "$DEV_AGENT" | head -n 1 | cut -d: -f1)"
[ -n "$ASSIGN_LINE" ] || ac_fail "could not find the TAPE_RUN_ATTEMPTS assignment line in dev-agent.sh"

BLOCK="$(awk -v start="$ASSIGN_LINE" '
  NR == start { grab = 1 }
  grab { print }
  grab && /^fi$/ { exit }
' "$DEV_AGENT")"
[ -n "$BLOCK" ] || ac_fail "could not extract the TAPE_RUN_ATTEMPTS export block from dev-agent.sh"

# run_export_block <attempts> — run the extracted block in a subshell with the
# given ATTEMPT value (empty = unset). The block itself does not reference
# $PROJECT_NAME, so no sentinel is needed.
run_export_block() {
  local attempt="$1"
  ATTEMPT="$attempt" bash -c '
    set -euo pipefail
    log() { :; }
    eval "$(cat)"
    printf "TAPE_RUN_ATTEMPTS=%s\n" "${TAPE_RUN_ATTEMPTS:-<unset>}"
  ' <<< "$BLOCK" 2>&1
}

out="$(run_export_block 2)"
case "$out" in
  *"TAPE_RUN_ATTEMPTS=3"*) ;;
  *) ac_fail "ATTEMPT=2 must export TAPE_RUN_ATTEMPTS=3, got: $out" ;;
esac

out="$(run_export_block "")"
case "$out" in
  *"TAPE_RUN_ATTEMPTS=1"*) ;;
  *) ac_fail "unset ATTEMPT must export TAPE_RUN_ATTEMPTS=1, got: $out" ;;
esac

out="$(run_export_block junk)"
case "$out" in
  *"TAPE_RUN_ATTEMPTS=1"*) ;;
  *) ac_fail "non-integer ATTEMPT must export TAPE_RUN_ATTEMPTS=1, got: $out" ;;
esac

ac_log "AC 4 OK: export block maps non-negative integer ATTEMPT to ATTEMPT+1,
       else 1 (never fails the pick)"

# ── AC 5: the bats regression net passes ────────────────────────────────────
bats "$REPO_ROOT/tests/lib-formula-tape.bats" 2>&1 \
  || ac_fail "bats tests/lib-formula-tape.bats failed"
ac_log "AC 5 OK: tests/lib-formula-tape.bats passes"

ac_pass
