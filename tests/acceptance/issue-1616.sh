#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1616.sh
#
# Issue #1616: outcomes carry CI-red and review-round totals.
#
# dev-agent.sh's close_dev_tape_outcome() wrote a hardcoded
#   numbers: {review_rounds: 0}
# so the dev outcome never reflected how many CI-reds the walk hit or how many
# review rounds ran. pr_walk_to_merge() in lib/pr-lifecycle.sh now tracks two
# walk-wide, never-reset totals and the outcome surfaces them:
#   numbers.ci_red        = ${PR_WALK_CI_RED:-0}
#   numbers.review_rounds = ${PR_WALK_REVIEW_ROUNDS:-0}
# The ${...:-0} defaults yield 0 on the no-walk (early-exit) paths, and
# duration_s is unchanged (still proposal_elapsed_s, omitted when unavailable).
#
# Contract under test (#1616):
#   (1) a stubbed walk with one CI failure + one review round + merge ends with
#       PR_WALK_CI_RED=1 and PR_WALK_REVIEW_ROUNDS=1;
#   (2) close_dev_tape_outcome after that walk writes numbers.ci_red == 1 and
#       numbers.review_rounds == 1;
#   (3) a no-walk early exit (no walk ran) writes ci_red == 0 and
#       review_rounds == 0 (the ${...:-0} defaults);
#   (4) the test exits 0 and calls ac_pass.
#
# Hermetic: no network, no forge, no agent. pr_walk_to_merge is extracted from
# lib/pr-lifecycle.sh and close_dev_tape_outcome from dev/dev-agent.sh; the
# walk's forge-facing calls (pr_poll_ci, pr_poll_review, agent_run, pr_merge,
# the CI-diagnostics helpers) are stubbed. The same extract-and-stub approach
# as the other tape tests.
#
# Acceptance: `bash tests/acceptance/issue-1616.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq awk date flock wc
WALK_SRC="$REPO_ROOT/lib/pr-lifecycle.sh"
CLOSE_SRC="$REPO_ROOT/dev/dev-agent.sh"
ac_assert_file "$WALK_SRC" "lib/pr-lifecycle.sh is present"
ac_assert_file "$CLOSE_SRC" "dev/dev-agent.sh is present"

# --- extract the functions under test -----------------------------------------
ac_log "Extracting pr_walk_to_merge from $WALK_SRC"
FN_WALK="$(ac_extract_fn pr_walk_to_merge "$WALK_SRC")"
[ -n "$FN_WALK" ] || ac_fail "pr_walk_to_merge() is not defined in lib/pr-lifecycle.sh"

ac_log "Extracting close_dev_tape_outcome from $CLOSE_SRC"
FN_CLOSE="$(ac_extract_fn close_dev_tape_outcome "$CLOSE_SRC")"
[ -n "$FN_CLOSE" ] || ac_fail "close_dev_tape_outcome() is not defined in dev-agent.sh"

# --- wiring checks -----------------------------------------------------------
# dev-agent.sh must source lib/pr-lifecycle.sh (so the walk is available),
# invoke it with the real budgets, and capture its exit into PR_WALK_RC.
grep -qE '^source .*lib/pr-lifecycle\.sh' "$CLOSE_SRC" \
  || ac_fail "dev-agent.sh must source lib/pr-lifecycle.sh"
grep -qF 'pr_walk_to_merge' "$CLOSE_SRC" \
  || ac_fail "dev-agent.sh must call pr_walk_to_merge"
# shellcheck disable=SC2016  # '$rc' is literal in the search pattern
grep -qF 'PR_WALK_RC="$rc"' "$CLOSE_SRC" \
  || ac_fail "the walk site must capture the exit into PR_WALK_RC"
grep -qF 'pr_walk_to_merge "$PR_NUMBER" "$_AGENT_SESSION_ID" "$WORKTREE" 3 5' "$CLOSE_SRC" \
  || ac_fail "the walk must be called with the 3/5 budgets"

# Walk-wide totals: initialised at walk start, incremented in the right places,
# never reset.
grep -qF 'PR_WALK_CI_RED=0' "$WALK_SRC" \
  || ac_fail "pr_walk_to_merge must initialise PR_WALK_CI_RED=0 at walk start"
grep -qF 'PR_WALK_REVIEW_ROUNDS=0' "$WALK_SRC" \
  || ac_fail "pr_walk_to_merge must initialise PR_WALK_REVIEW_ROUNDS=0 at walk start"
grep -qF 'PR_WALK_CI_RED=$((PR_WALK_CI_RED + 1))' "$WALK_SRC" \
  || ac_fail "pr_walk_to_merge must increment PR_WALK_CI_RED on every CI failure"
grep -qF 'PR_WALK_REVIEW_ROUNDS="$review_round"' "$WALK_SRC" \
  || ac_fail "pr_walk_to_merge must track PR_WALK_REVIEW_ROUNDS per review round"

# close_dev_tape_outcome must surface both totals (with 0 defaults) and keep
# the duration_s logic.
grep -qF '"${PR_WALK_CI_RED:-0}"' "$CLOSE_SRC" \
  || ac_fail "close_dev_tape_outcome must use \${PR_WALK_CI_RED:-0}"
grep -qF '"${PR_WALK_REVIEW_ROUNDS:-0}"' "$CLOSE_SRC" \
  || ac_fail "close_dev_tape_outcome must use \${PR_WALK_REVIEW_ROUNDS:-0}"
grep -qF 'duration_s' "$CLOSE_SRC" \
  || ac_fail "close_dev_tape_outcome must still carry duration_s"

# Define the functions once in the parent; every scenario subshell inherits them.
# The extracted bodies are stored verbatim — PRIMARY_BRANCH et cetera expand at
# call time, not here.
# shellcheck disable=SC2086
eval "$FN_WALK"
# shellcheck disable=SC2086
eval "$FN_CLOSE"

# --- runtime setup -----------------------------------------------------------
TMP_DIR="$(mktemp -d /tmp/acceptance-1616.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
WORKTREE="$TMP_DIR/worktree"
mkdir -p "$WORKTREE"

export PRIMARY_BRANCH=main
PROJECT_NAME="acceptance-1616"
ISSUE_TEST=1616
export PROJECT_NAME
# The id/started files live in /tmp (not TMP_DIR) to match the real layout;
# the EXIT trap removes them explicitly.
ID_FILE="/tmp/dev-proposal-id-${PROJECT_NAME}-${ISSUE_TEST}"
STARTED_FILE="/tmp/dev-proposal-started-${PROJECT_NAME}-${ISSUE_TEST}"
# shellcheck disable=SC2012  # rm in the trap uses these at exit
trap 'rm -rf "$TMP_DIR"; rm -f "$ID_FILE" "$STARTED_FILE"' EXIT

# --- hermetic stubs (inherited by every scenario subshell) -------------------
# log / _prl_log: the walk and the outcome writer both call these for logging.
# No-op so subshell stdout stays clean (only our explicit result line is
# emitted); real logging is not under test here.
log() { :; }
_prl_log() { :; }

# agent_run: a no-op success. The walk only observes rc (0 = keep going).
agent_run() { :; }

# pr_merge: a no-op success -> the walk takes the merged path (rc 0).
pr_merge() { return 0; }

# pr_poll_ci: emit code failures CI_FAILS times (rc 1), then green (rc 0).
# _PR_CI_PIPELINE is kept empty so the walk never reaches the diagnostics
# helpers (they are stubbed below regardless). _PR_CI_FAILURE_TYPE=code (not
# "infra") keeps the walk off the infra-retry path.
pr_poll_ci() {
  local n
  n="${CI_FAILS:-0}"
  if [ "$n" -gt 0 ]; then
    CI_FAILS=$((n - 1))
    _PR_CI_STATE="failure"
    _PR_CI_FAILURE_TYPE="code"
    _PR_CI_PIPELINE=""
    _PR_CI_ERROR_LOG="stubbed code failure"
    return 1
  fi
  _PR_CI_STATE="success"
  _PR_CI_FAILURE_TYPE=""
  _PR_CI_PIPELINE=""
  return 0
}

# pr_poll_review: emit REQUEST_CHANGES REV_ROUNDS times (rc 0), then APPROVE
# (rc 0). rc 1/2 are never produced, so the walk exits only via APPROVE +
# pr_merge — matching the "one review round, then merge" scenario.
pr_poll_review() {
  local n
  n="${REV_ROUNDS:-0}"
  if [ "$n" -gt 0 ]; then
    REV_ROUNDS=$((n - 1))
    _PR_REVIEW_VERDICT="REQUEST_CHANGES"
    _PR_REVIEW_TEXT="stubbed review feedback"
    return 0
  fi
  _PR_REVIEW_VERDICT="APPROVE"
  return 0
}

# CI-diagnostics helpers: not reached on the stubbed path (empty pipeline
# short-circuits them); stubbed defensively in case a trace varies.
woodpecker_api() { printf '{}\n'; }
ci_failed_logs() { :; }
ci_get_logs() { :; }

# signature_for: only invoked by close_dev_tape_outcome when the reason is
# non-empty (never, in the two outcome scenarios here). Stub to empty so a
# resolved signature would be inert either way.
signature_for() { printf '\n'; }

# --- tape-read helpers (JSONL, not a jq array) --------------------------------
count_outcomes() {
  local f="$1/tape.jsonl"
  if [ -f "$f" ]; then
    jq -c 'select(.type == "outcome")' "$f" 2>/dev/null | wc -l
  else
    echo 0
  fi
}

# $1 TAPE_DIR   $2 jq path (e.g. .numbers.ci_red)
first_outcome() {
  local f="$1/tape.jsonl" p="$2"
  if [ -f "$f" ]; then
    jq -r "select(.type == \"outcome\") | $p" "$f" 2>/dev/null | head -n1
  fi
}

# --- scenario 1: walk totals -------------------------------------------------
ac_log "scenario 1: walk with one CI failure + one review round + merge"
WORKTREE_OUT="$TMP_DIR/scen1.rc"
rm -f "$WORKTREE_OUT"
rc=0
(
  export PRIMARY_BRANCH=main
  CI_FAILS=1
  REV_ROUNDS=1
  # Defensive inits so the stubbed walk never hits an unbound global.
  _PR_WALK_EXIT_REASON=""
  _PR_CI_FAILURE_TYPE=""
  _PR_CI_PIPELINE=""
  if pr_walk_to_merge 55 55 "$WORKTREE" 3 5; then
    walk_rc=0
  else
    walk_rc=$?
  fi
  printf 'rc=%s ci_red=%s review_rounds=%s\n' \
    "$walk_rc" "${PR_WALK_CI_RED:-unset}" "${PR_WALK_REVIEW_ROUNDS:-unset}" > "$WORKTREE_OUT"
) >>"$TMP_DIR/scen1.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ac_fail "walk subshell crashed (see $TMP_DIR/scen1.log):
$(cat "$TMP_DIR/scen1.log" 2>/dev/null)"
fi
out="$(cat "$WORKTREE_OUT" 2>/dev/null)"
ac_assert_eq "$out" "rc=0 ci_red=1 review_rounds=1" "walk totals (got: $out)"

# --- scenario 2: close_dev_tape_outcome after the walk ----------------------
ac_log "scenario 2: outcome after a walk -> ci_red=1, review_rounds=1"
TAPE_2="$TMP_DIR/tape2"
mkdir -p "$TAPE_2"
now2=$(( $(date -u +%s) - 5 ))
printf 'acceptance-proposal-1616' > "$ID_FILE"
printf '%s\n' "$now2" > "$STARTED_FILE"
rc=0
(
  export PRIMARY_BRANCH=main
  export TAPE_DIR="$TAPE_2"
  export PROJECT_NAME="$PROJECT_NAME"
  export ISSUE="$ISSUE_TEST"
  export LOGFILE="$TMP_DIR/tape2.log"
  CI_FAILS=1
  REV_ROUNDS=1
  _PR_WALK_EXIT_REASON=""
  _PR_CI_FAILURE_TYPE=""
  _PR_CI_PIPELINE=""
  # shellcheck source=../../lib/tape.sh
  source "$REPO_ROOT/lib/tape.sh"
  if pr_walk_to_merge 55 55 "$WORKTREE" 3 5; then
    walk_rc=0
  else
    walk_rc=$?
  fi
  PR_WALK_RC="$walk_rc"
  close_dev_tape_outcome
) >>"$TMP_DIR/tape2.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ac_fail "scenario-2 subshell crashed (see $TMP_DIR/tape2.log):
$(cat "$TMP_DIR/tape2.log" 2>/dev/null)"
fi
ac_assert_eq "$(count_outcomes "$TAPE_2")" "1" "exactly one outcome (got: $(cat "$TAPE_2/tape.jsonl" 2>/dev/null))"
ac_assert_eq "$(first_outcome "$TAPE_2" .numbers.ci_red)" "1" "numbers.ci_red == 1 (got: $(cat "$TAPE_2/tape.jsonl" 2>/dev/null))"
ac_assert_eq "$(first_outcome "$TAPE_2" .numbers.review_rounds)" "1" "numbers.review_rounds == 1 (got: $(cat "$TAPE_2/tape.jsonl" 2>/dev/null))"
ac_assert_eq "$(first_outcome "$TAPE_2" .bits.merged)" "1" "bits.merged == 1 (walk merged)"
ac_assert_eq "$(first_outcome "$TAPE_2" .bits.ci_green)" "1" "bits.ci_green == 1"

# --- scenario 3: no walk (early exit) -> 0/0 ---------------------------------
ac_log "scenario 3: no walk ran (early exit) -> ci_red=0, review_rounds=0"
TAPE_3="$TMP_DIR/tape3"
mkdir -p "$TAPE_3"
printf 'acceptance-proposal-1616-early' > "$ID_FILE"
printf '%s\n' "$now2" > "$STARTED_FILE"
rc=0
(
  export PRIMARY_BRANCH=main
  export TAPE_DIR="$TAPE_3"
  export PROJECT_NAME="$PROJECT_NAME"
  export ISSUE="$ISSUE_TEST"
  export LOGFILE="$TMP_DIR/tape3.log"
  # shellcheck source=../../lib/tape.sh
  source "$REPO_ROOT/lib/tape.sh"
  # Simulated early-exit: a failure walk with no recorded refusal, and
  # PR_WALK_CI_RED / PR_WALK_REVIEW_ROUNDS intentionally left unset so the
  # ${...:-0} defaults yield 0.
  # shellcheck disable=SC2034  # consumed by inherited close_dev_tape_outcome()
  PR_WALK_RC=1
  _PR_WALK_EXIT_REASON="ci_exhausted"
  close_dev_tape_outcome
) >>"$TMP_DIR/tape3.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ac_fail "scenario-3 subshell crashed (see $TMP_DIR/tape3.log):
$(cat "$TMP_DIR/tape3.log" 2>/dev/null)"
fi
ac_assert_eq "$(count_outcomes "$TAPE_3")" "1" "exactly one outcome (got: $(cat "$TAPE_3/tape.jsonl" 2>/dev/null))"
ac_assert_eq "$(first_outcome "$TAPE_3" .numbers.ci_red)" "0" "no-walk ci_red == 0 (got: $(cat "$TAPE_3/tape.jsonl" 2>/dev/null))"
ac_assert_eq "$(first_outcome "$TAPE_3" .numbers.review_rounds)" "0" "no-walk review_rounds == 0 (got: $(cat "$TAPE_3/tape.jsonl" 2>/dev/null))"
ac_assert_eq "$(first_outcome "$TAPE_3" .bits.merged)" "0" "bits.merged == 0 (failure walk)"

ac_pass "issue #1616: dev outcomes carry CI-red and review-round totals"
