#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1171-review-env-overrides.sh
#
# Issue #1171: review/review-pr.sh set review-agent environment with the same
# variable names the deployment already sets, and got both wrong — in
# opposite directions:
#
#   export CLAUDE_MODEL="sonnet"                          # overwrote the
#       #                                              jobspec's CLAUDE_MODEL
#       #                                              on every review
#   export CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-900}"       # :- only falls back
#       #                                              when UNSET — the jobspec
#       #                                              exports 7200, so the
#       #                                              "15 min cap" was dead code
#
# The fix uses distinct names for "the value I want to impose" vs "the value
# that may already be set":
#   - CLAUDE_MODEL reaches the review agent as the container's value unless
#     REVIEW_CLAUDE_MODEL is set (no hardcoded model name)
#   - CLAUDE_TIMEOUT for the review is 2400s by default, overridable via
#     REVIEW_CLAUDE_TIMEOUT, and not silenced by an inherited CLAUDE_TIMEOUT
#   - the rc-124 error comment at review-pr.sh:~371 reports the timeout the
#     review actually ran under
#
# Acceptance (read-only — the env-setting block is exercised by extracting
# review_run_and_parse() from the checkout with ac_extract_fn, stubbing
# agent_run/curl/log/status, and asserting the environment the function
# leaves for the agent; the same approach as issue-1164):
#   1. with CLAUDE_TIMEOUT=7200 / CLAUDE_MODEL=<sentinel> pre-set (as the
#      jobspec does), a completed review leaves CLAUDE_TIMEOUT=2400 and the
#      container's CLAUDE_MODEL intact — the 7200 is NOT inherited and no
#      model name is hardcoded over it
#   2. CLAUDE_TIMEOUT unset → still 2400
#   3. REVIEW_CLAUDE_TIMEOUT / REVIEW_CLAUDE_MODEL win when set
#   4. the review-pr.sh source contains no hardcoded model export and the
#      timeout line's comment states the actual effective value (2400)
#   5. an rc-124 timeout with no output reports "timed out after 2400s" —
#      the timeout actually used, not the inherited container value
#
# No agent started, no live services.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd jq

TARGET="$REPO_ROOT/review/review-pr.sh"
ac_assert_file "$TARGET" "review/review-pr.sh must exist"

review_fn_body="$(ac_extract_fn review_run_and_parse "$TARGET")"
[ -n "$review_fn_body" ] \
  || ac_fail "could not locate review_run_and_parse() in review/review-pr.sh"
eval "$review_fn_body"
type review_run_and_parse >/dev/null 2>&1 \
  || ac_fail "review_run_and_parse() did not evaluate to a function"

# Globals review-pr.sh would normally have set before calling the function.
# SC2034: PR_NUMBER is consumed by the eval'd review_run_and_parse, which is
# not visible through `eval`.
# shellcheck disable=SC2034
PR_NUMBER=1171
# shellcheck disable=SC2034
PR_SHA="abcdef1234567890"
# shellcheck disable=SC2034
FORGE_TOKEN="test-token"
# shellcheck disable=SC2034
API="https://forge.example/api/repos/test/repo"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
# shellcheck disable=SC2034
WORKTREE="$TMP_DIR/review-wt"
# shellcheck disable=SC2034
PROMPT="review prompt"
# shellcheck disable=SC2034
IS_RE_REVIEW=false
_AGENT_SESSION_ID=""
OUTPUT_FILE="$TMP_DIR/review-output.json"

CURL_BODY="$TMP_DIR/curl-body.log"
# agent_run stub: record nothing, emulate the real agent by writing the
# pre-decided output before returning the configured rc.
agent_run() {
  [ -n "${AGENT_STUB_OUTPUT:-}" ] && printf '%s' "$AGENT_STUB_OUTPUT" > "$OUTPUT_FILE"
  return "${AGENT_RUN_RC_STUB:-0}"
}
curl() {
  local body
  body="$(cat)"
  printf '%s\n' "$body" >> "$CURL_BODY"
  return 0
}
log()    { :; }
status() { :; }

# run_review <agent-run-rc> <output-file|-> — run the extracted function and
# return its rc via REVIEW_RC (guarded: a non-zero rc is the thing under test).
run_review() {
  local stub_rc="$1" out="$2"
  AGENT_RUN_RC_STUB="$stub_rc"
  if [ "$out" = "-" ]; then AGENT_STUB_OUTPUT=""; else AGENT_STUB_OUTPUT="$(cat "$out")"; fi
  : > "$CURL_BODY"
  REVIEW_RC=0
  review_run_and_parse || REVIEW_RC=$?
}

VALID_VERDICT="$TMP_DIR/verdict.json"
printf '{"verdict":"approve","verdict_reason":"ok","review_markdown":"LGTM"}' > "$VALID_VERDICT"

# ── 1. Jobspec-like environment (sentinels) must not defeat the cap/model ──
unset REVIEW_CLAUDE_TIMEOUT REVIEW_CLAUDE_MODEL 2>/dev/null || true
export CLAUDE_TIMEOUT=7200
export CLAUDE_MODEL="unsloth/Qwen3.8-27B"
run_review 0 "$VALID_VERDICT"
[ "$REVIEW_RC" -eq 0 ] || ac_fail "valid verdict must return 0, got ${REVIEW_RC}"
ac_assert_eq "$CLAUDE_TIMEOUT" "2400" \
  "review timeout must be the 2400s cap, not the inherited 7200 jobspec value"
ac_assert_eq "$CLAUDE_MODEL" "unsloth/Qwen3.8-27B" \
  "CLAUDE_MODEL reaching the review agent must be the container's value, not a hardcoded name"

# ── 2. Unset CLAUDE_TIMEOUT → still the 2400 cap ───────────────────────────
unset CLAUDE_TIMEOUT
run_review 0 "$VALID_VERDICT"
[ "$REVIEW_RC" -eq 0 ] || ac_fail "valid verdict must return 0, got ${REVIEW_RC}"
ac_assert_eq "$CLAUDE_TIMEOUT" "2400" "unset CLAUDE_TIMEOUT must default to the 2400s cap"

# ── 3. REVIEW_* overrides win when set ─────────────────────────────────────
export REVIEW_CLAUDE_TIMEOUT=1800
export REVIEW_CLAUDE_MODEL="test/review-model"
run_review 0 "$VALID_VERDICT"
[ "$REVIEW_RC" -eq 0 ] || ac_fail "valid verdict must return 0, got ${REVIEW_RC}"
ac_assert_eq "$CLAUDE_TIMEOUT" "1800" "REVIEW_CLAUDE_TIMEOUT must override the 2400 default"
ac_assert_eq "$CLAUDE_MODEL" "test/review-model" "REVIEW_CLAUDE_MODEL must override the container's value"
unset REVIEW_CLAUDE_TIMEOUT REVIEW_CLAUDE_MODEL

# ── 4. Source checks: no hardcoded model, comment states the real value ─────
if grep -nE 'export[[:space:]]+CLAUDE_MODEL=[[:space:]]*"(sonnet|opus|haiku|claude-|qwen)' "$TARGET" >/dev/null; then
  ac_fail "review-pr.sh must not hardcode a CLAUDE_MODEL export"
fi
timeout_line="$(grep -n 'export CLAUDE_TIMEOUT=' "$TARGET" || true)"
[ -n "$timeout_line" ] || ac_fail "review-pr.sh must export CLAUDE_TIMEOUT for the review"
case "$timeout_line" in
  *2400*) ;;
  *) ac_fail "the CLAUDE_TIMEOUT line must state the actual effective value (2400), got: $timeout_line" ;;
esac
case "$timeout_line" in
  *REVIEW_CLAUDE_TIMEOUT*) ;;
  *) ac_fail "the review timeout must be overridable via REVIEW_CLAUDE_TIMEOUT, got: $timeout_line" ;;
esac
# The old dead-code pattern (falling back on an inherited value) is gone.
if grep -nE 'CLAUDE_TIMEOUT:-' "$TARGET" | grep -v 'REVIEW_CLAUDE_TIMEOUT' | grep -q 'CLAUDE_TIMEOUT:-'; then
  ac_fail "review-pr.sh must not fall back on the inherited CLAUDE_TIMEOUT (\${CLAUDE_TIMEOUT:-...})"
fi

# ── 5. rc-124 with no output reports the timeout actually used ─────────────
unset CLAUDE_TIMEOUT
run_review 124 -
[ "$REVIEW_RC" -eq 1 ] \
  || ac_fail "timeout with no output must return 1, got ${REVIEW_RC}"
BODY_TEXT="$(cat "$CURL_BODY" 2>/dev/null || true)"
case "$BODY_TEXT" in
  *"timed out after 2400s"*) ;;
  *) ac_fail "timeout comment must name the timeout actually used (2400s), got: $BODY_TEXT" ;;
esac
case "$BODY_TEXT" in
  *7200*) ac_fail "timeout comment must not name the inherited container value, got: $BODY_TEXT" ;;
esac

ac_pass
