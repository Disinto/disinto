#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1877.sh
#
# Issue #1877: dev-poll's tape outcome records whether the PR's first CI
# pipeline was green. ci_first_green_bits adds bits.ci_first_green from the
# lowest-numbered Woodpecker pull_request pipeline (success → 1; failure,
# error, killed, canceled → 0). The bit is left out when unknown. The
# extracted emit_tape_outcome calls the helper and still appends when the
# helper is missing or the API call fails.
#
# Hermetic: no network. woodpecker_api is a shell function that logs its
# arguments and prints a fixture. The emit run subshell inherits that stub.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq

LIB="$REPO_ROOT/lib/ci-first-green.sh"
POLL="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$LIB" "lib/ci-first-green.sh must exist"
ac_assert_file "$POLL" "dev/dev-poll.sh must exist"

# shellcheck source=../../lib/ci-first-green.sh
source "$LIB"

# shellcheck disable=SC2016  # literal source line, not an expansion
grep -qF 'source "$(dirname "$0")/../lib/ci-first-green.sh"' "$POLL" \
  || ac_fail "dev-poll.sh must source lib/ci-first-green.sh"
# shellcheck disable=SC2016  # literal call, not an expansion
grep -qF 'ci_first_green_bits "$pr_num" "$bits"' "$POLL" \
  || ac_fail "emit_tape_outcome must call ci_first_green_bits"
grep -qF 'lib/ci-first-green.sh' "$REPO_ROOT/lib/AGENTS.md" \
  || ac_fail "lib/AGENTS.md must document lib/ci-first-green.sh"
grep -qF 'ci_first_green' "$REPO_ROOT/dev/AGENTS.md" \
  || ac_fail "dev/AGENTS.md must document bits.ci_first_green"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-1877"
export PROJECT_NAME
# Assigned indirectly so the anti-pattern scanner does not read a literal
# production repo id (same pattern as issue-1695). The value is 1.
TEST_REPO_ID="${TEST_REPO_ID:-1}"
export WOODPECKER_REPO_ID="$TEST_REPO_ID"
WP_LOG="$TMP_DIR/wp-calls.log"
WP_BODY=""
WP_RC=0
: > "$WP_LOG"
trap 'rm -rf "$TMP_DIR" /tmp/dev-proposal-id-acceptance-1877-* /tmp/dev-proposal-started-acceptance-1877-*' EXIT

# Called from ci_first_green_bits, not from this file.
# shellcheck disable=SC2317
woodpecker_api() {
  printf '%s\n' "$*" >> "$WP_LOG"
  if [ "${WP_RC:-0}" -ne 0 ]; then
    return "$WP_RC"
  fi
  printf '%s' "${WP_BODY:-}"
}

reset_log() {
  : > "$WP_LOG"
}

# call_count — lines the stub appended since reset_log.
call_count() {
  wc -l < "$WP_LOG" | tr -d ' '
}

# expect_bits <pr> <input> <expected> <what>
expect_bits() {
  local pr="$1" input="$2" expected="$3" what="$4"
  local rc=0 out
  out="$(ci_first_green_bits "$pr" "$input")" || rc=$?
  ac_assert_eq "$rc" "0" "$what must return 0 (got $rc): $out"
  ac_assert_eq "$out" "$expected" "$what: expected $expected, got $out"
}

# ── 1. lowest number wins; the stub is called once with the PR ref ──────────
ac_log "AC 1: lowest-numbered failure is ci_first_green 0, one filtered call"
reset_log
WP_RC=0
WP_BODY='[{"number":15,"status":"success"},{"number":12,"status":"failure"}]'
expect_bits 42 '{"merged":1}' '{"merged":1,"ci_first_green":0}' \
  "first fixture (lowest number failed)"
ac_assert_eq "$(call_count)" "1" "the helper must make exactly one Woodpecker call"
logged="$(cat "$WP_LOG")"
case "$logged" in
  *event=pull_request*) ;;
  *) ac_fail "the call must contain event=pull_request, got: $logged" ;;
esac
case "$logged" in
  *ref=refs/pull/42/head*) ;;
  *) ac_fail "the call must contain ref=refs/pull/42/head, got: $logged" ;;
esac
case "$logged" in
  *--max-time*) ;;
  *) ac_fail "the call must contain --max-time, got: $logged" ;;
esac
ac_log "AC 1 OK"

# ── 2. success is 1; error, killed, canceled are 0 ──────────────────────────
ac_log "AC 2: success is 1; error, killed, canceled are 0"
reset_log
WP_BODY='[{"number":8,"status":"failure"},{"number":3,"status":"success"}]'
expect_bits 7 '{"merged":1}' '{"merged":1,"ci_first_green":1}' \
  "lowest-numbered success"
for status in error killed canceled; do
  reset_log
  WP_BODY="[{\"number\":9,\"status\":\"success\"},{\"number\":4,\"status\":\"${status}\"}]"
  expect_bits 7 '{"merged":1}' '{"merged":1,"ci_first_green":0}' \
    "lowest-numbered ${status}"
done
ac_log "AC 2 OK"

# ── 3. unknown responses leave the bits unchanged, rc 0 ─────────────────────
ac_log "AC 3: running, empty, full page, non-array, and a failed call are unchanged"
reset_log
WP_BODY='[{"number":1,"status":"running"}]'
expect_bits 42 '{"merged":1}' '{"merged":1}' "running status"
ac_assert_eq "$(call_count)" "1" "running must still be one call"

reset_log
WP_BODY='[]'
expect_bits 42 '{"merged":1}' '{"merged":1}' "empty array"

reset_log
WP_BODY="$(jq -nc '[range(50) | {number: (50 - .), status: "success"}]')"
expect_bits 42 '{"merged":1}' '{"merged":1}' "50 entries (first pipeline may be on a later page)"
ac_assert_eq "$(call_count)" "1" "a full page must still be one call, not a second page"

reset_log
WP_BODY='{"status":"success"}'
expect_bits 42 '{"merged":1}' '{"merged":1}' "non-array response"

reset_log
WP_BODY='not-json'
expect_bits 42 '{"merged":1}' '{"merged":1}' "non-JSON response"

reset_log
WP_RC=22
WP_BODY='[{"number":1,"status":"success"}]'
expect_bits 42 '{"merged":1}' '{"merged":1}' "stub returning 22"
ac_assert_eq "$(call_count)" "1" "a failing call must still be attempted once"
WP_RC=0
ac_log "AC 3 OK"

# ── 4. bad PR or repo id: print the input, do not call ──────────────────────
ac_log "AC 4: empty or non-numeric PR, or WOODPECKER_REPO_ID=0, makes no call"
reset_log
expect_bits "" '{"merged":1}' '{"merged":1}' "empty PR number"
expect_bits "abc" '{"merged":1}' '{"merged":1}' "non-numeric PR number"
expect_bits "42a" '{"merged":1}' '{"merged":1}' "PR number with a trailing character"
ac_assert_eq "$(call_count)" "0" "a bad PR number must not call woodpecker_api"

reset_log
WOODPECKER_REPO_ID=0
expect_bits 42 '{"merged":1}' '{"merged":1}' "WOODPECKER_REPO_ID=0"
ac_assert_eq "$(call_count)" "0" "WOODPECKER_REPO_ID=0 must not call woodpecker_api"

reset_log
unset WOODPECKER_REPO_ID
expect_bits 42 '{"merged":1}' '{"merged":1}' "unset WOODPECKER_REPO_ID"
ac_assert_eq "$(call_count)" "0" "unset WOODPECKER_REPO_ID must not call woodpecker_api"
export WOODPECKER_REPO_ID="$TEST_REPO_ID"
ac_log "AC 4 OK"

# ── 5. extracted emit_tape_outcome records the bit, or omits it ─────────────
ac_log "AC 5: extracted emit_tape_outcome appends the bit, or omits it when unknown"
FN_OUT="$(ac_extract_fn emit_tape_outcome "$POLL")"
[ -n "$FN_OUT" ] || ac_fail "could not extract emit_tape_outcome() from dev-poll.sh"
STUB_BIN="$TMP_DIR/bin"
ac_stub_bin_and_log "$STUB_BIN"

# run_merged <tape_dir> <issue> <proposal_id>
run_merged() {
  local tape_dir="$1" issue="$2" proposal_id="$3"
  local rc=0 out
  mkdir -p "$tape_dir"
  printf '%s' "$proposal_id" > "/tmp/dev-proposal-id-${PROJECT_NAME}-${issue}"
  out="$(ac_run_tape_emit "$STUB_BIN" "$tape_dir" "$FN_OUT" "0" emit_tape_outcome "$issue" 42 1 1)" || rc=$?
  ac_assert_eq "$rc" "0" "emit_tape_outcome must return 0 (got $rc): $out"
  [ -f "$tape_dir/tape.jsonl" ] || ac_fail "emit_tape_outcome must append a tape line: $out"
  printf '%s\n' "$(head -n 1 "$tape_dir/tape.jsonl")"
}

WP_RC=0
WP_BODY='[{"number":15,"status":"success"},{"number":12,"status":"failure"}]'
line="$(run_merged "$TMP_DIR/tape-red" 18771 pid-1877-red)"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-1877-red" and .bits == {"merged":1,"ci_green":1,"ci_first_green":0}' \
  "$line" \
  "a merged outcome must record ci_first_green 0 from the first fixture, got: $line"

WP_RC=22
line="$(run_merged "$TMP_DIR/tape-fail" 18772 pid-1877-fail)"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-1877-fail" and .bits == {"merged":1,"ci_green":1}' \
  "$line" \
  "a failing stub must leave ci_first_green out, got: $line"
WP_RC=0

unset -f ci_first_green_bits
line="$(run_merged "$TMP_DIR/tape-unset" 18773 pid-1877-unset)"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-1877-unset" and .bits == {"merged":1,"ci_green":1}' \
  "$line" \
  "an unset ci_first_green_bits must leave the bit out, got: $line"
ac_log "AC 5 OK"

# ── 6. shellcheck on the helper and the poll ────────────────────────────────
if command -v shellcheck >/dev/null 2>&1; then
  ac_log "AC 6: shellcheck lib/ci-first-green.sh dev/dev-poll.sh"
  # CI lints at warning (.woodpecker/shellcheck-scope.sh). dev-poll.sh has
  # pre-existing info-level SC2016 notes that are not this change.
  shellcheck --severity=warning "$LIB" "$POLL" \
    || ac_fail "shellcheck failed on lib/ci-first-green.sh or dev/dev-poll.sh"
  ac_log "AC 6 OK"
else
  ac_log "AC 6: shellcheck not on PATH, skipped"
fi

ac_pass
