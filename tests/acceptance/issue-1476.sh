#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1476.sh
#
# Issue #1476: planner/planner-run.sh — planner_tape_tick no longer appends a
# second loop=dev "approved" proposal for the backlog issue the planner just
# filed. The pick (dev-poll) writes the "approved" proposal when it claims the
# backlog issue — the pick is the sample. A second planner-side "approved"
# row pre-approved work the factory had not yet run (and would re-fire #1462's
# counts forecast on that extra row).
#
# Fix: planner_tape_tick() does not call emit_planner_proposal; emit_planner_proposal
# is deleted (it has no remaining caller); the pre-session open-issue snapshot
# that only fed that emission is gone too.
#
# Acceptance criteria exercised:
#   1. After planner_tape_tick, tape_proposal has not been called (the extracted
#      tick runs against a stubbed tape_proposal and the stub is never invoked).
#   2. No remaining caller (or definition) of emit_planner_proposal.
#   3. Planner still files backlog issues — the prompt / forge (tea) calls are
#      untouched: planner-run.sh still sources lib/tape.sh for the run lifecycle
#      (formula_session_start/end) and still drives agent_run, and no "discussed"
#      stand-in was written.
#
# Hermetic: no network, no live services. The tick is extracted with ac_extract_fn
# and run in a throwaway subshell against a stubbed tape_proposal + fixture
# TAPE_DIR.
#
# Run via: tools/run-acceptance.sh 1476
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk grep jq mktemp

TARGET="$REPO_ROOT/planner/planner-run.sh"
ac_assert_file "$TARGET" "planner/planner-run.sh must exist"

# ── 2. No remaining caller (or definition) of emit_planner_proposal ─────────
# The emitter was deleted by #1476; neither the definition nor a call site may
# survive (a dangling call would crash the planner run).
if grep -q 'emit_planner_proposal' "$TARGET"; then
  ac_fail "emit_planner_proposal still present (definition or caller) in planner-run.sh"
fi
# The pre-snapshot machinery that only fed that emission is also gone.
if grep -q 'planner_open_issues_json\|PLANNER_PRE_ISSUES' "$TARGET"; then
  ac_fail "pre-session open-issue snapshot (planner_open_issues_json / PLANNER_PRE_ISSUES) still present"
fi
# No "discussed" stand-in was written in its place (the pick is the sample).
if grep -qiE "planner.*(discussed|stand-in)" "$TARGET"; then
  ac_fail "a 'discussed' stand-in was written for the removed planner emission"
fi

# ── Extract planner_tape_tick (must still be a wired call site) ─────────────
# The tick remains as the guarded call site after the session closes; the
# acceptance test extracts it and runs it standalone (subshell), so the
# source must still be extractable by ac_extract_fn.
TICK_SRC="$(ac_extract_fn planner_tape_tick "$TARGET")"
[ -n "$TICK_SRC" ] || ac_fail "could not extract planner_tape_tick() from planner-run.sh"
# The tick is still invoked after the session closes (wiring intact).
if ! grep -q '^planner_tape_tick$' "$TARGET"; then
  ac_fail "planner_tape_tick must remain a call site after the session closes"
fi
# It must not reference tape_proposal or the deleted emitter.
if grep -qF 'tape_proposal' <<<"$TICK_SRC" || grep -qF 'emit_planner_proposal' <<<"$TICK_SRC"; then
  ac_fail "planner_tape_tick body must not reference tape_proposal / emit_planner_proposal"
fi

# ── Hermetic fixture ─────────────────────────────────────────────────────────
PROJECT_NAME="acceptance-1476"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TAPE_DIR="$TMP_DIR/tape"
mkdir -p "$TAPE_DIR"
# A pre-file argument that is readable but empty (nothing pre-existing to diff
# against) — the tick's old guard required it to be non-empty AND readable.
PRE_FILE="$TMP_DIR/pre-issues"
: > "$PRE_FILE"

# log() stand-in so any extracted warning lines reach the captured output.
# shellcheck disable=SC2034
log() { echo "planner: $*"; }

# ── 1. After planner_tape_tick, tape_proposal has not been called ──────────
# Run the extracted tick in a throwaway subshell with a stub tape_proposal that
# records every invocation in a file (subshells can't share variables). If
# tape_proposal fires, the stub appends a line and the assertion below fails.
TAPE_CALLS="${TAPE_DIR}/.calls"
(
  export TAPE_DIR="$TAPE_DIR"
  export PROJECT_NAME="$PROJECT_NAME"
  export PRE_FILE="$PRE_FILE"
  export TAPE_CALLS="$TAPE_CALLS"
  # stub the tape surface so the tick can run without live services; the
  # real lib/tape.sh is not needed (the tick no longer emits anything).
  tape_proposal() {
    printf 'TAPE_PROPOSAL_REF=%s\n' "${10:-unknown}" >> "$TAPE_DIR/.calls"
    return 0
  }
  eval "$TICK_SRC"
  # feed the tick an empty pre-file (nothing pre-existing to diff against)
  planner_tape_tick "$PRE_FILE"
) 2>&1 || ac_fail "planner_tape_tick failed to run hermetically"

# If tape_proposal was ever called, .calls is non-empty.
if [ -s "$TAPE_CALLS" ]; then
  ac_fail "tape_proposal was called by planner_tape_tick (it must not emit after #1476)"
fi
# The tick must not have written to the tape at all (no .calls, no jsonl).
if find "$TAPE_DIR" -mindepth 1 2>/dev/null | head -n1 | grep -q .; then
  ac_fail "planner_tape_tick must not write to the tape after #1476"
fi

# ── 3. The planner still files backlog issues — the prompt/forge calls are
#     untouched; the wrapper still sources lib/tape.sh for the run lifecycle. ─
grep -q '^source .*lib/tape\.sh' "$TARGET" \
  || ac_fail "planner-run.sh must source lib/tape.sh (run open/close via formula_session_start/end)"
grep -q 'formula_session_start' "$TARGET" \
  || ac_fail "planner-run.sh must open the tape run (formula_session_start)"
grep -q 'formula_session_end' "$TARGET" \
  || ac_fail "planner-run.sh must close the tape run (formula_session_end)"
# The filing path (agent drives tea/curl inside the session) is intact:
grep -q 'agent_run' "$TARGET" \
  || ac_fail "planner-run.sh must still invoke agent_run (the planner files issues via its session)"

ac_pass