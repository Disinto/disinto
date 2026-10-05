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
#   - dev-agent.sh exports TAPE_RUN_ATTEMPTS as DEV_FAILED_ATTEMPTS + 1 (since
#     #1646: the picked proposal's failed tape outcomes plus one), a 1-based
#     integer. It never fails the pick. The export sits before
#     formula_session_start "dev".
#   - lib/formula-session.sh resolves _FORMULA_TAPE_ATTEMPTS as
#     ${TAPE_RUN_ATTEMPTS:-1}, falling back to 1 when the value is not an
#     integer >= 1. Both the open run and the closing run carry that value.
#     No git calls in formula-session.
#
# Acceptance (hermetic — no live services, no agents started, no network):
#   1. TAPE_RUN_ATTEMPTS=3 → open and closing run attempts equal 3, rc 0
#   2. TAPE_RUN_ATTEMPTS unset, junk, 0, or negative → attempts 1, rc 0
#   3. dev-agent.sh exports TAPE_RUN_ATTEMPTS before formula_session_start
#      "dev"
#   4. (removed in #1753) the ATTEMPT-derived export block went with #1646;
#      tests/acceptance/issue-1646.sh covers the tape-driven count
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

# ── AC 1: TAPE_RUN_ATTEMPTS=3 → open and closing run attempts equal 3, rc 0 ─
T1="$TMP_DIR/tape-3"; P1="$TMP_DIR/payload-3"
rc=0
out="$(
  (
    set -euo pipefail
    log() { printf 'AC %s\\n' "\$*" >&2; }
    export AGENT_HARNESS=claude LOG_AGENT=acceptance
    source "$REPO_ROOT/lib/formula-session.sh"
    export TAPE_DIR="$T1" PAYLOAD_DIR="$P1"
    export TAPE_PROPOSAL_ID=ac-1478
    export TAPE_RUN_ATTEMPTS=3
    formula_session_start "acceptance-organ"
    formula_session_end 0
  ) 2>&1
)" || rc=$?
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
  out="$(
    (
      set -euo pipefail
      log() { printf 'AC %s\\n' "\$*" >&2; }
      export AGENT_HARNESS=claude LOG_AGENT=acceptance
      source "$REPO_ROOT/lib/formula-session.sh"
      export TAPE_DIR="$T2" PAYLOAD_DIR="$P2"
      export TAPE_PROPOSAL_ID=ac-1478
      if [ -n "$val" ]; then
        export TAPE_RUN_ATTEMPTS=$val
      else
        unset TAPE_RUN_ATTEMPTS
      fi
      formula_session_start "acceptance-organ"
      formula_session_end 0
    ) 2>&1
  )" || rc=$?
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

# AC 4 (the ATTEMPT-derived export block) went with the block in #1646;
# tests/acceptance/issue-1646.sh covers the tape-driven count.

# ── AC 5: the bats regression net passes ────────────────────────────────────
bats "$REPO_ROOT/tests/lib-formula-tape.bats" 2>&1 \
  || ac_fail "bats tests/lib-formula-tape.bats failed"
ac_log "AC 5 OK: tests/lib-formula-tape.bats passes"

ac_pass
