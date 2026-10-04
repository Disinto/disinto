#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1737.sh
#
# Issue #1737: a merge is recorded on the tape once. dev-poll
# (emit_tape_outcome) and the dev agent (close_dev_tape_outcome) both used
# to append a merged outcome for the same proposal. tape_has_merged_outcome
# is the shared check; both writers skip when the tape already holds one.
# A non-merge outcome is still appended.
#
# Hermetic: no network, no forge, no agent. Temp TAPE_DIR, fixture tape,
# emitters extracted with ac_extract_fn. Stub curl stands in for the forge.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk jq

GUARD="$REPO_ROOT/lib/tape-outcome-guard.sh"
POLL="$REPO_ROOT/dev/dev-poll.sh"
AGENT="$REPO_ROOT/dev/dev-agent.sh"
ac_assert_file "$GUARD" "lib/tape-outcome-guard.sh must exist"
ac_assert_file "$POLL" "dev/dev-poll.sh must exist"
ac_assert_file "$AGENT" "dev/dev-agent.sh must exist"

# Both writers source the guard after lib/tape.sh.
source_after_tape() {
  local file="$1" label="$2"
  awk '
    /source .*lib\/tape\.sh"/ { seen = 1 }
    /source .*lib\/tape-outcome-guard\.sh"/ { if (seen) found = 1 }
    END { exit found ? 0 : 1 }
  ' "$file" || ac_fail "$label must source lib/tape-outcome-guard.sh after lib/tape.sh"
}
source_after_tape "$POLL" "dev-poll.sh"
source_after_tape "$AGENT" "dev-agent.sh"

FN_EMIT="$(ac_extract_fn emit_tape_outcome "$POLL")"
[ -n "$FN_EMIT" ] || ac_fail "could not extract emit_tape_outcome() from dev-poll.sh"
FN_CLOSE="$(ac_extract_fn close_dev_tape_outcome "$AGENT")"
[ -n "$FN_CLOSE" ] || ac_fail "could not extract close_dev_tape_outcome() from dev-agent.sh"
FN_REASON="$(ac_extract_fn dev_walk_reason_terminal "$AGENT")"
[ -n "$FN_REASON" ] || ac_fail "could not extract dev_walk_reason_terminal() from dev-agent.sh"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-1737"
export PROJECT_NAME
trap 'rm -rf "$TMP_DIR" /tmp/dev-proposal-id-acceptance-1737-* /tmp/dev-proposal-started-acceptance-1737-*' EXIT

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
ac_write_curl_stub "$STUB_BIN"
log() { echo "poll: $*"; }

# expect_rc <expected> <actual> <what>
expect_rc() {
  ac_assert_eq "$2" "$1" "$3 (got $2)"
}

# line_count <tape_dir>
line_count() {
  if [ -f "$1/tape.jsonl" ]; then
    wc -l < "$1/tape.jsonl"
  else
    echo 0
  fi
}

# ── 1. tape_has_merged_outcome on a fixture tape ────────────────────────────
ac_log "AC 1: tape_has_merged_outcome fixture cases"
FIXTURE="$TMP_DIR/fixture"
mkdir -p "$FIXTURE"
cat > "$FIXTURE/tape.jsonl" <<'EOF'
{"type":"proposal","id":"pid-merged-1"}
{"type":"outcome","proposal_id":"pid-merged-1","bits":{"merged":1,"ci_green":1}}
{"type":"outcome","proposal_id":"pid-merged-true","bits":{"merged":true}}
{"type":"outcome","proposal_id":"pid-merged-0","bits":{"merged":0,"ci_green":0}}
{"type":"run","proposal_id":"pid-run-only","bits":{"merged":1}}
{"type":"outcome","proposal_id":"pid-other","bits":{"merged":1}}
EOF

guard_rc() {
  local tape_dir="$1"
  shift
  (
    export TAPE_DIR="$tape_dir"
    # shellcheck disable=SC1091
    source "$GUARD"
    tape_has_merged_outcome "$@"
  )
}

rc=0
guard_rc "$FIXTURE" pid-merged-1 >/dev/null || rc=$?
expect_rc 0 "$rc" "bits.merged 1 must return 0"
rc=0
guard_rc "$FIXTURE" pid-merged-true >/dev/null || rc=$?
expect_rc 0 "$rc" "bits.merged true must return 0"
rc=0
guard_rc "$FIXTURE" pid-merged-0 >/dev/null || rc=$?
expect_rc 1 "$rc" "only merged 0 must return 1"
rc=0
guard_rc "$FIXTURE" pid-unknown >/dev/null || rc=$?
expect_rc 1 "$rc" "unknown id must return 1"
rc=0
guard_rc "$FIXTURE" pid-run-only >/dev/null || rc=$?
expect_rc 1 "$rc" "a non-outcome with merged 1 must return 1"
rc=0
guard_rc "$FIXTURE" "" >/dev/null || rc=$?
expect_rc 1 "$rc" "empty id must return 1"
MISSING="$TMP_DIR/missing-tape"
mkdir -p "$MISSING"
rc=0
guard_rc "$MISSING" pid-merged-1 >/dev/null || rc=$?
expect_rc 1 "$rc" "missing tape file must return 1"
ac_log "AC 1 OK"

# run_emit <tape_dir> <issue> <pr> <merged> <ci_green>
run_emit() {
  local tape_dir="$1" issue="$2" pr="$3" merged="$4" ci_green="$5"
  (
    ac_stub_env "$STUB_BIN" "$tape_dir"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/tape.sh"
    # shellcheck disable=SC1091
    source "$GUARD"
    eval "$FN_EMIT"
    emit_tape_outcome "$issue" "$pr" "$merged" "$ci_green"
  ) 2>&1
}

# ── 2. emit_tape_outcome skips a second merge, appends the first ────────────
ac_log "AC 2: emit_tape_outcome merged 1 skips when already recorded"
TAPE_SKIP="$TMP_DIR/emit-skip"
mkdir -p "$TAPE_SKIP"
printf '%s\n' '{"type":"outcome","proposal_id":"pid-emit-skip","bits":{"merged":1,"ci_green":1},"numbers":{"review_rounds":2}}' \
  > "$TAPE_SKIP/tape.jsonl"
before="$(cat "$TAPE_SKIP/tape.jsonl")"
printf '%s' "pid-emit-skip" > "/tmp/dev-proposal-id-${PROJECT_NAME}-17371"
rc=0
out="$(run_emit "$TAPE_SKIP" 17371 42 1 1)" || rc=$?
expect_rc 0 "$rc" "emit_tape_outcome skip must return 0: $out"
ac_assert_eq "$(line_count "$TAPE_SKIP")" "1" "a second merged outcome must not be appended: $out"
ac_assert_eq "$(cat "$TAPE_SKIP/tape.jsonl")" "$before" "skip must leave the fixture line unchanged"
case "$out" in
  *"tape: merged outcome for #17371 already recorded — skipping"*) ;;
  *) ac_fail "skip must log the already-recorded line, got: $out" ;;
esac

ac_log "AC 2b: emit_tape_outcome merged 1 appends when none exists"
TAPE_NEW="$TMP_DIR/emit-new"
mkdir -p "$TAPE_NEW"
printf '%s' "pid-emit-new" > "/tmp/dev-proposal-id-${PROJECT_NAME}-17372"
rc=0
out="$(run_emit "$TAPE_NEW" 17372 43 1 1)" || rc=$?
expect_rc 0 "$rc" "emit_tape_outcome must return 0 when appending: $out"
ac_assert_eq "$(line_count "$TAPE_NEW")" "1" "a first merged outcome must be appended"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-emit-new" and .bits == {"merged":1,"ci_green":1} and .numbers.review_rounds == 2 and .children == {} and .payloads == []' \
  "$(head -n 1 "$TAPE_NEW/tape.jsonl")" \
  "a first merged outcome must keep today's shape"
ac_log "AC 2 OK"

# run_close <tape_dir> <issue> <walk_rc>
run_close() {
  local tape_dir="$1" issue="$2" walk_rc="$3"
  (
    export TAPE_DIR="$tape_dir"
    export PROJECT_NAME="$PROJECT_NAME"
    export ISSUE="$issue"
    export PR_WALK_RC="$walk_rc"
    _DEV_REFUSAL_STATUS=""
    _PR_WALK_EXIT_REASON=""
    _DEV_TAPE_OUTCOME_WRITTEN=0
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/tape.sh"
    # shellcheck disable=SC1091
    source "$GUARD"
    eval "$FN_CLOSE"
    eval "$FN_REASON"
    signature_for() { :; }
    close_dev_tape_outcome
  ) 2>&1
}

# ── 3. close_dev_tape_outcome skips a merged walk already on the tape ───────
ac_log "AC 3: close_dev_tape_outcome skips a merged walk already recorded"
TAPE_CLOSE="$TMP_DIR/close-skip"
mkdir -p "$TAPE_CLOSE"
printf '%s\n' '{"type":"outcome","proposal_id":"pid-close-skip","bits":{"merged":1}}' \
  > "$TAPE_CLOSE/tape.jsonl"
printf '%s' "pid-close-skip" > "/tmp/dev-proposal-id-${PROJECT_NAME}-17373"
rc=0
out="$(run_close "$TAPE_CLOSE" 17373 0)" || rc=$?
expect_rc 0 "$rc" "close_dev_tape_outcome skip must return 0: $out"
ac_assert_eq "$(line_count "$TAPE_CLOSE")" "1" \
  "a merged walk must append nothing when a merged outcome exists: $out"
case "$out" in
  *"already recorded — skipping"*) ;;
  *) ac_fail "close skip must log that the merge was already recorded, got: $out" ;;
esac
ac_log "AC 3 OK"

# ── 4. a failed outcome is still appended when a merged one exists ──────────
ac_log "AC 4: merged 0 is still appended when a merged outcome exists"
TAPE_FAIL="$TMP_DIR/emit-fail"
mkdir -p "$TAPE_FAIL"
printf '%s\n' '{"type":"outcome","proposal_id":"pid-emit-fail","bits":{"merged":1}}' \
  > "$TAPE_FAIL/tape.jsonl"
printf '%s' "pid-emit-fail" > "/tmp/dev-proposal-id-${PROJECT_NAME}-17374"
rc=0
out="$(run_emit "$TAPE_FAIL" 17374 44 0 0)" || rc=$?
expect_rc 0 "$rc" "emit_tape_outcome merged 0 must return 0: $out"
ac_assert_eq "$(line_count "$TAPE_FAIL")" "2" \
  "a failed emit must still append when a merged outcome exists: $out"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-emit-fail" and .bits.merged == 0' \
  "$(tail -n 1 "$TAPE_FAIL/tape.jsonl")" \
  "the appended failed emit must record merged 0"

TAPE_CLOSE_FAIL="$TMP_DIR/close-fail"
mkdir -p "$TAPE_CLOSE_FAIL"
printf '%s\n' '{"type":"outcome","proposal_id":"pid-close-fail","bits":{"merged":true}}' \
  > "$TAPE_CLOSE_FAIL/tape.jsonl"
printf '%s' "pid-close-fail" > "/tmp/dev-proposal-id-${PROJECT_NAME}-17375"
rc=0
out="$(run_close "$TAPE_CLOSE_FAIL" 17375 1)" || rc=$?
expect_rc 0 "$rc" "close_dev_tape_outcome failure walk must return 0: $out"
ac_assert_eq "$(line_count "$TAPE_CLOSE_FAIL")" "2" \
  "a failed walk must still append when a merged outcome exists: $out"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-close-fail" and .bits.merged == 0' \
  "$(tail -n 1 "$TAPE_CLOSE_FAIL/tape.jsonl")" \
  "the appended failed walk must record merged 0"
ac_log "AC 4 OK"

ac_pass
