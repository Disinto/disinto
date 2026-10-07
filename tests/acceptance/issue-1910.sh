#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1910.sh — a pitch without sub-issues gets a drafted
# list, committed by architect-bot
#
# Issue #1910 (fix/architect): when a pitch (an ops-repo PR that adds
# sprints/<slug>.md) carries only its goal + sprint block — no sub-issue
# entries — the architect drafts sub-issues, commits them to the PR branch as
# `architect-bot`, and posts a summary with the lint report. It revises on
# the owner's comments; it never merges or files.
#
# The decompose state lives in architect/architect-run.sh as four new functions
# (prepare_pitch, pitch_has_entries, publish_draft, dispatch_decompose) wired
# into the main flow between Reject and q_and_a. They are never taped:
# prepare_pitch (the "before" of an undecided pitch) must not call
# formula_session_start, and no tape_* runs.
#
# Hermetic: no forge, no nomad, no repo mutation. The decompose functions are
# extracted from architect/architect-run.sh with ac_extract_fn and run in a
# throwaway subshell against stubbed pitch_pr_put / post_pr_comment. Fixtures
# are built with ac_pitch_file / ac_pitch_entry. lib/pitch.sh is sourced so
# the extracted functions' pitch_sprint_block resolves.
#
# Run via: tools/run-acceptance.sh 1910
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep diff jq

ARCHITECT_RUN="$REPO_ROOT/architect/architect-run.sh"
ac_assert_file "$ARCHITECT_RUN" "architect/architect-run.sh is missing"

PR=7
BRANCH="architect: my-sprint"
SHA="deadbeef0123456789abcdef0123456789abcdef"
PITCH_PATH="sprints/my-sprint.md"

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

PITCH_DIR="$TMP_DIR/dir"
mkdir -p "$PITCH_DIR"
PITCH_FILE="$TMP_DIR/dir/my-sprint.md"
ORIG_FILE="$PITCH_DIR/orig"
BACKLOG_FILE="$TMP_DIR/backlog.json"
COMMENT_FILE="$TMP_DIR/comment.md"
PITCH_BRANCH="$BRANCH"
PITCH_SHA="$SHA"
FACTORY_ROOT="$REPO_ROOT"
echo '[]' >"$BACKLOG_FILE"
echo 'Reply text the session wrote.' >"$COMMENT_FILE"

# ── Fixtures ──────────────────────────────────────────────────────────────────
# ac_pitch_file writes the base pitch but WITHOUT sprint markers, and its
# sprint block is always `class: internal`. pitch_sprint_block only sees the
# block between the markers, so for the AC (d) class-change case to be
# detectable the test wraps the block in markers. Every fixture here is built
# with markers, so the block is always parseable.
#
# make_pitch DIR SLUG CLASS ENTRIES... — write DIR/sprints/SLUG.md:
# ac_pitch_file (STDIN=ENTRIES) with the class line changed to CLASS and the
# sprint block wrapped in <!-- sprint:begin --> / <!-- sprint:end --> markers.
make_pitch() {
  local dir="$1" slug="$2" class="$3"
  shift 3
  local entries="" e
  for e in "$@"; do
    entries+="$e"$'\n'
  done
  { ac_pitch_file "$dir" "$slug" <<<"$entries"; }
  local f="${dir}/sprints/${slug}.md"
  sed -r "s|^class: internal$|class: ${class}|" "$f" >"$f.tmp"
  sed -r 's|^class: |<!-- sprint:begin -->\n&|' "$f.tmp" >"$f.tmp2"
  sed -r 's|^soak: 0d$|soak: 0d\n<!-- sprint:end -->|' "$f.tmp2" >"$f"
  rm -f "$f.tmp" "$f.tmp2"
}

ac_log "building fixtures with ac_pitch_file / ac_pitch_entry (sprint block wrapped in markers)"
entry_id="sub1"
one_entry="$(ac_pitch_entry "$entry_id" "" "${TMP_DIR}/one.sh")"

# AC1: orig (no entries) vs PITCH_FILE (one entry), both class: internal.
make_pitch "$TMP_DIR" "orig" "internal"
cp "$TMP_DIR/sprints/orig.md" "$ORIG_FILE"
make_pitch "$TMP_DIR" "my-sprint" "internal" "$one_entry"
cp "$TMP_DIR/sprints/my-sprint.md" "$PITCH_FILE"

# AC2: one-entry draft (class unchanged) — must commit, then comment with
# reply + lint.
mkdir -p "$TMP_DIR/ac2"
make_pitch "$TMP_DIR/ac2" "my-sprint" "internal" "$one_entry"
cp "$TMP_DIR/ac2/sprints/my-sprint.md" "$TMP_DIR/ac2/my-sprint.md"
cp "$TMP_DIR/sprints/orig.md" "$TMP_DIR/ac2/orig"
PITCH_DIR_AC2="$TMP_DIR/ac2"
PITCH_FILE_AC2="$TMP_DIR/ac2/my-sprint.md"

# AC3: PITCH_FILE == orig (byte-identical, no commit, one comment).
mkdir -p "$TMP_DIR/ac3"
cp "$TMP_DIR/sprints/orig.md" "$TMP_DIR/ac3/orig"
cp "$TMP_DIR/ac3/orig" "$TMP_DIR/ac3/my-sprint.md"
PITCH_DIR_AC3="$TMP_DIR/ac3"
PITCH_FILE_AC3="$TMP_DIR/ac3/my-sprint.md"

# AC4: PITCH_FILE class: deploy (sprint block changed) — no commit, one
# comment naming the sprint block. orig stays class: internal.
mkdir -p "$TMP_DIR/ac4"
make_pitch "$TMP_DIR/ac4" "my-sprint" "deploy"
cp "$TMP_DIR/ac4/sprints/my-sprint.md" "$TMP_DIR/ac4/my-sprint.md"
cp "$TMP_DIR/sprints/orig.md" "$TMP_DIR/ac4/orig"
PITCH_DIR_AC4="$TMP_DIR/ac4"
PITCH_FILE_AC4="$TMP_DIR/ac4/my-sprint.md"

ac_log "fixtures ready (orig, ac2, ac3, ac4)"

# ── Extract the decompose functions + stub the mutating calls ─────────────────
ac_log "extracting pitch_has_entries / publish_draft from architect/architect-run.sh"
FN_HAS_ENTRIES="$(ac_extract_fn pitch_has_entries "$ARCHITECT_RUN")"
FN_PUBLISH="$(ac_extract_fn publish_draft "$ARCHITECT_RUN")"
[ -n "$FN_HAS_ENTRIES" ] || ac_fail "ac_extract_fn did not return pitch_has_entries"
[ -n "$FN_PUBLISH" ] || ac_fail "ac_extract_fn did not return publish_draft"
ac_log "extracted pitch_has_entries + publish_draft"

# run_extracted <fn-name> <fn-source> [args...] — run the extracted function in a
# fresh subshell against the stubs. The subshell is a separate bash process, so
# everything it needs is exported (globals the function reads, the function
# source + name, and its args). lib/pitch.sh is sourced so the extracted
# functions' pitch_sprint_block resolves; lib/pitch.sh's top `set -euo pipefail`
# would re-enable -e, so it is re-disabled after sourcing.
#
# The stubs record their args so the ACs can count and match:
#   calllog    — one line per pitch_pr_put, "PITCH_PR_PUT <branch> <path> <sha>
#                <file> <message>".
#   commentlog — one "POST_COMMENT <pr>" line + the comment body per post.
run_extracted() {
  local fn_name="$1" fn_src="$2"
  shift 2
  export RUN_FN_NAME="$fn_name" RUN_FN_SRC="$fn_src" RUN_ARGV="$*"
  (
    set +eu
    export PITCH_FILE PITCH_DIR PITCH_BRANCH PITCH_PATH PITCH_SHA \
      BACKLOG_FILE COMMENT_FILE FACTORY_ROOT
    # lib/pitch.sh is pure bash (no network, no forge, no secrets). It
    # re-enables -e/-u via its `set -euo pipefail`; disable them so we can
    # assert return codes without the subshell aborting early.
    # shellcheck source=lib/pitch.sh
    source "$REPO_ROOT/lib/pitch.sh"
    set +eu
    log() { :; }
    pitch_pr_put() {
      printf 'PITCH_PR_PUT %s\n' "$*" >>"$PITCH_DIR/calllog"
    }
    post_pr_comment() {
      printf 'POST_COMMENT %s\n%s\n---END-COMMENT---\n' "$1" "$2" >>"$PITCH_DIR/commentlog"
    }
    eval "$RUN_FN_SRC"
    local argv
    IFS=$'\n' read -r -a argv <<<"$RUN_ARGV"
    "$RUN_FN_NAME" "${argv[@]}"
  )
}

# ── AC1: pitch_has_entries rc 1 on orig, rc 0 on PITCH_FILE ──────────────────
ac_log "AC1: pitch_has_entries -> 1 on orig (no entries), 0 on PITCH_FILE (one entry)"
rc=0
run_extracted pitch_has_entries "$FN_HAS_ENTRIES" "$ORIG_FILE" || rc=$?
ac_assert_eq "$rc" "1" "AC1: expected pitch_has_entries(orig) -> 1, got $rc"
rc=0
run_extracted pitch_has_entries "$FN_HAS_ENTRIES" "$PITCH_FILE" || rc=$?
ac_assert_eq "$rc" "0" "AC1: expected pitch_has_entries(PITCH_FILE) -> 0, got $rc"
ac_log "AC1 passed: orig=1, PITCH_FILE=0"

# ── AC2: one-entry draft commits once, then posts one lint comment ────────────
ac_log "AC2: publish_draft on a one-entry draft -> pitch_pr_put once + one comment with reply + lint"
PITCH_DIR="$PITCH_DIR_AC2" PITCH_FILE="$PITCH_FILE_AC2" \
  run_extracted publish_draft "$FN_PUBLISH" "$PR" "architect: draft sub-issues"
put_count="$(grep -c 'PITCH_PR_PUT' "$TMP_DIR/ac2/calllog" 2>/dev/null || true)"
[ -n "$put_count" ] || put_count=0
comment_count="$(grep -c 'POST_COMMENT' "$TMP_DIR/ac2/commentlog" 2>/dev/null || true)"
[ -n "$comment_count" ] || comment_count=0
ac_assert_eq "$put_count" "1" \
  "AC2: expected pitch_pr_put called once (branch, path, sha, file), got $put_count"
grep -q "architect: my-sprint" "$TMP_DIR/ac2/calllog" \
  || ac_fail "AC2: commit did not use the draft branch"
grep -q "sprints/my-sprint.md" "$TMP_DIR/ac2/calllog" \
  || ac_fail "AC2: commit did not use the pitch path"
grep -q "$SHA" "$TMP_DIR/ac2/calllog" \
  || ac_fail "AC2: commit did not use the pitch sha"
grep -q "Reply text the session wrote." "$TMP_DIR/ac2/commentlog" \
  || ac_fail "AC2: comment lacks the session reply"
grep -q '### Pitch lint: sprints/' "$TMP_DIR/ac2/commentlog" \
  || ac_fail "AC2: comment lacks the pitch-lint header"
ac_log "AC2 passed: one commit + one reply+lint comment"

# ── AC3: byte-identical draft -> no commit, one comment ───────────────────────
ac_log "AC3: publish_draft on a byte-identical draft -> no pitch_pr_put, one comment"
PITCH_DIR="$PITCH_DIR_AC3" PITCH_FILE="$PITCH_FILE_AC3" \
  run_extracted publish_draft "$FN_PUBLISH" "$PR" "architect: draft sub-issues"
put_count="$(grep -c 'PITCH_PR_PUT' "$TMP_DIR/ac3/calllog" 2>/dev/null || true)"
[ -n "$put_count" ] || put_count=0
comment_count="$(grep -c 'POST_COMMENT' "$TMP_DIR/ac3/commentlog" 2>/dev/null || true)"
[ -n "$comment_count" ] || comment_count=0
ac_assert_eq "$put_count" "0" \
  "AC3: expected no pitch_pr_put for an identical draft, got $put_count"
ac_assert_eq "$comment_count" "1" \
  "AC3: expected one comment for an identical draft, got $comment_count"
ac_log "AC3 passed: no commit, one comment"

# ── AC4: sprint block changed (class: deploy) -> no commit, one comment ───────
ac_log "AC4: publish_draft on a draft that changed the sprint block -> no pitch_pr_put, one comment naming the sprint block"
PITCH_DIR="$PITCH_DIR_AC4" PITCH_FILE="$PITCH_FILE_AC4" \
  run_extracted publish_draft "$FN_PUBLISH" "$PR" "architect: draft sub-issues"
put_count="$(grep -c 'PITCH_PR_PUT' "$TMP_DIR/ac4/calllog" 2>/dev/null || true)"
[ -n "$put_count" ] || put_count=0
comment_count="$(grep -c 'POST_COMMENT' "$TMP_DIR/ac4/commentlog" 2>/dev/null || true)"
[ -n "$comment_count" ] || comment_count=0
ac_assert_eq "$put_count" "0" \
  "AC4: expected no pitch_pr_put when the sprint block changed, got $put_count"
ac_assert_eq "$comment_count" "1" \
  "AC4: expected one comment when the sprint block changed, got $comment_count"
grep -q 'Draft not committed: the session changed the sprint block.' "$TMP_DIR/ac4/commentlog" \
  || ac_fail "AC4: comment does not name the sprint-block change"
ac_log "AC4 passed: no commit, one comment naming the sprint block"

# ── AC5: no tape — formula_session_start / tape_* absent ───────────────────────
ac_log "AC5: no formula_session_start / tape_(run|proposal|outcome) in architect-run.sh"
tape_match="$(grep -nE 'formula_session_start|tape_(run|proposal|outcome)' "$ARCHITECT_RUN" || true)"
[ -z "$tape_match" ] || ac_fail "AC5: found tape in architect-run.sh: $tape_match"
ac_log "AC5 passed: no tape references"

ac_pass "issue #1910: a pitch without sub-issues gets a drafted list, committed by architect-bot"
