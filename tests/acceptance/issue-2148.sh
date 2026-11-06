#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2148.sh
#
# Issue #2148: fix(gardener): a run with nothing to groom still writes claim
# checks and sprint grades.
#
# gardener/idle-steps.sh defines gardener_idle_steps: it fetches the primary
# branch, then runs the six bash-only tape tools of a full run — sprint-outcomes,
# sprint-grades, tape-rejections, grade-threshold, claim-proposals, claim-checks
# — in that order. sprint-grades runs with SPRINT_HELD_REF set to
# "${FORGE_REMOTE}/${PRIMARY_BRANCH}". A tool that exits non-zero only logs
# `WARNING: <step>.sh failed (rc=<rc>, idle run)`, and the function itself
# always returns 0.
#
# gardener/gardener-run.sh sources the file and calls gardener_idle_steps in
# the early-exit branch, between the "no issues to groom" log line and the
# exit 0.
#
# Hermetic: no network, no forge, no agent, no live tape. The six tools are
# stubs in a throwaway FACTORY_ROOT/tools, and the git fetch runs against a
# throwaway local origin.
#
# Acceptance: `bash tests/acceptance/issue-2148.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash git awk
ac_assert_file "$REPO_ROOT/gardener/idle-steps.sh" "gardener/idle-steps.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/gardener-run.sh" "gardener/gardener-run.sh is missing"

# The six bash-only tape steps, in the order a full run runs them.
STEPS="sprint-outcomes sprint-grades tape-rejections grade-threshold claim-proposals claim-checks"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# write_stub STEP [RC] — a stub tool at $FACTORY_ROOT/tools/STEP.sh that
# appends its own name to $RECORD_FILE (sprint-grades also appends
# $SPRINT_HELD_REF) and exits RC.
write_stub() {
  local step="$1" rc="${2:-0}" dest
  dest="$FACTORY_ROOT/tools/${step}.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "printf '%s\\n' '${step}' >> '${RECORD_FILE}'"
    if [ "$step" = "sprint-grades" ]; then
      printf '%s\n' 'printf "%s\n" "$SPRINT_HELD_REF" >> "$RECORD_FILE"'
    fi
    printf '%s\n' "exit ${rc}"
  } >"$dest"
  chmod +x "$dest"
}

# run_idle — call gardener_idle_steps in this shell with the fixture env,
# capturing its return code in RC and every log() line in $LOG_FILE.
run_idle() {
  RC=0
  : >"$RECORD_FILE"
  : >"$LOG_FILE"
  gardener_idle_steps || RC=$?
}

FACTORY_ROOT="$TMP_DIR/factory"
RECORD_FILE="$TMP_DIR/steps-ran"
LOG_FILE="$TMP_DIR/gardener-log"
PROJECT_REPO_ROOT="$TMP_DIR/project"
FORGE_REMOTE=origin
PRIMARY_BRANCH=main
export FACTORY_ROOT RECORD_FILE LOG_FILE PROJECT_REPO_ROOT FORGE_REMOTE PRIMARY_BRANCH
mkdir -p "$FACTORY_ROOT/tools" "$PROJECT_REPO_ROOT"

# A real local origin so the fetch inside gardener_idle_steps is exercised,
# not just tolerated.
ac_git_ops_origin "$TMP_DIR"
PROJECT_REPO_ROOT="$WORK_DIR"
export PROJECT_REPO_ROOT

# The run scripts get log() from lib/env.sh; a stub stands in here.
# shellcheck disable=SC2317  # the sourced function calls this test's log stub
log() {
  printf 'log: %s\n' "$*" >>"$LOG_FILE"
}

# shellcheck source=../../gardener/idle-steps.sh
source "$REPO_ROOT/gardener/idle-steps.sh"

# ── AC1: an idle run runs the six steps in order, and never fails ─────────────
ac_log "AC1: with six stubs, gardener_idle_steps returns 0 and runs them in order"
for step in $STEPS; do
  write_stub "$step" 0
done
run_idle
ac_assert_eq "$RC" "0" "an idle run of gardener_idle_steps must return 0 (got $RC)"
WANT=""
for step in $STEPS; do
  [ -z "$WANT" ] || WANT="${WANT}"$'\n'
  WANT="${WANT}${step}"
  if [ "$step" = "sprint-grades" ]; then
    WANT="${WANT}"$'\norigin/main'
  fi
done
ac_assert_eq "$(cat "$RECORD_FILE")" "$WANT" \
  "the steps must run in the full-run order, with origin/main after sprint-grades"
ac_log "AC1 OK: six steps ran in order, origin/main reached sprint-grades"

# ── AC2: a failing step only warns; the remaining steps still run ─────────────
ac_log "AC2: claim-proposals.sh exiting 3 logs a warning and does not stop claim-checks"
write_stub claim-proposals 3
run_idle
ac_assert_eq "$RC" "0" "a failing idle step must not make gardener_idle_steps fail (got $RC)"
grep -qF 'WARNING: claim-proposals.sh failed (rc=3, idle run)' "$LOG_FILE" \
  || ac_fail "a failing idle step must log 'WARNING: <step>.sh failed (rc=<rc>, idle run)' (log: $(cat "$LOG_FILE"))"
grep -qF 'claim-checks' "$RECORD_FILE" \
  || ac_fail "claim-checks must still run after claim-proposals fails (ran: $(cat "$RECORD_FILE"))"
ac_log "AC2 OK: the warning was logged and claim-checks still ran"

# ── AC3: the idle call is wired into the early-exit branch ────────────────────
ac_log "AC3: gardener-run.sh sources idle-steps.sh and calls gardener_idle_steps in the skip branch"
GARDENER="$REPO_ROOT/gardener/gardener-run.sh"
grep -qF 'source "$FACTORY_ROOT/gardener/idle-steps.sh"' "$GARDENER" \
  || ac_fail "gardener-run.sh must source gardener/idle-steps.sh"
SKIP_LINE=$(grep -n 'no issues to groom' "$GARDENER" | head -n1 | cut -d: -f1)
IDLE_LINE=$(grep -n 'gardener_idle_steps' "$GARDENER" | head -n1 | cut -d: -f1)
EXIT_LINE=$(awk -v from="$SKIP_LINE" 'NR > from && /^[[:space:]]*exit 0/ { print NR; exit }' "$GARDENER")
[ -n "$SKIP_LINE" ] || ac_fail "gardener-run.sh must still log the no-issues-to-groom skip line"
[ -n "$IDLE_LINE" ] || ac_fail "gardener-run.sh must call gardener_idle_steps"
[ -n "$EXIT_LINE" ] || ac_fail "the skip branch must still exit 0 after the idle call"
[ "$SKIP_LINE" -lt "$IDLE_LINE" ] \
  || ac_fail "gardener_idle_steps (line $IDLE_LINE) must follow the skip log line (line $SKIP_LINE)"
[ "$IDLE_LINE" -lt "$EXIT_LINE" ] \
  || ac_fail "gardener_idle_steps (line $IDLE_LINE) must precede the exit 0 (line $EXIT_LINE)"
grep -qF 'refresh_ops_calibration' "$GARDENER" \
  || ac_fail "the full run must still refresh the ops catalog (out of scope for #2148)"
ac_log "AC3 OK: the idle steps run before the skip branch exits"

# ── AC4: the doc names the idle steps ─────────────────────────────────────────
ac_log "AC4: gardener/AGENTS.md describes the idle run's bash-only tape steps"
DOC_FLAT="$(tr '\n' ' ' < "$REPO_ROOT/gardener/AGENTS.md" | tr -s ' ')"
printf '%s\n' "$DOC_FLAT" | grep -qF 'gardener_idle_steps` (`gardener/idle-steps.sh`, #2148)' \
  || ac_fail "gardener/AGENTS.md must name gardener_idle_steps (gardener/idle-steps.sh, #2148)"
if printf '%s\n' "$DOC_FLAT" | grep -qF 'the run exits immediately'; then
  ac_fail "gardener/AGENTS.md must no longer say an idle run exits immediately without the tape steps"
fi
ac_log "AC4 OK: the doc matches the behavior"

# ── AC5: shellcheck is clean on both files ────────────────────────────────────
if command -v shellcheck >/dev/null 2>&1; then
  ac_log "AC5: shellcheck gardener/idle-steps.sh gardener/gardener-run.sh"
  sc_rc=0
  shellcheck --severity=warning \
    "$REPO_ROOT/gardener/idle-steps.sh" "$REPO_ROOT/gardener/gardener-run.sh" || sc_rc=$?
  ac_assert_eq "$sc_rc" "0" "shellcheck must be clean (got $sc_rc)"
  ac_log "AC5 OK: shellcheck clean"
else
  ac_warn "shellcheck not installed; skipping the lint criterion"
fi

ac_pass
