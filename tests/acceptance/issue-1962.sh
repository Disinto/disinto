#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1962.sh — formula-load and reply-post failures hold
# the architect last-seen marker
#
# Issue #1962: a failed load_formula_or_profile or post_pr_comment must set
# _OPUS_DISPATCH_FAILED so <!-- architect-last-seen: --> is not advanced.
# Otherwise others_comments_since (updated_at > since) drops the owner's
# comment, and a reply whose POST failed after the pitch commit landed is
# never sent again.
#
# Hermetic: no forge, no nomad, no repo mutation. The cycle and the dispatch
# functions are extracted with ac_extract_fn and run against stubs of
# load_formula_or_profile, agent_run, pitch_pr_put and post_pr_comment.
#
# Run via: tools/run-acceptance.sh 1962
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
bash -n "$ARCHITECT_RUN" || ac_fail "bash -n architect/architect-run.sh failed"

PR=7
LAST_SEEN_ISO="2026-10-07T10:00:00Z"
NOW_ISO="2026-10-09T00:00:00Z"
COMMENT_AT="2026-10-08T12:00:00Z"
OWNER_BODY="Split entry b"

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR" "$PENDING_FILE" 2>/dev/null || true; }
PENDING_FILE=""
trap cleanup EXIT

PROJECT_NAME="i1962-$$"
PENDING_FILE="/tmp/architect-pending-reply-${PROJECT_NAME}-${PR}"
rm -f "$PENDING_FILE"

FACTORY_ROOT="$TMP_DIR/factory"
mkdir -p "$FACTORY_ROOT/tools"
cat >"$FACTORY_ROOT/tools/pitch-lint.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "### Pitch lint: stub"
EOF
chmod +x "$FACTORY_ROOT/tools/pitch-lint.sh"

PATCH_LOG="$TMP_DIR/patch.log"
POST_LOG="$TMP_DIR/post.log"
PUT_LOG="$TMP_DIR/put.log"
AGENT_LOG="$TMP_DIR/agent.log"
FORMULA_LOG="$TMP_DIR/formula.log"

# Controls. Reset per case.
FORMULA_FAILS=0
AGENT_RC=0
PUT_RC=0
POST_FAILS=0
POST_N=0
PITCH_HAS_ENTRIES=0
AGENT_CHANGES_FILE=0

export PROJECT_NAME FACTORY_ROOT
export ARCHITECT_FORMULA="$TMP_DIR/formula.toml"
export ARCHITECT_LOGIN="architect-bot"
# One assignment per group so this block does not copy the issue-1911 exports.
export FORGE_REPO="disinto/disinto" QA_ROLE_TEXT="role" SUBISSUE_TERM="sub-issues" PITCH_NOUN="sprint"
export CONTEXT_BLOCK="" GRAPH_SECTION="" FORMULA_CONTENT="" PROMPT_FOOTER="" WORKTREE="$TMP_DIR/worktree"
export PR_NUMBER="$PR"
export LAST_SEEN="$LAST_SEEN_ISO"
export NOW_ISO
export PR_BODY="pitch body
<!-- architect-last-seen: ${LAST_SEEN_ISO} -->"

COMMENT_FIXTURE='[]'

ac_log "extracting architect cycle and dispatch functions"
extract_one() {
  local name="$1" src
  src="$(ac_extract_fn "$name" "$ARCHITECT_RUN")"
  [ -n "$src" ] || ac_fail "ac_extract_fn did not return $name"
  printf '%s\n' "$src"
}

EVAL_SRC="$(
  extract_one pending_reply_path
  extract_one read_pending_reply
  extract_one clear_pending_reply
  extract_one update_last_seen
  extract_one others_comments_since
  extract_one has_reject_comment
  extract_one has_new_comment_since
  extract_one architect_has_commented
  extract_one publish_draft
  extract_one _dispatch_opus_qa
  extract_one dispatch_q_and_a
  extract_one dispatch_decompose
  extract_one architect_pr_cycle
)"
# shellcheck disable=SC1090
eval "$EVAL_SRC"

# ── Stubs named by the issue ────────────────────────────────────────────────
log() { printf '%s\n' "$*" >>"$TMP_DIR/run.log"; }
get_pr_comments() { printf '%s' "$COMMENT_FIXTURE"; }
patch_pr_body() { printf '%s\n---END-PATCH---\n' "$2" >>"$PATCH_LOG"; }
pitch_pr_put() {
  printf '%s\n' "$*" >>"$PUT_LOG"
  return "$PUT_RC"
}
post_pr_comment() {
  POST_N=$((POST_N + 1))
  printf '%s' "$2" >"$TMP_DIR/post-${POST_N}"
  printf '%s\n' "$POST_N" >>"$POST_LOG"
  if [ "$POST_FAILS" -gt 0 ]; then
    POST_FAILS=$((POST_FAILS - 1))
    return 1
  fi
  return 0
}
load_formula_or_profile() {
  printf 'load\n' >>"$FORMULA_LOG"
  if [ "$FORMULA_FAILS" -gt 0 ]; then
    FORMULA_FAILS=$((FORMULA_FAILS - 1))
    return 1
  fi
  return 0
}
agent_run() {
  printf 'agent_run\n' >>"$AGENT_LOG"
  if [ -n "${COMMENT_FILE:-}" ]; then
    printf '%s\n' "reply from session" >"$COMMENT_FILE"
  fi
  if [ "$AGENT_CHANGES_FILE" = 1 ] && [ -n "${PITCH_FILE:-}" ]; then
    printf '\n- id: sub1\n' >>"$PITCH_FILE"
  fi
  return "$AGENT_RC"
}
prepare_pitch() {
  PITCH_DIR="$TMP_DIR/pitch"
  mkdir -p "$PITCH_DIR"
  PITCH_FILE="$PITCH_DIR/sprint.md"
  # Used by the extracted publish_draft; shellcheck cannot see the eval'd body.
  export PITCH_PATH="sprints/sprint.md"
  export PITCH_BRANCH="architect-sprint"
  export PITCH_SHA="abc123"
  printf 'goal\n' >"$PITCH_FILE"
  cp "$PITCH_FILE" "$PITCH_DIR/orig"
  BACKLOG_FILE="$PITCH_DIR/backlog.json"
  printf '[]\n' >"$BACKLOG_FILE"
  COMMENT_FILE="$PITCH_DIR/comment.md"
  : >"$COMMENT_FILE"
  return 0
}
pitch_sprint_block() { printf '%s\n' "class: internal"; }
pitch_has_entries() {
  if [ "$PITCH_HAS_ENTRIES" = 1 ]; then
    return 0
  fi
  return 1
}
# No-op the prompt builders in one loop. Separate `{ :; }` stubs duplicate issue-1911.
for _stub in build_context_block formula_prepare_profile_context build_graph_section \
  read_scratch_context build_scratch_instruction build_sdk_prompt_footer formula_lessons_block; do
  eval "${_stub}() { :; }"
done
unset _stub

reset_case() {
  : >"$PATCH_LOG"
  : >"$POST_LOG"
  : >"$PUT_LOG"
  : >"$AGENT_LOG"
  : >"$FORMULA_LOG"
  : >"$TMP_DIR/run.log"
  rm -f "$PENDING_FILE"
  FORMULA_FAILS=0
  AGENT_RC=0
  PUT_RC=0
  POST_FAILS=0
  POST_N=0
  PITCH_HAS_ENTRIES=0
  AGENT_CHANGES_FILE=0
  PR_BODY="pitch body
<!-- architect-last-seen: ${LAST_SEEN_ISO} -->"
  LAST_SEEN="$LAST_SEEN_ISO"
  COMMENT_FIXTURE='[]'
  _OPUS_DISPATCH_FAILED=false
}

patch_count() { grep -c 'END-PATCH' "$PATCH_LOG" || true; }
post_count() { grep -c . "$POST_LOG" || true; }
put_count() { grep -c . "$PUT_LOG" || true; }
agent_count() { grep -c . "$AGENT_LOG" || true; }

# marker_held — no patch, and a patch of NOW would have dropped the owner.
assert_marker_held() {
  local label="$1"
  ac_assert_eq "$(patch_count)" "0" "$label: last-seen must not be patched (got $(patch_count))"
  if [ -s "$PATCH_LOG" ] && grep -q "$NOW_ISO" "$PATCH_LOG"; then
    ac_fail "$label: patched body contains the new last-seen"
  fi
}

owner_still_visible() {
  local visible dropped
  COMMENT_FIXTURE="$(printf '[{"user":{"login":"owner"},"body":"%s","updated_at":"%s"}]' \
    "$OWNER_BODY" "$COMMENT_AT")"
  visible="$(others_comments_since "$PR" "$LAST_SEEN")"
  dropped="$(others_comments_since "$PR" "$NOW_ISO")"
  printf '%s' "$visible" | grep -qF "$OWNER_BODY" \
    || ac_fail "owner comment not visible since held last-seen ($LAST_SEEN): $visible"
  if printf '%s' "$dropped" | grep -qF "$OWNER_BODY"; then
    ac_fail "owner comment still visible since NOW ($NOW_ISO); the fixture cannot prove the drop"
  fi
}

# ── AC1: q_and_a formula-load failure holds the marker and retries ───────────
ac_log "AC1: q_and_a load_formula_or_profile failure holds last-seen and retries"
reset_case
PITCH_HAS_ENTRIES=1
FORMULA_FAILS=1
COMMENT_FIXTURE="$(printf '[{"user":{"login":"owner"},"body":"%s","updated_at":"%s"}]' \
  "$OWNER_BODY" "$COMMENT_AT")"
rc=0
_dispatch_opus_qa "$PR" body "$LAST_SEEN" || rc=$?
ac_assert_eq "$rc" "1" "AC1: _dispatch_opus_qa should return 1, got $rc"
ac_assert_eq "$_OPUS_DISPATCH_FAILED" "true" \
  "AC1: expected _OPUS_DISPATCH_FAILED=true, got $_OPUS_DISPATCH_FAILED"
ac_assert_eq "$(agent_count)" "0" "AC1: agent_run must not run when the formula fails"

reset_case
PITCH_HAS_ENTRIES=1
FORMULA_FAILS=1
COMMENT_FIXTURE="$(printf '[{"user":{"login":"owner"},"body":"%s","updated_at":"%s"}]' \
  "$OWNER_BODY" "$COMMENT_AT")"
architect_pr_cycle
ac_assert_eq "$_OPUS_DISPATCH_FAILED" "true" "AC1 cycle: flag should stay true"
assert_marker_held "AC1 cycle"
owner_still_visible
# Next cycle: formula loads, the owner's comment is still newer than last-seen,
# so the revision runs.
FORMULA_FAILS=0
architect_pr_cycle
ac_assert_eq "$(agent_count)" "1" \
  "AC1 cycle 2: revision should be retried (agent_run count $(agent_count))"
ac_log "AC1 passed"

# ── AC2: decompose formula-load failure holds the marker ─────────────────────
ac_log "AC2: decompose load_formula_or_profile failure holds last-seen"
reset_case
PITCH_HAS_ENTRIES=0
FORMULA_FAILS=1
rc=0
dispatch_decompose "$PR" || rc=$?
ac_assert_eq "$rc" "1" "AC2: dispatch_decompose should return 1, got $rc"
ac_assert_eq "$_OPUS_DISPATCH_FAILED" "true" \
  "AC2: expected _OPUS_DISPATCH_FAILED=true, got $_OPUS_DISPATCH_FAILED"

reset_case
PITCH_HAS_ENTRIES=0
FORMULA_FAILS=1
architect_pr_cycle
ac_assert_eq "$_OPUS_DISPATCH_FAILED" "true" "AC2 cycle: flag should stay true"
assert_marker_held "AC2 cycle"
ac_assert_eq "$(agent_count)" "0" "AC2 cycle: agent_run must not run"
# Next cycle retries the draft because the marker (and the gate) still match.
FORMULA_FAILS=0
AGENT_CHANGES_FILE=1
architect_pr_cycle
ac_assert_eq "$(agent_count)" "1" \
  "AC2 cycle 2: decompose should be retried (agent_run count $(agent_count))"
ac_log "AC2 passed"

# ── AC3: failed reply POST is reposted, even after the commit landed ────────
ac_log "AC3: post_pr_comment failure holds last-seen and reposts next cycle"
reset_case
PITCH_HAS_ENTRIES=0
AGENT_CHANGES_FILE=1
POST_FAILS=1
PUT_RC=0
architect_pr_cycle
ac_assert_eq "$_OPUS_DISPATCH_FAILED" "true" "AC3 cycle 1: flag should be true"
assert_marker_held "AC3 cycle 1"
ac_assert_eq "$(put_count)" "1" "AC3 cycle 1: pitch commit should have landed (puts $(put_count))"
ac_assert_eq "$(post_count)" "1" "AC3 cycle 1: the failed POST should have been attempted"
[ -s "$PENDING_FILE" ] || ac_fail "AC3 cycle 1: failed reply was not stashed"
failed_reply="$(cat "$PENDING_FILE")"
printf '%s' "$failed_reply" | grep -qF "reply from session" \
  || ac_fail "AC3 cycle 1: stash missing the session reply"
# Commit landed: the pitch now has entries, and there is still no owner
# comment. The retry must repost the stashed reply, not start another session.
PITCH_HAS_ENTRIES=1
POST_FAILS=0
architect_pr_cycle
ac_assert_eq "$_OPUS_DISPATCH_FAILED" "false" "AC3 cycle 2: flag should be false after repost"
ac_assert_eq "$(agent_count)" "1" \
  "AC3 cycle 2: must not re-run the session (agent_run count $(agent_count))"
ac_assert_eq "$(put_count)" "1" \
  "AC3 cycle 2: must not commit again (puts $(put_count))"
ac_assert_eq "$(post_count)" "2" "AC3 cycle 2: the failed reply should be reposted"
ac_assert_eq "$(cat "$TMP_DIR/post-2")" "$failed_reply" \
  "AC3 cycle 2: reposted body does not match the failed reply"
[ ! -e "$PENDING_FILE" ] || ac_fail "AC3 cycle 2: stash should be cleared after repost"
ac_assert_eq "$(patch_count)" "1" "AC3 cycle 2: marker should advance once the reply is posted"
grep -q "$NOW_ISO" "$PATCH_LOG" || ac_fail "AC3 cycle 2: advanced body missing $NOW_ISO"
if grep -q "$LAST_SEEN_ISO" "$PATCH_LOG"; then
  ac_fail "AC3 cycle 2: old last-seen still in the patch"
fi
ac_log "AC3 passed"

# ── AC4: a successful dispatch still advances the marker ────────────────────
ac_log "AC4: successful dispatch advances last-seen"
reset_case
PITCH_HAS_ENTRIES=0
AGENT_CHANGES_FILE=1
architect_pr_cycle
ac_assert_eq "$_OPUS_DISPATCH_FAILED" "false" "AC4: flag should stay false"
ac_assert_eq "$(patch_count)" "1" "AC4: marker should be patched"
grep -q "$NOW_ISO" "$PATCH_LOG" || ac_fail "AC4: patched body missing $NOW_ISO"
ac_assert_eq "$(post_count)" "1" "AC4: reply should be posted"
[ ! -e "$PENDING_FILE" ] || ac_fail "AC4: success must not leave a pending-reply stash"
ac_log "AC4 passed"

# ── AC5: agent_run failure still holds the marker ────────────────────────────
ac_log "AC5: agent_run failure sets the flag and holds last-seen"
reset_case
PITCH_HAS_ENTRIES=0
AGENT_RC=1
architect_pr_cycle
ac_assert_eq "$_OPUS_DISPATCH_FAILED" "true" "AC5: flag should be true"
assert_marker_held "AC5"
ac_assert_eq "$(post_count)" "0" "AC5: a failed session must not post"
[ ! -e "$PENDING_FILE" ] || ac_fail "AC5: a failed session must not stash a reply"
ac_log "AC5 passed"

# ── AC6: pitch_pr_put failure still holds the marker ─────────────────────────
ac_log "AC6: pitch_pr_put failure sets the flag and holds last-seen"
reset_case
PITCH_HAS_ENTRIES=0
AGENT_CHANGES_FILE=1
PUT_RC=1
architect_pr_cycle
ac_assert_eq "$_OPUS_DISPATCH_FAILED" "true" "AC6: flag should be true"
assert_marker_held "AC6"
ac_assert_eq "$(post_count)" "0" "AC6: a failed commit must not post"
[ ! -e "$PENDING_FILE" ] || ac_fail "AC6: a failed commit must not stash a reply"
ac_log "AC6 passed"

ac_pass
