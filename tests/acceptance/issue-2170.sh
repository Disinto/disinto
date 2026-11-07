#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2170.sh
#
# Issue #2170: a dev attempt keeps its proposal id across a container restart.
# The pick stores its proposal id only in /tmp; a restart empties /tmp and the
# attempt loses the id, so outcomes get keyed to a fresh ULID. dev_proposal_id
# (lib/dev-proposal-id.sh) reads the id file, and when it is missing or empty
# recovers the id from the tape: the newest dev proposal record for the issue
# with no merged or rejected outcome. All four id readers (emit_tape_outcome,
# the emit_tape_proposal re-pick guard, close_dev_tape_outcome, and the
# dev-agent TAPE_PROPOSAL_ID block) go through it.
#
# Hermetic: no network, no forge, no agent. Temp TAPE_DIR, fixture tapes,
# dev_proposal_id sourced directly from the lib, emitters extracted with
# ac_extract_fn, stub curl standing in for the forge.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../../tests/lib/acceptance-tape-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-tape-helpers.sh"

ac_require_cmd awk jq

LIB="$REPO_ROOT/lib/dev-proposal-id.sh"
GUARD="$REPO_ROOT/lib/tape-outcome-guard.sh"
POLL="$REPO_ROOT/dev/dev-poll.sh"
AGENT="$REPO_ROOT/dev/dev-agent.sh"
ac_assert_file "$LIB" "lib/dev-proposal-id.sh must exist"
ac_assert_file "$GUARD" "lib/tape-outcome-guard.sh must exist"
ac_assert_file "$POLL" "dev/dev-poll.sh must exist"
ac_assert_file "$AGENT" "dev/dev-agent.sh must exist"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-2170"
export PROJECT_NAME
trap 'rm -rf "$TMP_DIR" /tmp/dev-proposal-id-acceptance-2170-* /tmp/dev-proposal-started-acceptance-2170-*' EXIT

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
ac_write_curl_stub "$STUB_BIN"
log() { echo "test: $*"; }

# run_reader <tape_dir> <issue> — call dev_proposal_id in an isolated
# subshell with the fixture TAPE_DIR; stdout+stderr captured, rc preserved.
run_reader() {
  local tape_dir="$1" issue="$2"
  (
    export TAPE_DIR="$tape_dir"
    export PROJECT_NAME="$PROJECT_NAME"
    # shellcheck disable=SC1091
    source "$LIB"
    log() { echo "reader: $*"; }
    dev_proposal_id "$issue"
  ) 2>&1
}

expect_rc() { ac_assert_eq "$2" "$1" "$3"; }

# last_line <string> — last line of a captured output string
last_line() { tail -n 1 <<< "$1"; }

# ── 1. the id file wins: present + non-empty, even with an unreadable tape ──
ac_log "AC 1: a present, non-empty id file is echoed; the tape is never read"
TAPE1="$TMP_DIR/tape1"
mkdir -p "$TAPE1"
printf 'this is not json\n{{{\n' > "$TAPE1/tape.jsonl"
printf 'pid-file-71' > "/tmp/dev-proposal-id-${PROJECT_NAME}-71"
rc=0; out="$(run_reader "$TAPE1" 71)" || rc=$?
expect_rc 0 "$rc" "dev_proposal_id must return 0 with the id file present: $out"
ac_assert_eq "$out" "pid-file-71" "the id file's contents must be echoed verbatim"
case "$out" in
  *recovered*) ac_fail "the tape must not be consulted when the id file has an id, got: $out" ;;
esac
ac_log "AC 1 OK"

# ── 2. recovery: missing id file, open newest proposal on the tape ───────────
ac_log "AC 2: recovery from the tape rewrites the id file and the started file"
TAPE2="$TMP_DIR/tape2"
mkdir -p "$TAPE2"
cat > "$TAPE2/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-11-01T14:02:00Z","id":"pid-old","loop":"dev","ref":"72"}
{"type":"outcome","proposal_id":"pid-old","bits":{"merged":1,"ci_green":1}}
{"type":"run","proposal_id":"pid-old"}
{"type":"proposal","t":"2026-11-02T09:30:00Z","id":"pid-new","loop":"dev","ref":"72"}
{"type":"run","proposal_id":"pid-new"}
EOF
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-72"
rc=0; out="$(run_reader "$TAPE2" 72)" || rc=$?
expect_rc 0 "$rc" "recovery must return 0: $out"
ac_assert_eq "$(last_line "$out")" "pid-new" "the newest open dev proposal's id must be echoed"
case "$out" in
  *"tape: recovered proposal id pid-new for #72 from the tape (id file missing)"*) ;;
  *) ac_fail "recovery must log the recovery line, got: $out" ;;
esac
ac_assert_eq "$(cat "/tmp/dev-proposal-id-${PROJECT_NAME}-72")" "pid-new" \
  "recovery must write the id to the id file"
expected_epoch="$(date -u -d "2026-11-02T09:30:00Z" +%s)"
ac_assert_eq "$(cat "/tmp/dev-proposal-started-${PROJECT_NAME}-72")" "$expected_epoch" \
  "recovery must write the proposal's t as epoch seconds to the started file"

# The second call hits the fast path: no recovery log, same id.
rc=0; out="$(run_reader "$TAPE2" 72)" || rc=$?
expect_rc 0 "$rc" "the rewritten id file must return 0: $out"
ac_assert_eq "$out" "pid-new" "the rewritten id file must be echoed without a recovery log"
ac_log "AC 2 OK"

# ── 3. an empty id file is treated as missing ────────────────────────────────
ac_log "AC 3: an empty id file falls through to tape recovery"
TAPE3="$TMP_DIR/tape3"
mkdir -p "$TAPE3"
cat > "$TAPE3/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-11-03T10:00:00Z","id":"pid-empty-file","loop":"dev","ref":"73"}
EOF
printf '' > "/tmp/dev-proposal-id-${PROJECT_NAME}-73"
printf 'not-an-integer' > "/tmp/dev-proposal-started-${PROJECT_NAME}-73"
rc=0; out="$(run_reader "$TAPE3" 73)" || rc=$?
expect_rc 0 "$rc" "an empty id file must not short-circuit: $out"
ac_assert_eq "$(last_line "$out")" "pid-empty-file" "an empty id file must trigger tape recovery"
ac_assert_eq "$(cat "/tmp/dev-proposal-id-${PROJECT_NAME}-73")" "pid-empty-file" \
  "recovery must rewrite the empty id file"
ac_log "AC 3 OK"

# ── 4. a failed outcome does not close the proposal ──────────────────────────
ac_log "AC 4: newest proposal with only a failed (merged 0, not rejected) outcome is recovered"
TAPE4="$TMP_DIR/tape4"
mkdir -p "$TAPE4"
cat > "$TAPE4/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-11-04T11:00:00Z","id":"pid-failed","loop":"dev","ref":"74"}
{"type":"outcome","proposal_id":"pid-failed","bits":{"merged":0,"ci_green":0}}
EOF
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-74"
rc=0; out="$(run_reader "$TAPE4" 74)" || rc=$?
expect_rc 0 "$rc" "a failed proposal must still be recoverable: $out"
ac_assert_eq "$(last_line "$out")" "pid-failed" \
  "a failed outcome must not close the proposal (#1441 re-picks, #1646 counts failures)"
ac_log "AC 4 OK"

# ── 5. merged or rejected outcomes keep the proposal closed ──────────────────
ac_log "AC 5: newest proposal with a merged or rejected outcome is NOT recovered"
TAPE5A="$TMP_DIR/tape5a"
mkdir -p "$TAPE5A"
cat > "$TAPE5A/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-11-05T12:00:00Z","id":"pid-merged","loop":"dev","ref":"75"}
{"type":"outcome","proposal_id":"pid-merged","bits":{"merged":1,"ci_green":1}}
EOF
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-75"
rc=0; out="$(run_reader "$TAPE5A" 75)" || rc=$?
expect_rc 0 "$rc" "a merged proposal must return 0 with no id: $out"
ac_assert_eq "$out" "" "a merged proposal must yield no id"
if [ -f "/tmp/dev-proposal-id-${PROJECT_NAME}-75" ]; then
  ac_fail "a merged proposal must not write an id file"
fi

TAPE5B="$TMP_DIR/tape5b"
mkdir -p "$TAPE5B"
cat > "$TAPE5B/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-11-05T12:00:00Z","id":"pid-rejected","loop":"dev","ref":"76"}
{"type":"outcome","proposal_id":"pid-rejected","bits":{"merged":0,"rejected":true}}
EOF
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-76"
rc=0; out="$(run_reader "$TAPE5B" 76)" || rc=$?
expect_rc 0 "$rc" "a rejected proposal must return 0 with no id: $out"
ac_assert_eq "$out" "" "a rejected proposal must yield no id"
if [ -f "/tmp/dev-proposal-id-${PROJECT_NAME}-76" ]; then
  ac_fail "a rejected proposal must not write an id file"
fi
ac_log "AC 5 OK"

# ── 6. only dev-loop proposals for this exact issue match ────────────────────
ac_log "AC 6: non-dev-loop proposals and other refs are never recovered"
TAPE6="$TMP_DIR/tape6"
mkdir -p "$TAPE6"
cat > "$TAPE6/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-11-06T08:00:00Z","id":"pid-review-loop","loop":"review","ref":"77"}
{"type":"proposal","t":"2026-11-06T09:00:00Z","id":"pid-other-issue","loop":"dev","ref":"78"}
EOF
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-77"
rc=0; out="$(run_reader "$TAPE6" 77)" || rc=$?
expect_rc 0 "$rc" "a non-dev proposal must not match: $out"
ac_assert_eq "$out" "" "a review-loop proposal for the issue must not be recovered"
rc=0; out="$(run_reader "$TAPE6" 79)" || rc=$?
expect_rc 0 "$rc" "an issue with no proposal must return 0 with no id: $out"
ac_assert_eq "$out" "" "a dev proposal for another issue must not match"
ac_log "AC 6 OK"

# ── 7. no id file and no tape: nothing, rc 0 ─────────────────────────────────
ac_log "AC 7: no id file and no tape returns nothing with rc 0"
TAPE7="$TMP_DIR/tape7-empty-dir"
mkdir -p "$TAPE7"
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-80"
rc=0; out="$(run_reader "$TAPE7" 80)" || rc=$?
expect_rc 0 "$rc" "a missing tape must return 0, not crash: $out"
ac_assert_eq "$out" "" "no tape must yield no id"
if [ -f "/tmp/dev-proposal-id-${PROJECT_NAME}-80" ]; then
  ac_fail "no tape must not write an id file"
fi
ac_log "AC 7 OK"

# ── 8. the emitters recover the id when the file is missing ──────────────────
FN_EMIT="$(ac_extract_fn emit_tape_outcome "$POLL")"
[ -n "$FN_EMIT" ] || ac_fail "could not extract emit_tape_outcome() from dev-poll.sh"
FN_PROP="$(ac_extract_fn emit_tape_proposal "$POLL")"
[ -n "$FN_PROP" ] || ac_fail "could not extract emit_tape_proposal() from dev-poll.sh"
FN_CLOSE="$(ac_extract_fn close_dev_tape_outcome "$AGENT")"
[ -n "$FN_CLOSE" ] || ac_fail "could not extract close_dev_tape_outcome() from dev-agent.sh"
FN_REASON="$(ac_extract_fn dev_walk_reason_terminal "$AGENT")"
[ -n "$FN_REASON" ] || ac_fail "could not extract dev_walk_reason_terminal() from dev-agent.sh"

# run_emit_outcome <tape_dir> <issue> <pr> <merged> <ci_green>
run_emit_outcome() {
  local tape_dir="$1" issue="$2" pr="$3" merged="$4" ci_green="$5"
  (
    ac_stub_env "$STUB_BIN" "$tape_dir"
    # Mirror production: log() appends to LOGFILE, keeping stdout clean for
    # the command substitution in `id="$(dev_proposal_id "$issue")"`.
    export LOGFILE="$tape_dir/poll.log"
    log() { printf 'poll: %s\n' "$*" >> "$LOGFILE"; }
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/dev-proposal-id.sh"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/tape.sh"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/tape-outcome-guard.sh"
    eval "$FN_EMIT"
    emit_tape_outcome "$issue" "$pr" "$merged" "$ci_green"
  ) 2>&1
}

ac_log "AC 8: emit_tape_outcome with no id file keys the outcome off the recovered proposal"
TAPE8="$TMP_DIR/tape8"
mkdir -p "$TAPE8"
cat > "$TAPE8/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-11-07T15:00:00Z","id":"pid-emit-2170","loop":"dev","ref":"81"}
EOF
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-81"
rc=0; out="$(run_emit_outcome "$TAPE8" 81 42 1 1)" || rc=$?
expect_rc 0 "$rc" "emit_tape_outcome must return 0: $out"
ac_assert_eq "$(wc -l < "$TAPE8/tape.jsonl")" "2" "the outcome must be appended after the proposal"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-emit-2170" and .bits.merged == 1' \
  "$(tail -n 1 "$TAPE8/tape.jsonl")" \
  "the appended outcome must carry the recovered proposal id"
grep -qF "tape: recovered proposal id pid-emit-2170 for #81 from the tape (id file missing)" \
  "$TAPE8/poll.log" \
  || ac_fail "emit_tape_outcome must log the recovery line: $(cat "$TAPE8/poll.log")"

# The shared close runner (tests/lib/acceptance-tape-helpers.sh) reuses the
# parent's close_dev_tape_outcome()/dev_walk_reason_terminal() — eval them here.
eval "$FN_CLOSE"
eval "$FN_REASON"

ac_log "AC 8b: close_dev_tape_outcome with no id file keys the outcome off the recovered proposal"
TAPE8B="$TMP_DIR/tape8b"
mkdir -p "$TAPE8B"
cat > "$TAPE8B/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-11-07T16:00:00Z","id":"pid-close-2170","loop":"dev","ref":"82"}
EOF
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-82"
ISSUE_TEST=82
rc=0
ac_run_close_subshell "$TAPE8B" 0 "" 1 || rc=$?
expect_rc 0 "$rc" "close_dev_tape_outcome must return 0"
ac_assert_eq "$(cat "/tmp/dev-proposal-id-${PROJECT_NAME}-${ISSUE_TEST}")" "pid-close-2170" \
  "the recovery must rewrite the id file for the dev-agent too"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-close-2170" and .bits.merged == 1' \
  "$(tail -n 1 "$TAPE8B/tape.jsonl")" \
  "the dev-agent outcome must carry the recovered proposal id"

ac_log "AC 8c: the re-pick guard recovers from the tape and reuses the id instead of minting a second"
TAPE8C="$TMP_DIR/tape8c"
mkdir -p "$TAPE8C"
cat > "$TAPE8C/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-11-07T17:00:00Z","id":"pid-repick-2170","loop":"dev","ref":"83"}
EOF
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-83"
run_pick() {
  local tape_dir="$1" issue="$2"
  (
    ac_stub_env "$STUB_BIN" "$tape_dir"
    export LOGFILE="$tape_dir/poll.log"
    log() { printf 'poll: %s\n' "$*" >> "$LOGFILE"; }
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/tape.sh"
    # shellcheck disable=SC1091
    source "$LIB"
    sprint_field() { :; }
    eval "$FN_PROP"
    emit_tape_proposal "$issue"
  ) 2>&1
}
rc=0; out="$(run_pick "$TAPE8C" 83)" || rc=$?
expect_rc 0 "$rc" "the re-pick guard must return 0: $out"
ac_assert_eq "$(wc -l < "$TAPE8C/tape.jsonl")" "1" "the re-pick guard must not mint a second proposal"
grep -qF "reusing existing proposal id pid-repick-2170 for #83" "$TAPE8C/poll.log" \
  || ac_fail "the re-pick guard must reuse the recovered id: $(cat "$TAPE8C/poll.log")"
ac_log "AC 8 OK"

# ── 9. wiring: every reader goes through dev_proposal_id ─────────────────────
ac_log "AC 9: the four id readers call dev_proposal_id; no direct id-file reads remain"
grep -qF 'existing_id="$(dev_proposal_id "$issue")"' "$POLL" \
  || ac_fail "emit_tape_proposal's re-pick guard must read the id via dev_proposal_id"
grep -qF 'id="$(dev_proposal_id "$issue")"' "$POLL" \
  || ac_fail "emit_tape_outcome must read the id via dev_proposal_id"
grep -qF 'id="$(dev_proposal_id "$ISSUE")"' "$AGENT" \
  || ac_fail "close_dev_tape_outcome must read the id via dev_proposal_id"
grep -qF 'PROPOSAL_ID="$(dev_proposal_id "$ISSUE")"' "$AGENT" \
  || ac_fail "the dev-agent TAPE_PROPOSAL_ID block must read the id via dev_proposal_id"
grep -q 'source .*lib\/dev-proposal-id\.sh"' "$POLL" \
  || ac_fail "dev-poll.sh must source lib/dev-proposal-id.sh"
grep -q 'source .*lib\/dev-proposal-id\.sh"' "$AGENT" \
  || ac_fail "dev-agent.sh must source lib/dev-proposal-id.sh"
if grep -q 'cat "/tmp/dev-proposal-id' "$POLL"; then
  ac_fail "dev-poll.sh must not read the id file directly anymore"
fi
if grep -q 'cat "/tmp/dev-proposal-id' "$AGENT"; then
  ac_fail "dev-agent.sh must not read the id file directly anymore"
fi
ac_log "AC 9 OK"

# ── 10. lint ──────────────────────────────────────────────────────────────────
if command -v shellcheck >/dev/null 2>&1; then
  ac_log "AC 10: shellcheck passes on the changed scripts"
  shellcheck --severity=warning "$LIB" "$POLL" "$AGENT" \
    || ac_fail "shellcheck must pass on lib/dev-proposal-id.sh dev/dev-poll.sh dev/dev-agent.sh"
else
  ac_log "AC 10 skipped: shellcheck not installed"
fi
ac_log "AC 10 OK"

ac_pass
