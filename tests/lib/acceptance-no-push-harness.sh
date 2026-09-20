#!/usr/bin/env bash
# =============================================================================
# tests/lib/acceptance-no-push-harness.sh — shared harness for in-process
# no-push decision tests
#
# Sourced by acceptance tests that exercise no_push_outcome() from top-level
# executables without starting the executable (sourcing a top-level script would
# run the whole agent). The function under test is extracted with
# ac_extract_fn() + eval; this harness provides the globals the function
# would normally have, stubs the calls the function makes (issue_block,
# issue_requeue, forge_api), owns $TMP_DIR + its EXIT cleanup trap, and
# offers parameterized assertions on the recorded issue_block()/issue_requeue()
# calls.
#
# Usage (after sourcing tests/lib/acceptance-helpers.sh):
#   ac_no_push_stub
#   ac_load_decision_fn "$REPO_ROOT/dev/dev-agent.sh" no_push_outcome
#   ISSUE=<n>; NO_PUSH_TEXT="Claude did not push branch ${BRANCH}"
#   ac_assert_requeue     <diag> <rc> <attempt> <reason> <what>
#   ac_assert_block_reason <diag> <rc> <attempt> <reason> <what>
#
# Shared by tests/acceptance/issue-1164-requeue-on-resource-limit.sh and
# tests/acceptance/issue-1442.sh (both tests otherwise duplicate the stubs,
# extraction, and asserters — this file carries them once).
#
# Conventions: same as acceptance-helpers.sh — helpers are read-only apart from
# writing under $TMP_DIR, and failures go through ac_fail.
# =============================================================================

# Idempotent guard — a test that sources the harness twice (e.g. via nested
# sourcing) shouldn't redefine functions or re-run setup.
if [ -n "${AC_NO_PUSH_HARNESS_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
AC_NO_PUSH_HARNESS_LOADED=1

# Own the scratch dir + its cleanup, so tests don't re-define it and the
# duplicate detector never sees a shared TMP_DIR/trap cluster twice.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ac_no_push_stub — install the stubs no_push_outcome() would normally call:
# issue_block()/issue_requeue() record their full argument list in the
# calling test's global CALLS array; forge_api() is a no-op (defensive: the
# extracted function must not need the live API).
ac_no_push_stub() {
  CALLS=()
  issue_block()   { CALLS+=("issue_block $*"); }
  issue_requeue() { CALLS+=("issue_requeue $*"); }
  forge_api()     { :; }
}

# ac_load_decision_fn <target-sh> <fn-name> — extract <fn-name>() from
# target-sh via ac_extract_fn() (column-0 `name() {` to the next column-0
# closing brace), eval it, and fail the test if it did not become a function.
ac_load_decision_fn() {
  local target="$1" fn="$2"
  local body
  body="$(ac_extract_fn "$fn" "$target")"
  [ -n "$body" ] || ac_fail "could not locate ${fn}() in ${target}"
  eval "$body"
  type "$fn" >/dev/null 2>&1 \
    || ac_fail "${fn}() did not evaluate to a function"
}

# ac_assert_requeue <diag> <rc> <attempt> <reason> <what>
# — the extracted no_push_outcome must issue_requeue <ISSUE> <reason> ... and
# must never issue_block. Uses the calling test's globals ISSUE and
# NO_PUSH_TEXT. The trailing space in the matching pattern means the recorded
# reason must be exactly <reason> (a block-class reason is a different string).
ac_assert_requeue() {
  local diag="$1" rc="$2" attempt="$3" reason="$4" what="$5"
  CALLS=()
  no_push_outcome "$ISSUE" "$diag" "$rc" "$attempt" "$NO_PUSH_TEXT"
  if ac_has_call_matching "issue_block "; then
    ac_fail "no-push exit must NOT call issue_block (${what})"
  fi
  ac_has_call_matching "issue_requeue ${ISSUE} ${reason} " \
    || ac_fail "expected issue_requeue ${ISSUE} ${reason}, got: ${CALLS[*]:-nothing} (${what})"
}

# ac_assert_block_reason <diag> <rc> <attempt> <reason> <what>
# — the extracted no_push_outcome must issue_block <ISSUE> <reason> ... and
# must never issue_requeue. Uses the calling test's globals ISSUE and
# NO_PUSH_TEXT. The trailing space in the matching pattern means the recorded
# reason must be exactly <reason> (e.g. "no_push" not "no_push_after_3_attempts").
ac_assert_block_reason() {
  local diag="$1" rc="$2" attempt="$3" reason="$4" what="$5"
  CALLS=()
  no_push_outcome "$ISSUE" "$diag" "$rc" "$attempt" "$NO_PUSH_TEXT"
  if ac_has_call_matching "issue_requeue "; then
    ac_fail "attempt $attempt with reason ${reason} must NOT requeue (${what})"
  fi
  ac_has_call_matching "issue_block ${ISSUE} ${reason} " \
    || ac_fail "expected issue_block ${ISSUE} ${reason}, got: ${CALLS[*]:-nothing} (${what})"
}
