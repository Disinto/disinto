#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2114.sh
#
# Issue #2114: tools/rollout.sh gains the tick that starts a rollout
# (docs/design/notes/self-update.md, "Start" and "Records and the grade").
# `tools/rollout.sh tick` — when nothing is being rolled out and main is ahead
# of live — moves canary to main's head, appends one proposal of loop `rollout`
# whose ref is that commit, one closed run for the tick, and records the open
# rollout in ${TAPE_DIR}/rollout/state.json. Any other argument: usage, exit 2.
#
# Hermetic: a bare repo as `origin`, main at M2, live and canary at M1, a temp
# TAPE_DIR, a pack with soak_s = 1800 and take_polls = 2, ROLLOUT_NOW=5000, and
# an evidence file whose last take/poll line has ref canary. No forge, no
# network.
#
# Acceptance:
#   1. one tick: canary is M2; the tape holds one proposal (loop rollout, ref
#      M2, decision auto) and one closed run for it; state.json has
#      .open.commit M2 and .open.moved_at 5000.
#   2. a second tick: no new proposal, canary still M2.
#   3. HOLD present, or no pack, or the evidence's last line naming main: no
#      proposal, canary still M1.
#   4. blocked_main = M2 in the state: no proposal.
#   5. no open rollout, main and live at M2, canary at M1: canary becomes M2,
#      no proposal.
#   6. `bash tools/rollout.sh foo` exits 2; `bash -n tools/rollout.sh` passes.
#
# Acceptance: `bash tests/acceptance/issue-2114.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../lib/rollout-fixture.sh
source "$REPO_ROOT/tests/lib/rollout-fixture.sh"

ac_require_cmd bash git jq awk timeout

TOOL="$REPO_ROOT/tools/rollout.sh"
ac_assert_file "$TOOL" "tools/rollout.sh is missing"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/issue-2114.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PACK="$WORK/rollout.toml"
printf 'soak_s = 1800\ntake_polls = 2\n# the soak, in seconds\n' > "$PACK"

CANARY_JOB="agents-review-qwen"
NOW=5000

# The fixture helpers (commit_on, rollout_fixture, origin_head, tape_count)
# come from tests/lib/rollout-fixture.sh, shared with issue-2115's test.

# canary_evidence REF — write the canary's evidence lines into the fixture's
# tape, the last one a poll following REF.
canary_evidence() {
  local ref="$1"
  printf '%s\n' \
    "{\"t\":4000,\"kind\":\"take\",\"job\":\"${CANARY_JOB}\",\"ref\":\"canary\",\"commit\":\"${M1}\",\"smoke\":0}" \
    "{\"t\":4500,\"kind\":\"poll\",\"job\":\"${CANARY_JOB}\",\"ref\":\"canary\",\"commit\":\"${M1}\",\"role\":\"review\",\"rc\":0}" \
    "{\"t\":4800,\"kind\":\"poll\",\"job\":\"${CANARY_JOB}\",\"ref\":\"${ref}\",\"commit\":\"${M1}\",\"role\":\"review\",\"rc\":0}" \
    >"${TAPE_DIR}/rollout/evidence/${CANARY_JOB}.jsonl"
}

# run_tick — run the tool's tick on the current fixture: RC holds the status,
# OUT the combined stderr log and stdout.
run_tick() {
  RC=0
  # shellcheck disable=SC2034  # OUT is consumed by the assertions below
  OUT="$(TAPE_DIR="$TAPE_DIR" ROLLOUT_GIT_DIR="$CLONE" ROLLOUT_PACK_FILE="$PACK" \
        ROLLOUT_CANARY_JOB="$CANARY_JOB" ROLLOUT_NOW="$NOW" bash "$TOOL" tick 2>&1)" \
    || RC=$?
}

# ── AC1: one tick starts the rollout ──────────────────────────────────────────
ac_log "AC1: main ahead of live -> canary to M2, proposal + closed run, state open"
rollout_fixture ac1
canary_evidence canary
run_tick
ac_assert_eq "$RC" 0 "AC1 the tick must return 0, got $RC: $OUT"
ac_assert_eq "$(origin_head canary)" "$M2" "AC1 canary must move to M2"

ac_assert_eq "$(tape_count proposal)" "1" "AC1 the tick must append exactly one proposal"
PROP="$(jq -c 'select(.type == "proposal")' "$TAPE_DIR/tape.jsonl")"
jq -e --arg m2 "$M2" --arg m1 "$M1" --arg job "$CANARY_JOB" '
  .loop == "rollout" and .ref == $m2 and .decision == "auto"
  and .class == $job and .context.live == $m1' <<<"$PROP" >/dev/null \
  || ac_fail "AC1 the proposal must be loop rollout, ref $M2, decision auto, class $CANARY_JOB, context.live $M1: $PROP"

ac_assert_eq "$(tape_count run)" "1" "AC1 the tick must append exactly one run"
RUN="$(jq -c 'select(.type == "run")' "$TAPE_DIR/tape.jsonl")"
ac_assert_eq "$(printf '%s' "$RUN" | jq -r '.proposal_id')" "$(printf '%s' "$PROP" | jq -r '.id')" \
  "AC1 the run must belong to the proposal"
ac_assert_jq '.organ == "supervisor" and .agent == "rollout" and .status == "completed"' "$RUN" \
  "AC1 the run must be a closed supervisor/rollout run"
case "$OUT" in
  *"rollout: started ${M2:0:7}"*) ;;
  *) ac_fail "AC1 the tick must log 'started ${M2:0:7}', got: $OUT" ;;
esac

STATE="$(cat "$TAPE_DIR/rollout/state.json")"
jq -e --arg m2 "$M2" '
  .open.commit == $m2 and .open.moved_at == 5000 and .blocked_main == null' <<<"$STATE" >/dev/null \
  || ac_fail "AC1 state.json must open the rollout at $M2 with moved_at 5000: $STATE"
ac_assert_eq "$(printf '%s' "$STATE" | jq -r '.open.id')" "rollout-${NOW}-${M2:0:12}" \
  "AC1 the open id must be rollout-<now>-<main's first 12>"

# ── AC2: the second tick sees the open rollout and does nothing ───────────────
ac_log "AC2: a second tick adds no proposal and leaves canary at M2"
run_tick
ac_assert_eq "$RC" 0 "AC2 the tick must return 0, got $RC: $OUT"
ac_assert_eq "$(tape_count proposal)" "1" "AC2 a second tick must append no proposal"
ac_assert_eq "$(origin_head canary)" "$M2" "AC2 canary must still be M2"
case "$OUT" in
  *"rollout: open: rollout-${NOW}-${M2:0:12}"*) ;;
  *) ac_fail "AC2 the tick must log the open rollout, got: $OUT" ;;
esac

# ── AC3: the hold, the missing pack and an idle canary all stop the tick ──────
ac_log "AC3a: HOLD present -> on hold, nothing moves"
rollout_fixture ac3a
canary_evidence canary
: > "${TAPE_DIR}/rollout/HOLD"
run_tick
ac_assert_eq "$RC" 0 "AC3a the tick must return 0, got $RC: $OUT"
ac_assert_eq "$(tape_count proposal)" "0" "AC3a a held tick must append no proposal"
ac_assert_eq "$(origin_head canary)" "$M1" "AC3a canary must stay at M1"
case "$OUT" in
  *"rollout: on hold"*) ;;
  *) ac_fail "AC3a the tick must log 'on hold', got: $OUT" ;;
esac

ac_log "AC3b: no pack -> off, nothing moves"
rollout_fixture ac3b
canary_evidence canary
RC=0
OUT="$(TAPE_DIR="$TAPE_DIR" ROLLOUT_GIT_DIR="$CLONE" ROLLOUT_PACK_FILE="$WORK/no-such-pack.toml" \
      ROLLOUT_CANARY_JOB="$CANARY_JOB" ROLLOUT_NOW="$NOW" bash "$TOOL" tick 2>&1)" || RC=$?
ac_assert_eq "$RC" 0 "AC3b the tick must return 0, got $RC: $OUT"
ac_assert_eq "$(tape_count proposal)" "0" "AC3b a tick with no pack must append no proposal"
ac_assert_eq "$(origin_head canary)" "$M1" "AC3b canary must stay at M1"
case "$OUT" in
  *"rollout: off: no pack"*) ;;
  *) ac_fail "AC3b the tick must log 'off: no pack', got: $OUT" ;;
esac

ac_log "AC3c: the canary's last line names main -> idle, nothing moves"
rollout_fixture ac3c
canary_evidence main
run_tick
ac_assert_eq "$RC" 0 "AC3c the tick must return 0, got $RC: $OUT"
ac_assert_eq "$(tape_count proposal)" "0" "AC3c an idle canary must append no proposal"
ac_assert_eq "$(origin_head canary)" "$M1" "AC3c canary must stay at M1"
case "$OUT" in
  *"rollout: idle: ${CANARY_JOB} does not follow canary"*) ;;
  *) ac_fail "AC3c the tick must log that ${CANARY_JOB} does not follow canary, got: $OUT" ;;
esac

# ── AC4: blocked_main stops a new rollout ─────────────────────────────────────
ac_log "AC4: blocked_main = M2 -> no proposal"
rollout_fixture ac4
canary_evidence canary
printf '{"open":null,"blocked_main":"%s"}\n' "$M2" > "$TAPE_DIR/rollout/state.json"
run_tick
ac_assert_eq "$RC" 0 "AC4 the tick must return 0, got $RC: $OUT"
ac_assert_eq "$(tape_count proposal)" "0" "AC4 a blocked main must append no proposal"
ac_assert_eq "$(origin_head canary)" "$M1" "AC4 canary must stay at M1"
case "$OUT" in
  *"rollout: waiting for main to move past ${M2:0:7}"*) ;;
  *) ac_fail "AC4 the tick must log the wait for main, got: $OUT" ;;
esac

# ── AC5: canary drifted from live -> pulled back, no rollout ──────────────────
ac_log "AC5: main and live at M2, canary at M1 -> canary reset to live, no proposal"
rollout_fixture ac5
canary_evidence canary
git -C "$ORIGIN" update-ref refs/heads/live "$M2"
run_tick
ac_assert_eq "$RC" 0 "AC5 the tick must return 0, got $RC: $OUT"
ac_assert_eq "$(origin_head canary)" "$M2" "AC5 canary must be pulled back to live (M2)"
ac_assert_eq "$(tape_count proposal)" "0" "AC5 the reset must append no proposal"
case "$OUT" in
  *"rollout: canary reset to live"*) ;;
  *) ac_fail "AC5 the tick must log 'canary reset to live', got: $OUT" ;;
esac

# ── AC6: the direct-run guard ──────────────────────────────────────────────────
ac_log "AC6: bash -n passes; a bad argument exits 2 with the usage"
bash -n "$TOOL" || ac_fail "bash -n tools/rollout.sh must pass"

direct_rc=0
direct_msg="$(bash "$TOOL" foo 2>&1)" || direct_rc=$?
ac_assert_eq "$direct_rc" 2 "tools/rollout.sh run with a bad argument must exit 2, got $direct_rc"
ac_assert_eq "$direct_msg" "usage: tools/rollout.sh tick" \
  "tools/rollout.sh run with a bad argument must print its usage, got: $direct_msg"

ac_pass
