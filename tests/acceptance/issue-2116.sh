#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2116.sh
#
# Issue #2116: the supervisor tick runs one step of the update-self rollout
# (docs/design/notes/self-update.md, "The flow"). supervisor/supervisor-run.sh
# calls `bash "$FACTORY_ROOT/tools/rollout.sh" tick` once per tick, right
# after the repair-tape pass (repair_tape_tick) and before the LLM escalation
# gate (LLM_REQUIRED=true). The call sits at top level — not inside the
# RECIPE_EVAL_OK conditional — and is guarded so a failing rollout never fails
# the tick: its output goes to the supervisor log and the line ends with
# `|| log "WARNING: rollout tick failed"`.
#
# Acceptance:
#   1. exactly one rollout tick call exists in supervisor/supervisor-run.sh
#   2. it comes after the repair_tape_tick call and before the first
#      top-level `LLM_REQUIRED=true` line
#   3. it starts at column 0 (outside the RECIPE_EVAL_OK conditional)
#   4. it ends with the WARNING guard, so the tick never fails
#   5. supervisor-run.sh still parses (bash -n)
#
# Hermetic: static checks on the shipped file; no services needed.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"

# ── 1. exactly one rollout tick call ─────────────────────────────────────────
CALLS="$(grep -cF 'tools/rollout.sh" tick' "$TARGET" || true)"
[ "$CALLS" = "1" ] \
  || ac_fail "supervisor-run.sh must call tools/rollout.sh tick exactly once (found $CALLS)"

ROLL_LINE="$(grep -nF 'tools/rollout.sh" tick' "$TARGET" | head -n1 | cut -d: -f1)"
[ -n "$ROLL_LINE" ] || ac_fail "could not locate the rollout tick call line"

# ── 2. wired between the repair tape and the LLM escalation gate ─────────────
TICK_LINE="$(grep -n '^[[:space:]]*repair_tape_tick$' "$TARGET" | head -n1 | cut -d: -f1 || true)"
[ -n "$TICK_LINE" ] \
  || ac_fail "the repair tape tick call must still be present (#1408, #1713)"
[ "$TICK_LINE" -lt "$ROLL_LINE" ] \
  || ac_fail "the rollout tick must run after repair_tape_tick"

GATE_LINE="$(grep -n '^LLM_REQUIRED=true' "$TARGET" | head -n1 | cut -d: -f1 || true)"
[ -n "$GATE_LINE" ] \
  || ac_fail "supervisor-run.sh must keep the LLM escalation gate"
[ "$ROLL_LINE" -lt "$GATE_LINE" ] \
  || ac_fail "the rollout tick must run before the LLM escalation gate"

# ── 3. top level: column 0, not nested inside the RECIPE_EVAL_OK conditional ──
ROLL_TEXT="$(sed -n "${ROLL_LINE}p" "$TARGET")"
[[ "$ROLL_TEXT" != [[:space:]]* ]] \
  || ac_fail "the rollout tick call must sit at column 0, not inside a conditional (got: $ROLL_TEXT)"
grep -qF "bash \"\$FACTORY_ROOT/tools/rollout.sh\" tick" <<< "$ROLL_TEXT" \
  || ac_fail "the rollout tick call must run the tool from this checkout (got: $ROLL_TEXT)"

# ── 4. a failed rollout never fails the tick ─────────────────────────────────
[[ "$ROLL_TEXT" == *'|| log "WARNING: rollout tick failed"' ]] \
  || ac_fail "the rollout tick call must end with || log \"WARNING: rollout tick failed\""

# ── 5. the script still parses ───────────────────────────────────────────────
bash -n "$TARGET" || ac_fail "supervisor-run.sh does not parse (bash -n)"

ac_log "rollout tick wired at line $ROLL_LINE (repair tape at $TICK_LINE, LLM gate at $GATE_LINE)"
echo PASS
