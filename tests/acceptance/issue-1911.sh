#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1911.sh — the owner's comment revises the committed draft
#
# Issue #1911 (fix/architect): q_and_a commits its revisions the way decompose
# commits a draft. _dispatch_opus_qa stages the pitch (prepare_pitch), shows
# the session the new comments, and — only after agent_run succeeds — calls
# publish_draft. A PR that is not a pitch is skipped. The session writes the
# reply to COMMENT_FILE; it does not post it.
#
# Hermetic: no forge, no nomad, no repo mutation. _dispatch_opus_qa is extracted
# with ac_extract_fn and run against the stubs named in the issue.
#
# Run via: tools/run-acceptance.sh 1911
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep jq

ARCHITECT_RUN="$REPO_ROOT/architect/architect-run.sh"
ac_assert_file "$ARCHITECT_RUN" "architect/architect-run.sh is missing"

SINCE="2026-10-07T10:00:00Z"
PR=7

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

PITCH_FILE="$TMP_DIR/pitch.md"
BACKLOG_FILE="$TMP_DIR/backlog.json"
COMMENT_FILE="$TMP_DIR/comment.md"
PROMPT_FILE="$TMP_DIR/prompt.txt"
PUBLISH_LOG="$TMP_DIR/publish.log"
AGENT_LOG="$TMP_DIR/agent.log"
RC_FILE="$TMP_DIR/rc"
FLAG_FILE="$TMP_DIR/flag"

# Globals the extracted function expands. The stubs do not set them; production
# does, via load_formula_or_profile / build_* before the prompt is built.
export ARCHITECT_FORMULA="$TMP_DIR/formula.toml"
export PROJECT_NAME="disinto"
export FORGE_REPO="disinto/disinto"
export QA_ROLE_TEXT="role"
export SUBISSUE_TERM="sub-issues"
export PITCH_NOUN="sprint"
export CONTEXT_BLOCK=""
export GRAPH_SECTION=""
export FORMULA_CONTENT=""
export PROMPT_FOOTER=""
export WORKTREE="$TMP_DIR/worktree"

# Stub controls. Reset per case.
AGENT_RC=0
PREP_RC=0

# ── Stubs named by the issue ──────────────────────────────────────────────────
# no-ops
load_formula_or_profile() { :; }
build_context_block() { :; }
formula_prepare_profile_context() { :; }
build_graph_section() { :; }
read_scratch_context() { :; }
build_scratch_instruction() { :; }
build_sdk_prompt_footer() { :; }
formula_lessons_block() { :; }
# the extracted function logs; a missing log would fail the skip path
log() { :; }

# prepare_pitch sets the three paths to temp files
prepare_pitch() {
  if [ "$PREP_RC" -ne 0 ]; then
    return 1
  fi
  PITCH_FILE="$TMP_DIR/pitch.md"
  BACKLOG_FILE="$TMP_DIR/backlog.json"
  COMMENT_FILE="$TMP_DIR/comment.md"
  : >"$PITCH_FILE"
  printf '[]\n' >"$BACKLOG_FILE"
  : >"$COMMENT_FILE"
  return 0
}

# others_comments_since prints the owner's new comment
others_comments_since() {
  printf '%s' '[{"user":{"login":"disinto-admin"},"body":"Split entry b"}]'
}

# agent_run saves its last argument
agent_run() {
  printf '%s' "${!#}" >"$PROMPT_FILE"
  printf 'agent_run\n' >>"$AGENT_LOG"
  return "$AGENT_RC"
}

# publish_draft logs its arguments
publish_draft() {
  printf '%s\n' "$*" >>"$PUBLISH_LOG"
}

ac_log "extracting _dispatch_opus_qa from architect/architect-run.sh"
FN="$(ac_extract_fn _dispatch_opus_qa "$ARCHITECT_RUN")"
[ -n "$FN" ] || ac_fail "ac_extract_fn did not return _dispatch_opus_qa"

# The call site forwards last-seen (#1911 step 1).
# shellcheck disable=SC2016
grep -qF '_dispatch_opus_qa "$pr" "$body" "$last_seen"' "$ARCHITECT_RUN" \
  || ac_fail "dispatch_q_and_a does not pass last_seen to _dispatch_opus_qa"

# run_dispatch — eval the extracted function in a subshell (set +e so a
# failing agent_run is observable) and record rc + _OPUS_DISPATCH_FAILED.
run_dispatch() {
  : >"$PROMPT_FILE"
  : >"$PUBLISH_LOG"
  : >"$AGENT_LOG"
  : >"$RC_FILE"
  : >"$FLAG_FILE"
  (
    set +e
    _OPUS_DISPATCH_FAILED=false
    eval "$FN"
    _dispatch_opus_qa "$PR" body "$SINCE"
    printf '%s\n' "$?" >"$RC_FILE"
    printf '%s\n' "$_OPUS_DISPATCH_FAILED" >"$FLAG_FILE"
  )
}

prompt_has() {
  grep -qF "$1" "$PROMPT_FILE"
}

# ── AC1: a revision is published, and the prompt carries the comment ─────────
ac_log "AC1: _dispatch_opus_qa returns 0, prompt has the comment, publish_draft once with 7"
AGENT_RC=0
PREP_RC=0
run_dispatch
ac_assert_eq "$(cat "$RC_FILE")" "0" "AC1: expected rc 0, got $(cat "$RC_FILE")"
prompt_has "Split entry b" \
  || ac_fail "AC1: saved prompt missing 'Split entry b'"
prompt_has "**disinto-admin**" \
  || ac_fail "AC1: saved prompt missing '**disinto-admin**'"
prompt_has "$COMMENT_FILE" \
  || ac_fail "AC1: saved prompt missing COMMENT_FILE path ($COMMENT_FILE)"
publish_n="$(grep -c . "$PUBLISH_LOG" || true)"
ac_assert_eq "$publish_n" "1" "AC1: expected publish_draft once, got $publish_n ($(cat "$PUBLISH_LOG"))"
publish_line="$(cat "$PUBLISH_LOG")"
case "$publish_line" in
  "7 "*) ;;
  *) ac_fail "AC1: publish_draft was not called with 7 (got: $publish_line)" ;;
esac
ac_log "AC1 passed"

# ── AC2: a failed session does not publish ────────────────────────────────────
ac_log "AC2: agent_run returns 1 -> no publish_draft, _OPUS_DISPATCH_FAILED=true"
AGENT_RC=1
PREP_RC=0
run_dispatch
publish_n="$(grep -c . "$PUBLISH_LOG" || true)"
ac_assert_eq "$publish_n" "0" "AC2: publish_draft must not be called (got $publish_n)"
ac_assert_eq "$(cat "$FLAG_FILE")" "true" \
  "AC2: expected _OPUS_DISPATCH_FAILED=true, got $(cat "$FLAG_FILE")"
ac_log "AC2 passed"

# ── AC3: a non-pitch is skipped ───────────────────────────────────────────────
ac_log "AC3: prepare_pitch returns 1 -> neither agent_run nor publish_draft, rc 0"
AGENT_RC=0
PREP_RC=1
run_dispatch
ac_assert_eq "$(cat "$RC_FILE")" "0" "AC3: expected rc 0, got $(cat "$RC_FILE")"
agent_n="$(grep -c . "$AGENT_LOG" || true)"
publish_n="$(grep -c . "$PUBLISH_LOG" || true)"
ac_assert_eq "$agent_n" "0" "AC3: agent_run must not be called (got $agent_n)"
ac_assert_eq "$publish_n" "0" "AC3: publish_draft must not be called (got $publish_n)"
ac_log "AC3 passed"

# ── AC4: the prompt no longer tells the session to post or refine inline ─────
ac_log "AC4: prompt contains neither 'Post a reply comment' nor 'Refine the <!-- filer:begin -->'"
AGENT_RC=0
PREP_RC=0
run_dispatch
if prompt_has "Post a reply comment"; then
  ac_fail "AC4: prompt still contains 'Post a reply comment'"
fi
if prompt_has "Refine the <!-- filer:begin -->"; then
  ac_fail "AC4: prompt still contains 'Refine the <!-- filer:begin -->'"
fi
ac_log "AC4 passed"

ac_pass
