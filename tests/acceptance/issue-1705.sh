#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1705.sh
#
# Issue #1705: pr_walk_to_merge() exits ci_timeout when CI is still pending
# after the CI-wait budget runs out (30m, raised to 60m by #1695). dev-agent.sh
# then treated that non-zero exit as a terminal failure: issue_block + a
# "blocked_ci_timeout" tape outcome, even though the PR was still open and CI
# was still running — the issue got wrongly blocked and released.
#
# Fix (no-network, hermetic contract):
#   * dev-agent.sh: new dev_walk_reason_terminal REASON (1 iff REASON is
#     ci_timeout, 0 for any other reason incl. empty). The walk-failure branch
#     calls issue_block and records blocked_<reason> only when the reason is
#     terminal; for ci_timeout it leaves the issue in-progress and assigned,
#     records journal "waiting_ci", and the EXIT-trap close_dev_tape_outcome
#     skips the tape outcome. Worktree/session cleanup is unchanged.
#   * dev-poll.sh: the in-progress check now also probes the PR's CI and, when it
#     failed, spawns a CI fix (via handle_ci_exhaustion) before blocking.
#
# Acceptance: `bash tests/acceptance/issue-1705.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../../tests/lib/acceptance-tape-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-tape-helpers.sh"

ac_require_cmd bash jq awk date
TARGET_AGENT="$REPO_ROOT/dev/dev-agent.sh"
TARGET_POLL="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$TARGET_AGENT" "dev-agent.sh is present"
ac_assert_file "$TARGET_POLL" "dev-poll.sh is present"

# --- extract the functions under test ------------------------------------------
ac_log "Extracting dev_walk_reason_terminal from $TARGET_AGENT"
FN_REASON="$(ac_extract_fn dev_walk_reason_terminal "$TARGET_AGENT")"
[ -n "$FN_REASON" ] || ac_fail "dev_walk_reason_terminal() is not defined in dev-agent.sh"
ac_log "Extracting close_dev_tape_outcome from $TARGET_AGENT"
FN_CLOSE="$(ac_extract_fn close_dev_tape_outcome "$TARGET_AGENT")"
[ -n "$FN_CLOSE" ] || ac_fail "close_dev_tape_outcome() is not defined in dev-agent.sh"

# Define both once in the parent; every scenario subshell inherits them.
# The parent stubs the helpers close_dev_tape_outcome may invoke (log,
# signature_for); the subshells keep them and add the real lib/tape.sh.
# shellcheck disable=SC2086
eval "$FN_REASON"
# shellcheck disable=SC2086
eval "$FN_CLOSE"

# --- wiring: walk-failure branch ------------------------------------------------
# The issue_block call must be gated by the dev_walk_reason_terminal guard, and
# the ci_timeout (waiting_ci) path must not block or release the issue.
ac_log "wiring: walk-failure branch gates issue_block on dev_walk_reason_terminal"
branch_file="$(mktemp)"
awk '/# Exhausted or unrecoverable failure/,/^fi$/' "$TARGET_AGENT" > "$branch_file"
if [ ! -s "$branch_file" ]; then
  rm -f "$branch_file"
  ac_fail "could not find the walk-failure branch in dev-agent.sh"
fi
# The guard must exist and must precede the issue_block call (i.e. the block
# lives inside the guard).
guard_ln="$(grep -nF 'if dev_walk_reason_terminal' "$branch_file" | head -n1 | cut -d: -f1)"
block_ln="$(grep -nF 'issue_block' "$branch_file" | head -n1 | cut -d: -f1)"
rm -f "$branch_file"
[ -n "$guard_ln" ] || ac_fail "walk-failure branch must contain the dev_walk_reason_terminal guard"
[ -n "$block_ln" ] || ac_fail "walk-failure branch must call issue_block"
if (( guard_ln < block_ln )); then
  ac_log "  -> guard (line $guard_ln) precedes issue_block (line $block_ln) OK"
else
  ac_fail "the dev_walk_reason_terminal guard (line $guard_ln) must precede issue_block (line $block_ln) in the walk-failure branch"
fi

grep -qF 'waiting_ci' "$TARGET_AGENT" \
  || ac_fail "walk-failure branch must record a waiting_ci journal outcome for ci_timeout"

# The ci_timeout path must log that CI is still running and leave the issue for
# dev-poll — it must NOT release it (no issue_release in that path).
awk '/# Exhausted or unrecoverable failure/,/^fi$/' "$TARGET_AGENT" \
  | grep -qF 'CI still running on PR' \
    || ac_fail "ci_timeout path must log 'CI still running on PR'"
awk '/# Exhausted or unrecoverable failure/,/^fi$/' "$TARGET_AGENT" \
  | { grep -qF 'issue_release' && { echo "ci path must not release the issue"; exit 1; }
      exit 0; } || ac_fail "ci_timeout path must not release the issue"

# --- wiring: dev-poll in-progress check ----------------------------------------
ac_log "wiring: dev-poll in-progress check spawns a CI fix on a failed CI"
grep -qF 'IP_CI_STATE=$(ci_commit_status' "$TARGET_POLL" \
  || ac_fail "in-progress check must probe the PR's CI state (ci_commit_status)"
grep -qF 'elif ci_failed' "$TARGET_POLL" \
  || ac_fail "in-progress check must branch on a failed CI (elif ci_failed)"
grep -qF 'handle_ci_exhaustion "$HAS_PR" "$ISSUE_NUM"' "$TARGET_POLL" \
  || ac_fail "in-progress CI-failed branch must route through handle_ci_exhaustion"
grep -qF 'started dev-agent PID $! for issue #${ISSUE_NUM} (CI fix)' "$TARGET_POLL" \
  || ac_fail "in-progress CI-failed branch must spawn the (CI fix) dev-agent"

# --- runtime setup -----------------------------------------------------------
TMP_DIR="$(mktemp -d /tmp/acceptance-1705.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_NAME="acceptance-1705"
ISSUE_TEST=1705
export PROJECT_NAME

ID_FILE="/tmp/dev-proposal-id-${PROJECT_NAME}-${ISSUE_TEST}"
STARTED_FILE="/tmp/dev-proposal-started-${PROJECT_NAME}-${ISSUE_TEST}"

# Run close_dev_tape_outcome in a fresh subshell via the shared tape-helpers
# runner. $1 TAPE_DIR  $2 PR_WALK_RC (0 merged, 1 not)  $3 walk reason (or ""
# for none). Single call against a hermetic TAPE_DIR; the runner no-ops log()
# / signature_for() in the subshell, so the ci_exhausted outcome is written
# signature-free.
run_close() {
  ac_run_close_subshell "$1" "$2" "${3:-}" 1
}

# --- AC 1: ci_timeout is not terminal; everything else is --------------------
ac_log "AC 1: dev_walk_reason_terminal — ci_timeout fails, others succeed"
# In a condition context, `! fn arg` is true only when fn returns non-zero (1).
if ! dev_walk_reason_terminal "ci_timeout"; then
  ac_log "  -> ci_timeout is non-terminal (returns 1) OK"
else
  ac_fail "dev_walk_reason_terminal 'ci_timeout' must return 1 (non-terminal)"
fi
for r in ci_exhausted review_exhausted "ci_failure" ""; do
  if ! dev_walk_reason_terminal "$r"; then
    ac_fail "dev_walk_reason_terminal '$r' must return 0 (terminal)"
  fi
done
ac_log "AC 1 OK"

# --- AC 2: ci_timeout -> no tape outcome --------------------------------------
ac_log "AC 2: close_dev_tape_outcome with PR_WALK_RC=1 + ci_timeout appends no outcome"
printf 'dev-proposal-A-1705' > "$ID_FILE"
nowA=$(( $(date -u +%s) - 5 ))
printf '%s\n' "$nowA" > "$STARTED_FILE"
TAPE_A="$TMP_DIR/tapeA"
mkdir -p "$TAPE_A"
rc=0
out="$(run_close "$TAPE_A" 1 ci_timeout)" || rc=$?
rm -f "$ID_FILE" "$STARTED_FILE"
ac_assert_eq "$rc" "0" "ci_timeout outcome must succeed (rc=$rc): $out"
ac_assert_eq "$(count_outcomes "$TAPE_A")" "0" "no outcome for ci_timeout (got $(count_outcomes "$TAPE_A")): $out"
ac_log "AC 2 OK"

# --- AC 3: ci_exhausted -> one tape outcome (as today) ------------------------
ac_log "AC 3: close_dev_tape_outcome with PR_WALK_RC=1 + ci_exhausted appends one outcome"
printf 'dev-proposal-B-1705' > "$ID_FILE"
printf '%s\n' "$nowA" > "$STARTED_FILE"
TAPE_B="$TMP_DIR/tapeB"
mkdir -p "$TAPE_B"
rc=0
out="$(run_close "$TAPE_B" 1 ci_exhausted)" || rc=$?
rm -f "$ID_FILE" "$STARTED_FILE"
ac_assert_eq "$rc" "0" "ci_exhausted outcome must succeed (rc=$rc): $out"
ac_assert_eq "$(count_outcomes "$TAPE_B")" "1" "one outcome for ci_exhausted (as today): $out"
ac_assert_eq "$(first_outcome "$TAPE_B" .bits.merged)" "0" "ci_exhausted: merged is 0"
ac_assert_eq "$(first_outcome "$TAPE_B" .bits.ci_green)" "0" "ci_exhausted: ci_green is 0"
ac_log "AC 3 OK"

ac_pass "issue #1705: a CI-wait timeout leaves the issue in progress, not blocked"
