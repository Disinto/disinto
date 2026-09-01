#!/usr/bin/env bash
# =============================================================================
# tests/lib/review-harness.sh — shared harness for in-process review tests
#
# Sourced by acceptance tests that exercise review/review-pr.sh functions
# without starting the script (which is a top-level executable — sourcing it
# would run the whole review). The function under test is extracted from the
# checkout with ac_extract_fn() + eval; this harness provides the globals
# review-pr.sh would normally have set and stubs the calls the function
# makes (agent_run, curl, log, status).
#
# Usage (after sourcing tests/lib/acceptance-helpers.sh):
#   TMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TMP_DIR"' EXIT
#   ac_load_review_fn "$REPO_ROOT/review/review-pr.sh"
#   ac_setup_review_env <pr-number>
#   ac_run_review <agent-run-rc> <output-file|->
#
# Conventions: same as acceptance-helpers.sh — helpers are read-only apart
# from writing under $TMP_DIR, and failures go through ac_fail.
# =============================================================================

# Idempotent guard — a test that sources the harness twice (e.g. via nested
# sourcing) shouldn't redefine functions or re-run setup.
if [ -n "${REVIEW_HARNESS_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
REVIEW_HARNESS_LOADED=1

# ac_load_review_fn <file> — extract review_run_and_parse() from <file>
# (column-0 `name() {` to the next column-0 `}`, as ac_extract_fn does),
# eval it, and fail the test if it does not become a function.
ac_load_review_fn() {
  local target="$1" body
  ac_assert_file "$target" "review/review-pr.sh must exist"
  body="$(ac_extract_fn review_run_and_parse "$target")"
  [ -n "$body" ] \
    || ac_fail "could not locate review_run_and_parse() in review/review-pr.sh"
  eval "$body"
  type review_run_and_parse >/dev/null 2>&1 \
    || ac_fail "review_run_and_parse() did not evaluate to a function"
}

# ac_setup_review_env <pr-number> — set the globals review-pr.sh would
# normally have set before calling review_run_and_parse(), and install the
# stubs for the calls the function makes. Requires $TMP_DIR to be set.
#
# Globals set: PR_NUMBER PR_SHA FORGE_TOKEN API WORKTREE PROMPT
# IS_RE_REVIEW _AGENT_SESSION_ID OUTPUT_FILE CURL_ARGS CURL_BODY.
# Stubs installed: agent_run, curl, log, status.
#
#   agent_run — emulates the real agent: before returning the configured
#     rc it writes the (pre-decided) output file, so the function's opening
#     `rm -f "$OUTPUT_FILE"` + "agent writes it during the run" sequence
#     holds. The rc comes from AGENT_RUN_RC_STUB, the content from
#     AGENT_STUB_OUTPUT (both set per case by ac_run_review).
#   curl — runs in a pipeline subshell, so it records to files instead of a
#     shell array. The body goes to its own file because jq -n emits
#     pretty-printed, multi-line JSON.
#   log / status — no-ops.
ac_setup_review_env() {
  local pr_number="$1"
  [ -n "${TMP_DIR:-}" ] \
    || ac_fail "ac_setup_review_env: TMP_DIR must be set before calling it"
  # SC2034: PR_NUMBER, PR_SHA, FORGE_TOKEN, API, WORKTREE, PROMPT,
  # IS_RE_REVIEW, _AGENT_SESSION_ID, OUTPUT_FILE are consumed by the
  # eval'd review_run_and_parse, which shellcheck cannot see through eval.
  # shellcheck disable=SC2034
  PR_NUMBER="$pr_number"
  # shellcheck disable=SC2034
  PR_SHA="abcdef1234567890"
  # shellcheck disable=SC2034
  FORGE_TOKEN="test-token"
  # shellcheck disable=SC2034
  API="https://forge.example/api/repos/test/repo"
  # shellcheck disable=SC2034
  WORKTREE="$TMP_DIR/review-wt"
  # shellcheck disable=SC2034
  PROMPT="review prompt"
  # shellcheck disable=SC2034
  IS_RE_REVIEW=false
  # shellcheck disable=SC2034
  _AGENT_SESSION_ID=""
  # shellcheck disable=SC2034
  OUTPUT_FILE="$TMP_DIR/review-output.json"
  CURL_ARGS="$TMP_DIR/curl-args.log"
  CURL_BODY="$TMP_DIR/curl-body.log"
  : > "$CURL_ARGS"
  : > "$CURL_BODY"
  agent_run() {
    [ -n "${AGENT_STUB_OUTPUT:-}" ] && printf '%s' "$AGENT_STUB_OUTPUT" > "$OUTPUT_FILE"
    return "${AGENT_RUN_RC_STUB:-0}"
  }
  curl() {
    local body
    body="$(cat)"
    printf '%s\n' "$*" >> "$CURL_ARGS"
    printf '%s\n' "$body" >> "$CURL_BODY"
    return 0
  }
  log()    { :; }
  status() { :; }
}

# ac_run_review <agent-run-rc> <output-file|-> — run the loaded
# review_run_and_parse() with a per-case rc and output; its rc comes back
# in REVIEW_RC (guarded: a non-zero rc is the thing under test). Truncates
# CURL_ARGS and CURL_BODY per case.
# SC2034: REVIEW_RC is read by the sourcing test, which shellcheck cannot
# see through `source`.
# shellcheck disable=SC2034
ac_run_review() {
  local stub_rc="$1" out="$2"
  AGENT_RUN_RC_STUB="$stub_rc"
  if [ "$out" = "-" ]; then AGENT_STUB_OUTPUT=""; else AGENT_STUB_OUTPUT="$(cat "$out")"; fi
  : > "$CURL_ARGS"
  : > "$CURL_BODY"
  REVIEW_RC=0
  review_run_and_parse || REVIEW_RC=$?
}
