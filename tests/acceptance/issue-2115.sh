#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2115.sh
#
# Issue #2115: the rollout tick promotes or rolls back the open rollout
# (docs/design/notes/self-update.md, "Watch", "Promote", "Roll back"). Once
# the #2114 tick has opened a rollout (state open.commit C, open.moved_at),
# the next tick watches C's evidence lines and:
#   - canary moved off C          -> rolled back, reason "moved", bit
#     rolled_back 0, no dev issue, blocked_main = main;
#   - still soaking               -> a closed run, "watching <sha7>: <polls>
#     polls, <soak_s>s", nothing moves;
#   - promote verdict           -> live fast-forwards to C (on failure: a run
#     with status failed, the rollout stays open), outcome promoted 1 with the
#     watch's smoke bit and soak_s/polls numbers, closed run, open = null,
#     "promoted <sha7>";
#   - rollback verdict          -> canary forced back to live, outcome promoted
#     0 rolled_back 1, closed run, open = null and blocked_main = main,
#     "rolled back <sha7>: <reason>", and rollout_rollback_issue(C, subject,
#     reason, evidence) — stubbed here to record its arguments.
# After a rollback a tick with main unchanged starts nothing; after a new
# commit on main the next tick opens a rollout of it.
#
# Hermetic: a bare repo as origin, main at M2, live and canary at M1, a temp
# TAPE_DIR, a pack with soak_s 1800 and take_polls 2, ROLLOUT_NOW pinned. No
# forge, no network: the tick runs through a wrapper that sources
# tools/rollout.sh and redefines rollout_rollback_issue to append its four
# arguments to ISSUE_LOG.
#
# Acceptance:
#   1. take of M2 at 5100 (smoke 0), polls of M2 at 5400 and 6950 (rc 0),
#      ROLLOUT_NOW=7000: live becomes M2; the tape has an outcome for the
#      proposal with bits.promoted 1, bits.rolled_back 0 and numbers.polls 2;
#      open is null.
#   2. the same evidence at ROLLOUT_NOW=6000: nothing moves, one more closed
#      run, no outcome.
#   3. a take of M2 with smoke 1: canary back at M1, an outcome with promoted 0
#      and rolled_back 1, blocked_main M2, the issue stub called with M2 and
#      smoke.
#   4. canary pushed back to M1 by hand before the tick: an outcome with
#      promoted 0 and rolled_back 0, the issue stub not called.
#   5. after a rollback, a tick with main unchanged writes no proposal; after
#      a new commit M3 on main, the next tick opens a rollout of M3.
#   6. bash -n tools/rollout.sh passes.
#
# Run via `tools/run-acceptance.sh 2115` or `bash tests/acceptance/issue-2115.sh`.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash git jq awk timeout

TOOL="$REPO_ROOT/tools/rollout.sh"
ac_assert_file "$TOOL" "tools/rollout.sh is missing"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/issue-2115.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PACK="$WORK/rollout.toml"
printf 'soak_s = 1800\ntake_polls = 2\n# the soak, in seconds\n' > "$PACK"

CANARY_JOB="agents-review-qwen"

# commit_on BRANCH MESSAGE — one commit on BRANCH in the clone $CLONE, echo its
# SHA (the same helper shape as issue-2114's fixture).
commit_on() {
  local branch="$1" message="$2"
  if git -C "$CLONE" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    git -C "$CLONE" checkout --quiet "$branch"
  elif git -C "$CLONE" rev-parse --verify --quiet HEAD >/dev/null; then
    git -C "$CLONE" checkout --quiet -b "$branch"
  fi
  printf '%s\n' "$message" >>"$CLONE/history.txt"
  git -C "$CLONE" add -A
  git -C "$CLONE" commit --quiet -m "$message"
  git -C "$CLONE" rev-parse HEAD
}

# fixture NAME — a fresh origin/clone pair: main at M2, live and canary at M1.
# Sets the globals ORIGIN, CLONE, TAPE_DIR, ISSUE_LOG, M1, M2.
fixture() {
  local name="$1"
  ORIGIN="$WORK/$name/origin"
  CLONE="$WORK/$name/clone"
  TAPE_DIR="$WORK/$name/tape"
  ISSUE_LOG="$WORK/$name/issues"
  mkdir -p "$CLONE" "$TAPE_DIR/rollout/evidence"
  git init -b main --bare "$ORIGIN" >/dev/null
  git init -b main "$CLONE" >/dev/null
  git -C "$CLONE" config user.name "rollout-close-test"
  git -C "$CLONE" config user.email "rollout-close-test@example.com"
  git -C "$CLONE" remote add origin "$ORIGIN"

  M1="$(commit_on main "M1")"
  git -C "$CLONE" push --quiet origin main
  git -C "$CLONE" push --quiet origin "$M1:refs/heads/live" "$M1:refs/heads/canary"
  M2="$(commit_on main "M2")"
  git -C "$CLONE" push --quiet origin main
}

# open_rollout — run the first tick: the rollout of M2 opens, canary at M2,
# moved_at 5000.
open_rollout() {
  canary_evidence
  tick 5000
  ac_assert_eq "$RC" 0 "the start tick must return 0, got $RC: $OUT"
  ac_assert_eq "$(origin_head canary)" "$M2" "the start tick must move canary to M2"
  PROP_ID="$(jq -r 'select(.type == "proposal") | .id' "$TAPE_DIR/tape.jsonl")"
}

# canary_evidence — the canary's pre-move lines, the last naming canary.
canary_evidence() {
  printf '%s\n' \
    "{\"t\":4000,\"kind\":\"take\",\"job\":\"${CANARY_JOB}\",\"ref\":\"canary\",\"commit\":\"${M1}\",\"smoke\":0}" \
    "{\"t\":4500,\"kind\":\"poll\",\"job\":\"${CANARY_JOB}\",\"ref\":\"canary\",\"commit\":\"${M1}\",\"role\":\"review\",\"rc\":0}" \
    "{\"t\":4800,\"kind\":\"poll\",\"job\":\"${CANARY_JOB}\",\"ref\":\"canary\",\"commit\":\"${M1}\",\"role\":\"review\",\"rc\":0}" \
    >"${TAPE_DIR}/rollout/evidence/${CANARY_JOB}.jsonl"
}

# m2_evidence SMOKE — append the canary's lines for M2: a take at 5100 with
# the given smoke result and two clean polls, at 5400 and 6950.
m2_evidence() {
  local smoke="$1"
  printf '%s\n' \
    "{\"t\":5100,\"kind\":\"take\",\"job\":\"${CANARY_JOB}\",\"ref\":\"canary\",\"commit\":\"${M2}\",\"smoke\":${smoke}}" \
    "{\"t\":5400,\"kind\":\"poll\",\"job\":\"${CANARY_JOB}\",\"ref\":\"canary\",\"commit\":\"${M2}\",\"role\":\"review\",\"rc\":0}" \
    "{\"t\":6950,\"kind\":\"poll\",\"job\":\"${CANARY_JOB}\",\"ref\":\"canary\",\"commit\":\"${M2}\",\"role\":\"review\",\"rc\":0}" \
    >>"${TAPE_DIR}/rollout/evidence/${CANARY_JOB}.jsonl"
}

# tick NOW — run one tick of the tool with rollout_rollback_issue stubbed:
# RC holds the status, OUT the combined log; every issue call appends
# "<commit>\t<subject>\t<reason>\t<evidence>" to ISSUE_LOG.
tick() {
  local now="$1"
  RC=0
  # shellcheck disable=SC2034  # OUT is consumed by the assertions below
  OUT="$(TAPE_DIR="$TAPE_DIR" ROLLOUT_GIT_DIR="$CLONE" ROLLOUT_PACK_FILE="$PACK" \
        ROLLOUT_CANARY_JOB="$CANARY_JOB" ROLLOUT_NOW="$now" ISSUE_LOG="$ISSUE_LOG" \
        bash -c '
          source "$1"
          rollout_rollback_issue() {
            printf "%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$4" >> "$ISSUE_LOG"
            return 0
          }
          rollout_tick
        ' stub "$TOOL" 2>&1)" || RC=$?
}

origin_head() {  # origin_head BRANCH — the SHA origin has for BRANCH
  git -C "$ORIGIN" rev-parse "refs/heads/$1" 2>/dev/null || echo missing
}

tape_count() {  # tape_count TYPE — how many records of TYPE the tape holds
  [ -r "$TAPE_DIR/tape.jsonl" ] || { echo 0; return; }
  jq -s --arg type "$1" '[.[] | select(.type == $type)] | length' "$TAPE_DIR/tape.jsonl"
}

log_has() {  # log_has TEXT — the tick's log contains TEXT
  case "$OUT" in
    *"$1"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── AC1: the soak met -> promote ──────────────────────────────────────────────
ac_log "AC1: verdict promote -> live fast-forwards to M2, outcome promoted 1, open null"
fixture ac1
open_rollout
m2_evidence 0
tick 7000
ac_assert_eq "$RC" 0 "AC1 the tick must return 0, got $RC: $OUT"
ac_assert_eq "$(origin_head live)" "$M2" "AC1 promote must fast-forward live to M2"
ac_assert_eq "$(origin_head canary)" "$M2" "AC1 canary must stay at M2"

ac_assert_eq "$(tape_count outcome)" "1" "AC1 the promote must append exactly one outcome"
OUTCOME="$(jq -c 'select(.type == "outcome")' "$TAPE_DIR/tape.jsonl")"
jq -e --arg pid "$PROP_ID" '
  .proposal_id == $pid and .bits.promoted == 1 and .bits.rolled_back == 0
  and .bits.smoke == 1 and .numbers.polls == 2 and .numbers.soak_s == 1900' \
  <<<"$OUTCOME" >/dev/null \
  || ac_fail "AC1 the outcome must promote with smoke 1, 2 polls, soak 1900: $OUTCOME"
ac_assert_eq "$(tape_count run)" "2" "AC1 the start tick and the promote tick each append one closed run"

STATE="$(cat "$TAPE_DIR/rollout/state.json")"
jq -e '.open == null' <<<"$STATE" >/dev/null \
  || ac_fail "AC1 the state must close the rollout: $STATE"
log_has "rollout: promoted ${M2:0:7}" \
  || ac_fail "AC1 the tick must log 'promoted ${M2:0:7}', got: $OUT"
if [ -e "$ISSUE_LOG" ]; then
  ac_fail "AC1 a promoted rollout must file no dev issue"
fi
ac_log "AC1 OK"

# ── AC2: still soaking -> wait ────────────────────────────────────────────────
ac_log "AC2: verdict wait at NOW 6000 -> nothing moves, one more closed run, no outcome"
fixture ac2
open_rollout
m2_evidence 0
tick 6000
ac_assert_eq "$RC" 0 "AC2 the tick must return 0, got $RC: $OUT"
ac_assert_eq "$(origin_head live)" "$M1" "AC2 a waiting tick must not move live"
ac_assert_eq "$(origin_head canary)" "$M2" "AC2 canary must still be M2"
ac_assert_eq "$(tape_count outcome)" "0" "AC2 a waiting tick must append no outcome"
ac_assert_eq "$(tape_count run)" "2" "AC2 the wait tick must append one more closed run"
log_has "rollout: watching ${M2:0:7}: 2 polls, 900s" \
  || ac_fail "AC2 the tick must log the watch, got: $OUT"
ac_log "AC2 OK"

# ── AC3: smoke failed -> rollback with a dev issue ────────────────────────────
ac_log "AC3: take of M2 with smoke 1 -> canary back to M1, rolled_back 1, blocked_main M2, issue filed"
fixture ac3
open_rollout
m2_evidence 1
tick 7000
ac_assert_eq "$RC" 0 "AC3 the tick must return 0, got $RC: $OUT"
ac_assert_eq "$(origin_head canary)" "$M1" "AC3 the rollback must reset canary to live (M1)"
ac_assert_eq "$(origin_head live)" "$M1" "AC3 live must stay at M1"

ac_assert_eq "$(tape_count outcome)" "1" "AC3 the rollback must append exactly one outcome"
OUTCOME="$(jq -c 'select(.type == "outcome")' "$TAPE_DIR/tape.jsonl")"
jq -e --arg pid "$PROP_ID" '
  .proposal_id == $pid and .bits.promoted == 0 and .bits.rolled_back == 1' \
  <<<"$OUTCOME" >/dev/null \
  || ac_fail "AC3 the outcome must roll back with promoted 0: $OUTCOME"
ac_assert_eq "$(tape_count run)" "2" "AC3 the rollback tick must append one closed run"

STATE="$(cat "$TAPE_DIR/rollout/state.json")"
jq -e --arg m2 "$M2" '.open == null and .blocked_main == $m2' <<<"$STATE" >/dev/null \
  || ac_fail "AC3 the state must close the rollout and block main at $M2: $STATE"
log_has "rollout: rolled back ${M2:0:7}: smoke" \
  || ac_fail "AC3 the tick must log 'rolled back ${M2:0:7}: smoke', got: $OUT"

ac_assert_file "$ISSUE_LOG" "AC3 the rollback must file exactly one dev issue"
ac_assert_eq "$(grep -c "^${M2}	" "$ISSUE_LOG")" "1" "AC3 the rollback must file exactly one dev issue"
IFS=$'\t' read -r issue_commit issue_subject issue_reason issue_evidence < "$ISSUE_LOG"
ac_assert_eq "$issue_commit" "$M2" "AC3 the issue must name the rolled-back commit M2"
ac_assert_eq "$issue_subject" "M2" "AC3 the issue must carry M2's commit subject"
ac_assert_eq "$issue_reason" "smoke" "AC3 the issue reason must be smoke"
case "$issue_evidence" in
  *'"smoke":1'*) ;;
  *) ac_fail "AC3 the issue evidence must carry the failing take: $issue_evidence" ;;
esac
ac_log "AC3 OK"

# ── AC4: canary moved off the commit by hand -> rolled back, no issue ─────────
ac_log "AC4: canary pushed back to M1 by hand -> rolled back with reason moved, rolled_back 0, no issue"
fixture ac4
open_rollout
m2_evidence 0
git -C "$ORIGIN" update-ref refs/heads/canary "$M1"
tick 7000
ac_assert_eq "$RC" 0 "AC4 the tick must return 0, got $RC: $OUT"
ac_assert_eq "$(origin_head canary)" "$M1" "AC4 the rollback must keep canary at live (M1)"
ac_assert_eq "$(origin_head live)" "$M1" "AC4 live must not move"

ac_assert_eq "$(tape_count outcome)" "1" "AC4 the moved rollback must append exactly one outcome"
OUTCOME="$(jq -c 'select(.type == "outcome")' "$TAPE_DIR/tape.jsonl")"
jq -e --arg pid "$PROP_ID" '
  .proposal_id == $pid and .bits.promoted == 0 and .bits.rolled_back == 0' \
  <<<"$OUTCOME" >/dev/null \
  || ac_fail "AC4 the moved outcome must have promoted 0 and rolled_back 0: $OUTCOME"

STATE="$(cat "$TAPE_DIR/rollout/state.json")"
jq -e --arg m2 "$M2" '.open == null and .blocked_main == $m2' <<<"$STATE" >/dev/null \
  || ac_fail "AC4 the state must close the rollout and block main at $M2: $STATE"
log_has "rollout: rolled back ${M2:0:7}: moved" \
  || ac_fail "AC4 the tick must log 'rolled back ${M2:0:7}: moved', got: $OUT"
if [ -e "$ISSUE_LOG" ]; then
  ac_fail "AC4 a moved rollout must file no dev issue"
fi
ac_log "AC4 OK"

# ── AC5: after a rollback, main must move before the next rollout ─────────────
ac_log "AC5: main unchanged after a rollback -> no proposal; a new M3 -> the next tick opens it"
fixture ac5
open_rollout
m2_evidence 1
tick 7000
ac_assert_eq "$RC" 0 "AC5 the rollback tick must return 0, got $RC: $OUT"

tick 8000
ac_assert_eq "$RC" 0 "AC5 the blocked tick must return 0, got $RC: $OUT"
ac_assert_eq "$(tape_count proposal)" "1" "AC5 a blocked main must append no proposal"
ac_assert_eq "$(origin_head canary)" "$M1" "AC5 the blocked tick must leave canary at live (M1)"
log_has "rollout: waiting for main to move past ${M2:0:7}" \
  || ac_fail "AC5 the blocked tick must log the wait for main, got: $OUT"

M3="$(commit_on main "M3")"
git -C "$CLONE" push --quiet origin main
tick 8100
ac_assert_eq "$RC" 0 "AC5 the restart tick must return 0, got $RC: $OUT"
ac_assert_eq "$(origin_head canary)" "$M3" "AC5 the new rollout must move canary to M3"
ac_assert_eq "$(tape_count proposal)" "2" "AC5 the new rollout must append a second proposal"
STATE="$(cat "$TAPE_DIR/rollout/state.json")"
jq -e --arg m3 "$M3" '.open.commit == $m3' <<<"$STATE" >/dev/null \
  || ac_fail "AC5 the state must open the rollout of $M3: $STATE"
ac_log "AC5 OK"

# ── AC6: the tool parses ──────────────────────────────────────────────────────
ac_log "AC6: bash -n tools/rollout.sh passes"
bash -n "$TOOL" || ac_fail "bash -n tools/rollout.sh must pass"
ac_log "AC6 OK"

ac_pass
