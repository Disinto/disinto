#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1399.sh
#
# Issue #1399: when a dev PR reaches terminal state, dev-poll appends one
# outcome record to the tape (lib/tape.sh) keyed off the proposal id written
# by the #1398 pick:
#
#   tape_outcome <proposal id> '{"merged":0|1,"ci_green":0|1}' \
#     '{"review_rounds":<n>}' '{}' '[]'
#
# review_rounds = the PR's REQUEST_CHANGES review count from one forge call.
# No proposal id file (issue predates the proposal step) → skip silently.
# Tape failure → warning, continue.
#
# Acceptance (read-only — no live services, no agents started, no pick
# triggered; the emitter is exercised in-process with a stub curl, the same
# extract-and-stub approach as issue-1398):
#   1. wiring — the merge handling paths (pre-lock, in-progress, backlog)
#      emit an outcome for merged PRs and the stale-branch abandonment paths
#      emit one for closed PRs
#   2. the issue's acceptance criterion — merging a dev PR appends exactly
#      one {"type":"outcome",...} line whose proposal_id matches the id
#      written by the proposal step, with bits={"merged":1,"ci_green":1},
#      numbers={"review_rounds":<n>} (n = REQUEST_CHANGES count from the
#      stubbed reviews), children={}, payloads=[]
#   3. a closed (not merged) PR records bits={"merged":0,"ci_green":0}
#   4. no id file (issue predates the proposal step) → rc 0, no record, no
#      output (silent skip)
#   5. a forge API failure degrades review_rounds to 0 and still appends
#   6. an unwritable $TAPE_DIR logs a warning and returns 0
#
# The stub curl (ac_write_curl_stub, tests/lib/acceptance-helpers.sh) stands
# in for the forge; AC_STUB_FAIL=1 makes it fail like an unreachable API.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd jq

TARGET="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$TARGET" "dev/dev-poll.sh must exist"

# ── 1. Wiring: the merge/close handling paths emit the outcome ─────────────
# Merged PRs (all three direct-merge paths, CI green by construction):
grep -q 'emit_tape_outcome "\$PL_ISSUE" "\$PL_PR_NUM" 1 1' "$TARGET" \
  || ac_fail "dev-poll.sh must emit an outcome when the pre-lock scan merges a PR"
grep -q 'emit_tape_outcome "\$ISSUE_NUM" "\$HAS_PR" 1 1' "$TARGET" \
  || ac_fail "dev-poll.sh must emit an outcome when the in-progress scan merges a PR"
grep -q 'emit_tape_outcome "\$ISSUE_NUM" "\$EXISTING_PR" 1 1' "$TARGET" \
  || ac_fail "dev-poll.sh must emit an outcome when the backlog scan merges a PR"
# Closed PRs (stale-branch abandonment in both scans):
grep -q 'emit_tape_outcome "\$ISSUE_NUM" "\$HAS_PR" 0 0' "$TARGET" \
  || ac_fail "dev-poll.sh must emit an outcome when a stale PR is closed (in-progress scan)"
grep -q 'emit_tape_outcome "\$ISSUE_NUM" "\$EXISTING_PR" 0 0' "$TARGET" \
  || ac_fail "dev-poll.sh must emit an outcome when a stale PR is closed (backlog scan)"

FN_OUT="$(ac_extract_fn emit_tape_outcome "$TARGET")"
[ -n "$FN_OUT" ] || ac_fail "could not extract emit_tape_outcome() from dev-poll.sh"
FN_PROP="$(ac_extract_fn emit_tape_proposal "$TARGET")"
[ -n "$FN_PROP" ] || ac_fail "could not extract emit_tape_proposal() from dev-poll.sh"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-1399"   # sentinel — can never clobber a live id file
trap 'rm -rf "$TMP_DIR" \
  /tmp/dev-proposal-id-acceptance-1399-1399 \
  /tmp/dev-proposal-id-acceptance-1399-9995 \
  /tmp/dev-proposal-id-acceptance-1399-9996 \
  /tmp/dev-proposal-id-acceptance-1399-9998' EXIT

# ── Stub curl: hermetic forge stand-in (no network, no live services) ───────
# ac_write_curl_stub writes a fake forge curl: */issues/* answers a labelled
# issue, */pulls?state=open* answers 3 open PRs, */pulls/*/reviews answers 4
# reviews (2 REQUEST_CHANGES); AC_STUB_FAIL=1 makes it fail like an
# unreachable API.
STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
ac_write_curl_stub "$STUB_BIN"

# The extracted emitters log through log(); the subshells inherit this
# stand-in so those lines land in the runner's captured output.
log() { echo "poll: $*"; }

# run_proposal <TAPE_DIR> <issue> — run the extracted #1398 emitter in an
# isolated subshell so the outcome can be keyed off the id it writes (the
# issue's acceptance criterion).
run_proposal() {
  local tape_dir="$1" issue="$2"
  (
    ac_stub_env "$STUB_BIN" "$tape_dir"
    # shellcheck disable=SC1091  # path only known at runtime
    source "$REPO_ROOT/lib/tape.sh"
    eval "$FN_PROP"
    emit_tape_proposal "$issue"
  ) 2>&1
}

# run_outcome <TAPE_DIR> <issue> <pr> <merged> <ci_green> [fail] — run the
# extracted function in an isolated subshell (stub curl on PATH, real
# lib/tape.sh, sentinel PROJECT_NAME, caller's TAPE_DIR) and capture its
# output; the exit status is the function's.
run_outcome() {
  local tape_dir="$1" issue="$2" pr="$3" merged="$4" ci_green="$5" fail="${6:-0}"
  (
    ac_stub_env "$STUB_BIN" "$tape_dir"
    # shellcheck disable=SC1091  # path only known at runtime
    source "$REPO_ROOT/lib/tape.sh"
    eval "$FN_OUT"
    if [ "$fail" = "1" ]; then
      export AC_STUB_FAIL=1
    fi
    emit_tape_outcome "$issue" "$pr" "$merged" "$ci_green"
  ) 2>&1
}

# ── 2. Acceptance criterion: merged PR → one outcome line keyed off the ────
# ── proposal step's id ─────────────────────────────────────────────────────
TAPE1="$TMP_DIR/tape-happy"
rc=0
out="$(run_proposal "$TAPE1" 1399)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_proposal must return 0 on success (got $rc): $out"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "1" "proposal step must append exactly one line"
ID_FILE="/tmp/dev-proposal-id-${PROJECT_NAME}-1399"
[ -f "$ID_FILE" ] || ac_fail "id file $ID_FILE missing after a successful pick"
PROP_ID="$(jq -r '.id' <(head -n 1 "$TAPE1/tape.jsonl"))"
ac_assert_eq "$(cat "$ID_FILE")" "$PROP_ID" \
  "the project-scoped id file must contain exactly the recorded proposal id"

rc=0
out="$(run_outcome "$TAPE1" 1399 42 1 1)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_outcome must return 0 on success (got $rc): $out"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "2" \
  "merging a dev PR must append exactly one outcome line to the proposal line"
LINE="$(sed -n 2p "$TAPE1/tape.jsonl")"
ac_assert_jq ".type == \"outcome\" and .proposal_id == \"${PROP_ID}\" and .bits == {\"merged\":1,\"ci_green\":1} and .numbers == {\"review_rounds\":2} and .children == {} and .payloads == []" \
  "$LINE" \
  "the outcome line's proposal must match the id written by the proposal step, with merged/ci_green bits and the REQUEST_CHANGES review count"

# ── 3. Closed (not merged) PR: bits record the close ────────────────────────
TAPE2="$TMP_DIR/tape-close"
printf '%s' "pid-close-9998" > "/tmp/dev-proposal-id-${PROJECT_NAME}-9998"
rc=0
out="$(run_outcome "$TAPE2" 9998 43 0 0)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_outcome must return 0 for a closed PR (got $rc): $out"
ac_assert_eq "$(wc -l < "$TAPE2/tape.jsonl")" "1" "a closed PR must append exactly one outcome line"
LINE="$(head -n 1 "$TAPE2/tape.jsonl")"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-close-9998" and .bits == {"merged":0,"ci_green":0} and .numbers == {"review_rounds":2} and .children == {} and .payloads == []' \
  "$LINE" \
  "a closed PR must record bits={merged:0,ci_green:0} keyed off its proposal id"

# ── 4. No id file (issue predates the proposal step): silent skip ───────────
TAPE3="$TMP_DIR/tape-silent"
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-9997"
rc=0
out="$(run_outcome "$TAPE3" 9997 44 1 1)" || rc=$?
ac_assert_eq "$rc" "0" "a missing id file must not fail the terminal-state handling (got $rc): $out"
[ -z "$out" ] || ac_fail "the skip without an id file must be silent, got: $out"
[ ! -f "$TAPE3/tape.jsonl" ] \
  || ac_fail "no outcome record may be appended when no proposal id file exists"

# ── 5. Forge API failure: review_rounds degrades to 0, record still appended ─
TAPE4="$TMP_DIR/tape-apifail"
printf '%s' "pid-fail-9996" > "/tmp/dev-proposal-id-${PROJECT_NAME}-9996"
rc=0
out="$(run_outcome "$TAPE4" 9996 45 1 1 1)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_outcome must return 0 when the forge API fails (got $rc): $out"
LINE="$(head -n 1 "$TAPE4/tape.jsonl" 2>/dev/null || true)"
[ -n "$LINE" ] || ac_fail "a record must still be appended when the reviews call fails"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-fail-9996" and .numbers == {"review_rounds":0} and .bits == {"merged":1,"ci_green":1}' \
  "$LINE" \
  "a failed reviews call must degrade review_rounds to 0 while still appending the record"

# ── 6. Unwritable TAPE_DIR: warning, rc 0, no record ────────────────────────
# A regular file as the tape dir's parent can never be created into — for
# any user, root included — so the tape writer's mkdir fails deterministically.
touch "$TMP_DIR/blocker"
TAPE5="$TMP_DIR/blocker/tape"
printf '%s' "pid-block-9995" > "/tmp/dev-proposal-id-${PROJECT_NAME}-9995"
rc=0
out="$(run_outcome "$TAPE5" 9995 46 1 1)" || rc=$?
ac_assert_eq "$rc" "0" "an unwritable TAPE_DIR must not fail the terminal-state handling (got $rc): $out"
case "$out" in
  *"tape: failed to append outcome"*) ;;
  *) ac_fail "unwritable TAPE_DIR must log a tape warning, got: $out" ;;
esac
[ ! -f "$TAPE5/tape.jsonl" ] \
  || ac_fail "no outcome record may be written when TAPE_DIR is unwritable"

ac_pass
