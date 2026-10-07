#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1908.sh — the architect's own comments are not engagement
#
# Issue #1908 (fix/architect): the architect's own PR comments must not be
# engagement. The state predicates (has_new_comment_since, has_reject_comment,
# get_reject_reason) and the new architect_has_commented filter comments by
# author, not just by time, so a posted reply does not re-wake the agent
# (reply loop, once per ARCHITECT_INTERVAL).
#
# The since-filter + architect exclusion live in a new others_comments_since
# (JSON array of get_pr_comments with .updated_at > SINCE and
# (.user.login // "") != ARCHITECT_LOGIN); the predicates read it instead of
# re-filtering get_pr_comments themselves.
#
# Hermetic: no forge, no nomad, no repo mutation. The predicates are
# extracted from architect/architect-run.sh with ac_extract_fn and run in a
# throwaway subshell against a stub get_pr_comments that echoes a fixture
# array (the COMMENT_FIXTURE env var). ARCHITECT_LOGIN=architect-bot,
# since = 2026-10-07T10:00:00Z.
#
# Run via: tools/run-acceptance.sh 1908
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk jq

ARCHITECT_RUN="$REPO_ROOT/architect/architect-run.sh"

SINCE="2026-10-07T10:00:00Z"
PR=1
ARCHITECT="architect-bot"

ac_assert_file "$ARCHITECT_RUN" "architect/architect-run.sh is missing"

# ── Extract the predicates + stub the forge ──────────────────────────────────
# The extracted functions reference ARCHITECT_LOGIN and get_pr_comments; the
# stub returns $COMMENT_FIXTURE (set per assertion) so each AC controls the
# comment thread.
ac_log "extracting comment predicates from architect/architect-run.sh"
declare -A FN_MAP=()
FN_MAP[others_comments_since]="$(ac_extract_fn others_comments_since "$ARCHITECT_RUN")"
FN_MAP[has_reject_comment]="$(ac_extract_fn has_reject_comment "$ARCHITECT_RUN")"
FN_MAP[get_reject_reason]="$(ac_extract_fn get_reject_reason "$ARCHITECT_RUN")"
FN_MAP[has_new_comment_since]="$(ac_extract_fn has_new_comment_since "$ARCHITECT_RUN")"
FN_MAP[architect_has_commented]="$(ac_extract_fn architect_has_commented "$ARCHITECT_RUN")"

for fn_name in others_comments_since has_reject_comment get_reject_reason \
    has_new_comment_since architect_has_commented; do
  fn_src="${FN_MAP[$fn_name]}"
  [ -n "$fn_src" ] || ac_fail "ac_extract_fn did not return $fn_name from architect/architect-run.sh"
done
ac_log "all five functions extracted (others_comments_since, has_reject_comment, get_reject_reason, has_new_comment_since, architect_has_commented)"

EXTRACTED=""
for fn_name in others_comments_since has_reject_comment get_reject_reason \
    has_new_comment_since architect_has_commented; do
  EXTRACTED+="${FN_MAP[$fn_name]}"
  EXTRACTED+=$'\n'
done

# run_fn <fn> [args...] — run the function in a fresh subshell with the
# extracted predicates, ARCHITECT_LOGIN, and the current COMMENT_FIXTURE stub
# get_pr_comments. The function's stdout -> stdout and its exit status -> the
# subshell's (set +e so a failing predicate does not abort the run).
run_fn() {
  local fn="$1"
  shift
  (
    # shellcheck disable=SC1090  # EXTRACTED/COMMENT_FIXTURE set by caller
    set +e
    export ARCHITECT_LOGIN="$ARCHITECT"
    export COMMENT_FIXTURE
    eval "$EXTRACTED"
    # shellcheck disable=SC2317  # defined here, called dynamically via others_comments_since et al.
    get_pr_comments() { printf '%s' "${COMMENT_FIXTURE}"; }
    "$fn" "$@"
  )
}

# assert_rc <fn> <expected-rc> [fn-args...] — run fn with the given args and
# assert its exit status equals <expected-rc>.
assert_rc() {
  local fn="$1" expect="$2"
  shift 2
  local rc=0
  run_fn "$fn" "$@" || rc=$?
  ac_assert_eq "$rc" "$expect" \
    "expected $fn($*) -> $expect, got $rc"
}

# ── AC1: architect's own since-11:00 reply + operator at 09:00 (pre-since) ────
# has_new_comment_since -> 1 (no non-architect since-comment);
# architect_has_commented -> 0 (architect has replied).
ac_log "AC1: architect's own 11:00 reply + operator 09:00 (pre-since) is not engagement"
COMMENT_FIXTURE='[
  {"id":1,"user":{"login":"architect-bot"},"updated_at":"2026-10-07T11:00:00Z","body":"Draft below"},
  {"id":2,"user":{"login":"disinto-admin"},"updated_at":"2026-10-07T09:00:00Z","body":"seen"}
]'
# Sanity: others_comments_since excludes the pre-since AND the architect reply.
oc_out="$(run_fn others_comments_since "$PR" "$SINCE")"
ac_assert_eq "$oc_out" "[]" \
  "expected others_comments_since -> [] in AC1, got: $oc_out"
assert_rc has_new_comment_since 1 "$PR" "$SINCE"
assert_rc architect_has_commented 0 "$PR"
ac_log "AC1: has_new_comment_since=1 (no re-wake), architect_has_commented=0 (replied)"

# ── AC2: operator engagement since-11:30 now wakes the architect ──────────────
ac_log "AC2: operator 11:30 since-comment wakes the architect"
COMMENT_FIXTURE='[
  {"id":1,"user":{"login":"architect-bot"},"updated_at":"2026-10-07T11:00:00Z","body":"Draft below"},
  {"id":2,"user":{"login":"disinto-admin"},"updated_at":"2026-10-07T09:00:00Z","body":"seen"},
  {"id":3,"user":{"login":"disinto-admin"},"updated_at":"2026-10-07T11:30:00Z","body":"Please split c"}
]'
# Sanity: others_comments_since now returns the operator's 11:30 comment only.
oc_out="$(run_fn others_comments_since "$PR" "$SINCE")"
ac_assert_jq '.[0].user.login == "disinto-admin" and .[0].updated_at > "2026-10-07T10:00:00Z"' "$oc_out" \
  "expected the 11:30 operator comment in AC2 others_comments_since, got: $oc_out"
assert_rc has_new_comment_since 0 "$PR" "$SINCE"
ac_log "AC2: has_new_comment_since=0 (operator engagement since marker)"

# ── AC3: Reject: attribution ───────────────────────────────────────────────────
# 3a. architect's own "Reject: x" is not a reject from an operator.
ac_log "AC3a: architect's own 'Reject: x' is not an operator reject"
COMMENT_FIXTURE='[
  {"id":1,"user":{"login":"architect-bot"},"updated_at":"2026-10-07T11:00:00Z","body":"Reject: x"}
]'
assert_rc has_reject_comment 1 "$PR" "$SINCE"
# 3b. operator "Reject: duplicate" is a real reject; reason extracted.
ac_log "AC3b: operator 'Reject: duplicate' rejects and reason is 'duplicate'"
COMMENT_FIXTURE='[
  {"id":1,"user":{"login":"disinto-admin"},"updated_at":"2026-10-07T11:00:00Z","body":"Reject: duplicate"}
]'
assert_rc has_reject_comment 0 "$PR" "$SINCE"
rc=0
reason_out="$(run_fn get_reject_reason "$PR" "$SINCE")" || rc=$?
ac_assert_eq "$rc" "0" "expected get_reject_reason -> 0, got $rc"
ac_assert_eq "$reason_out" "duplicate" \
  "expected get_reject_reason -> 'duplicate', got: $reason_out"
ac_log "AC3: has_reject_comment honors author; get_reject_reason -> duplicate"

# ── AC4: no architect comment at all ──────────────────────────────────────────
ac_log "AC4: no architect comment -> architect_has_commented=1"
COMMENT_FIXTURE='[
  {"id":1,"user":{"login":"disinto-admin"},"updated_at":"2026-10-07T11:30:00Z","body":"Please split c"}
]'
assert_rc architect_has_commented 1 "$PR"

ac_pass
