#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2163.sh — the planner waits for a running gardener
#
# Issue #2163: since #2151 the gardener's job runs two roles, gardener,planner.
# docker/agents/entrypoint.sh paces each slow organ by iteration * POLL_INTERVAL
# modulo its interval (#1388); 43200 is a multiple of 21600, so every 12 hours
# both organs start in the same iteration, the gardener first. Both runs call
# ensure_ops_repo on the one ops clone and pull it at the same moment (the
# 2026-11-07 overlap: "Cannot fast-forward to multiple branches"), and the
# planner reads what the gardener writes during its run (sprint grades on the
# tape, catalog/claims.md), so a planner that starts beside the gardener reads
# the previous run's state.
#
# planner/after-gardener.sh adds planner_wait_for_gardener: while pgrep finds
# gardener-run.sh it sleeps PLANNER_GARDENER_POLL_S (default 60), counting the
# wait by adding the poll interval per sleep (never the clock, so the test can
# stub sleep), and gives up after PLANNER_GARDENER_WAIT_S (default 10800). It
# always returns 0: waiting never stops a planner run.
#
# Hermetic: pgrep, sleep and log are stubbed in-process. No forge, no agent,
# no real waiting.
#
# Run via: bash tests/acceptance/issue-2163.sh
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep cut

AFTER="$REPO_ROOT/planner/after-gardener.sh"
RUN="$REPO_ROOT/planner/planner-run.sh"
DOC="$REPO_ROOT/planner/AGENTS.md"

# ── Static wiring ────────────────────────────────────────────────────────────
ac_log "static: after-gardener.sh exists and is sourced by planner-run.sh"
ac_assert_file "$AFTER" "planner/after-gardener.sh is missing"
bash -n "$AFTER"
bash -n "$RUN"
grep -qF 'after-gardener.sh' "$RUN" \
  || ac_fail "planner/planner-run.sh must source planner/after-gardener.sh"
grep -qF 'planner_wait_for_gardener' "$RUN" \
  || ac_fail "planner/planner-run.sh must call planner_wait_for_gardener"

ac_log "static: planner/AGENTS.md names the gardener wait"
grep -qF "planner_wait_for_gardener\` (\`planner/after-gardener.sh\`, #2163)" "$DOC" \
  || ac_fail "planner/AGENTS.md must name planner_wait_for_gardener and #2163"
grep -qF 'PLANNER_GARDENER_WAIT_S' "$DOC" \
  || ac_fail "planner/AGENTS.md must name PLANNER_GARDENER_WAIT_S"

ac_log "static: the call sits between acquire_run_lock and memory_guard/ensure_ops_repo"
line_lock="$(grep -nF 'acquire_run_lock "/tmp/planner-run.lock"' "$RUN" | head -n1 | cut -d: -f1)"
line_wait="$(grep -nE '^planner_wait_for_gardener$' "$RUN" | head -n1 | cut -d: -f1)"
line_mem="$(grep -nF 'memory_guard 2000' "$RUN" | head -n1 | cut -d: -f1)"
line_ops="$(grep -nE '^ensure_ops_repo$' "$RUN" | head -n1 | cut -d: -f1)"
[ -n "$line_lock" ] || ac_fail "planner-run.sh must call acquire_run_lock"
[ -n "$line_wait" ] || ac_fail "planner-run.sh must call planner_wait_for_gardener at top level"
[ -n "$line_mem" ] || ac_fail "planner-run.sh must call memory_guard"
[ -n "$line_ops" ] || ac_fail "planner-run.sh must call ensure_ops_repo"
[ "$line_lock" -lt "$line_wait" ] \
  || ac_fail "planner_wait_for_gardener (line $line_wait) must come after acquire_run_lock (line $line_lock)"
[ "$line_wait" -lt "$line_mem" ] \
  || ac_fail "planner_wait_for_gardener (line $line_wait) must come before memory_guard (line $line_mem)"
[ "$line_wait" -lt "$line_ops" ] \
  || ac_fail "planner_wait_for_gardener (line $line_wait) must come before ensure_ops_repo (line $line_ops)"

# ── Behaviour with in-process stubs ──────────────────────────────────────────
# shellcheck source=../planner/after-gardener.sh
source "$AFTER"

# In-process recorders: log() and sleep() are stubbed so the wait can be
# counted without real time passing.
SLEEPS=()
LOGS=()
log() { LOGS+=("$*"); }
sleep() { SLEEPS+=("$1"); }

# pgrep stub: PGREP_CALLS counts calls; the stub "finds a process" while
# PGREP_CALLS <= PGREP_FOUND, or always when PGREP_ALWAYS=1.
PGREP_CALLS=0
PGREP_FOUND=0
PGREP_ALWAYS=0
pgrep() {
  PGREP_CALLS=$((PGREP_CALLS + 1))
  if [ "$PGREP_ALWAYS" = "1" ] || [ "$PGREP_CALLS" -le "$PGREP_FOUND" ]; then
    return 0
  fi
  return 1
}

reset_stubs() {
  SLEEPS=()
  LOGS=()
  PGREP_CALLS=0
  PGREP_FOUND=0
  PGREP_ALWAYS=0
}

ac_log "AC1: no gardener running — returns 0, no sleeps, no log lines"
reset_stubs
RC=0
planner_wait_for_gardener || RC=$?
ac_assert_eq "$RC" "0" "no gardener running must return 0 (rc=$RC)"
ac_assert_eq "${#SLEEPS[@]}" "0" "no gardener running must never sleep (got ${#SLEEPS[@]} sleeps)"
ac_assert_eq "${#LOGS[@]}" "0" "no gardener running must log nothing (got ${#LOGS[@]} lines)"

ac_log "AC2: gardener running on the first two checks — two sleeps of 60, waited 120s"
reset_stubs
PGREP_FOUND=2
RC=0
planner_wait_for_gardener || RC=$?
ac_assert_eq "$RC" "0" "the wait must return 0 (rc=$RC)"
ac_assert_eq "${#SLEEPS[@]}" "2" "two detected gardener runs must mean exactly 2 sleeps (got ${#SLEEPS[@]})"
ac_assert_eq "${SLEEPS[0]}" "60" "the first sleep must be the default poll of 60s (got ${SLEEPS[0]})"
ac_assert_eq "${SLEEPS[1]}" "60" "the second sleep must be the default poll of 60s (got ${SLEEPS[1]})"
ac_assert_eq "${#LOGS[@]}" "2" "the wait must log a 'waits' line and a finish line (got ${#LOGS[@]})"
case "${LOGS[0]}" in
  *"waits for it"*) ;;
  *) ac_fail "the first log line must say the planner waits for the gardener (got '${LOGS[0]}')" ;;
esac
case "${LOGS[1]}" in
  *"120"*) ;;
  *) ac_fail "the finish log line must report 120 seconds waited (got '${LOGS[1]}')" ;;
esac

ac_log "AC3: gardener never finishes — waits up to PLANNER_GARDENER_WAIT_S and runs anyway"
reset_stubs
PGREP_ALWAYS=1
RC=0
PLANNER_GARDENER_WAIT_S=180 PLANNER_GARDENER_POLL_S=60 planner_wait_for_gardener || RC=$?
ac_assert_eq "$RC" "0" "the wait must always return 0 (rc=$RC)"
ac_assert_eq "${#SLEEPS[@]}" "3" "a 180s cap with 60s polls must sleep exactly 3 times (got ${#SLEEPS[@]})"
ac_assert_eq "${LOGS[-1]}" "gardener still running after 180s; the planner runs anyway" \
  "reaching the cap must log the 'runs anyway' line (got '${LOGS[-1]}')"

ac_log "AC4: a non-integer PLANNER_GARDENER_WAIT_S falls back to 10800"
reset_stubs
PGREP_ALWAYS=1
RC=0
PLANNER_GARDENER_WAIT_S=abc planner_wait_for_gardener || RC=$?
ac_assert_eq "$RC" "0" "an invalid wait value must still return 0 (rc=$RC)"
ac_assert_eq "${#SLEEPS[@]}" "180" "the default 10800s cap at 60s polls must sleep exactly 180 times (got ${#SLEEPS[@]})"
ac_assert_eq "${LOGS[-1]}" "gardener still running after 10800s; the planner runs anyway" \
  "the fallback cap must log the 10800s 'runs anyway' line (got '${LOGS[-1]}')"

ac_log "AC5: a non-integer PLANNER_GARDENER_POLL_S falls back to 60"
reset_stubs
PGREP_ALWAYS=1
RC=0
PLANNER_GARDENER_WAIT_S=120 PLANNER_GARDENER_POLL_S=xyz planner_wait_for_gardener || RC=$?
ac_assert_eq "$RC" "0" "an invalid poll value must still return 0 (rc=$RC)"
ac_assert_eq "${#SLEEPS[@]}" "2" "a 120s cap at the default 60s poll must sleep exactly 2 times (got ${#SLEEPS[@]})"
ac_assert_eq "${SLEEPS[0]}" "60" "the poll must fall back to 60s (got ${SLEEPS[0]})"

ac_log "AC6: shellcheck is clean on both files (when shellcheck is available)"
if command -v shellcheck >/dev/null 2>&1; then
  RC=0
  shellcheck "$AFTER" "$RUN" || RC=$?
  ac_assert_eq "$RC" "0" "shellcheck must be clean on after-gardener.sh and planner-run.sh (rc=$RC)"
else
  ac_warn "shellcheck not installed; skipping the lint AC"
fi

ac_log "AC7: the neighbouring planner tests still pass"
RC=0
bash "$REPO_ROOT/tests/acceptance/issue-2150.sh" >/dev/null || RC=$?
ac_assert_eq "$RC" "0" "issue-2150.sh must still pass (rc=$RC)"
RC=0
bash "$REPO_ROOT/tests/acceptance/issue-2151.sh" >/dev/null || RC=$?
ac_assert_eq "$RC" "0" "issue-2151.sh must still pass (rc=$RC)"

ac_pass
