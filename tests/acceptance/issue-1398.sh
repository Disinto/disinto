#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1398.sh
#
# Issue #1398: when dev-poll picks an issue, it records the pick on the tape
# (lib/tape.sh) as a proposal record before launching dev-agent:
#
#   tape_proposal <uuid> dev "<primary label or dev>" "" "" \
#     '{"open_prs":<n>}' "" "approved" "<issue number>"
#
# and stores the record's id at /tmp/dev-proposal-id-${PROJECT_NAME}-<issue>
# (contents: just the id) so the #1399 outcome step can reference it. Any
# tape failure logs a warning and the pick proceeds unchanged.
#
# Acceptance (read-only — no live services, no agents started, no pick
# triggered; the emitter is exercised in-process with a stub curl, the same
# extract-and-stub approach as issue-1171):
#   1. a pick appends exactly one {"type":"proposal",...} line to
#      $TAPE_DIR/tape.jsonl with loop=dev, class=<primary label>,
#      context={"open_prs":<n>}, decision=approved, ref=<issue>, and no
#      parent/caused_by/forecast; the project-scoped id file contains
#      exactly that record's id
#   2. a forge API failure degrades to class="dev" / context={} and still
#      appends the record (rc 0)
#   3. an unwritable $TAPE_DIR logs a warning and returns 0 — the pick
#      proceeds, no record and no id file are left behind
#
# The stub curl (ac_write_curl_stub, tests/lib/acceptance-helpers.sh) stands
# in for the forge; AC_STUB_FAIL=1 makes it fail like an unreachable API.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd jq

TARGET="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$TARGET" "dev/dev-poll.sh must exist"

# ── 1. Wiring: dev-poll sources the tape lib and calls the emitter ─────────
grep -q '^source .*lib/tape\.sh' "$TARGET" \
  || ac_fail "dev-poll.sh must source lib/tape.sh"
grep -q 'emit_tape_proposal "\$READY_ISSUE"' "$TARGET" \
  || ac_fail "dev-poll.sh must call emit_tape_proposal for the picked issue"

FN_SRC="$(ac_extract_fn emit_tape_proposal "$TARGET")"
[ -n "$FN_SRC" ] || ac_fail "could not extract emit_tape_proposal() from dev-poll.sh"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-1398"   # sentinel — can never clobber a live id file
trap 'rm -rf "$TMP_DIR" /tmp/dev-proposal-id-acceptance-1398-1398 \
  /tmp/dev-proposal-id-acceptance-1398-9998 /tmp/dev-proposal-id-acceptance-1398-9999' EXIT

# ── Stub curl: hermetic forge stand-in (no network, no live services) ───────
# ac_write_curl_stub writes a fake forge curl: */issues/* answers a labelled
# issue, */pulls?state=open* answers 3 open PRs, */pulls/*/reviews answers 4
# reviews (2 REQUEST_CHANGES); AC_STUB_FAIL=1 makes it fail like an
# unreachable API.
STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
ac_write_curl_stub "$STUB_BIN"

# The extracted emitter logs through log(); the subshells inherit this
# stand-in so those lines land in the runner's captured output.
log() { echo "poll: $*"; }

# run_emit <TAPE_DIR> <issue> [fail] — run the extracted function via the
# shared ac_run_tape_emit subshell runner (stub curl on PATH, real
# lib/tape.sh, sentinel PROJECT_NAME, caller's TAPE_DIR); fail=1 degrades
# the stub like an unreachable API.
run_emit() {
  local tape_dir="$1" issue="$2" fail="${3:-0}"
  ac_run_tape_emit "$STUB_BIN" "$tape_dir" "$FN_SRC" "$fail" \
    emit_tape_proposal "$issue"
}

# ── 2. Happy path: one proposal record + project-scoped id file ────────────
TAPE1="$TMP_DIR/tape-happy"
rc=0
out="$(run_emit "$TAPE1" 1398)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_proposal must return 0 on success (got $rc): $out"
ac_assert_file "$TAPE1/tape.jsonl" "no tape record was appended to $TAPE1/tape.jsonl"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "1" \
  "picking an issue must append exactly one tape line"
LINE="$(head -n 1 "$TAPE1/tape.jsonl")"
# #1443 relaxed the happy-path assertion: context may now also carry size_class
# and backend. The shared stub (backlog+priority, no size label) still yields
# size_class=M, and open_prs must remain exactly 3. area must not appear.
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1398" and .class == "backlog" and .context.open_prs == 3 and .context.size_class == "M" and (.context | has("area") | not) and (.parent | not) and (.caused_by | not) and (.forecast | not)' \
  "$LINE" \
  "record must be an approved dev-loop proposal: primary label as class, open-PR count 3, size_class M, no area/parent/caused_by/forecast"
ID_FILE="/tmp/dev-proposal-id-${PROJECT_NAME}-1398"
[ -f "$ID_FILE" ] || ac_fail "id file $ID_FILE missing after a successful pick"
ac_assert_eq "$(cat "$ID_FILE")" "$(jq -r '.id' <<<"$LINE")" \
  "the project-scoped id file must contain exactly the recorded proposal id"

# ── 3. Forge API failure: degrades to {} / "dev", record still appended ────
TAPE2="$TMP_DIR/tape-apifail"
rc=0
out="$(run_emit "$TAPE2" 9998 1)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_proposal must return 0 when the forge API fails (got $rc): $out"
LINE="$(head -n 1 "$TAPE2/tape.jsonl" 2>/dev/null || true)"
[ -n "$LINE" ] || ac_fail "a record must still be appended when the forge API is unreachable"
ac_assert_jq '.type == "proposal" and .class == "dev" and .context == {} and .ref == "9998"' \
  "$LINE" \
  "API failure must degrade to class=dev and context={} while still appending the record"

# ── 4. Unwritable TAPE_DIR: warning, rc 0, no record, no dangling id file ──
# A regular file as the tape dir's parent can never be created into — for
# any user, root included — so the tape writer's mkdir fails deterministically.
touch "$TMP_DIR/blocker"
TAPE3="$TMP_DIR/blocker/tape"
rc=0
out="$(run_emit "$TAPE3" 9999)" || rc=$?
ac_assert_eq "$rc" "0" "an unwritable TAPE_DIR must not fail the pick (got $rc): $out"
case "$out" in
  *"tape: failed to append"*) ;;
  *) ac_fail "unwritable TAPE_DIR must log a tape warning, got: $out" ;;
esac
[ ! -f "$TAPE3/tape.jsonl" ] || ac_fail "no tape record may be written when TAPE_DIR is unwritable"
[ ! -f "/tmp/dev-proposal-id-${PROJECT_NAME}-9999" ] \
  || ac_fail "no id file may be left behind when the tape append fails"

ac_pass
