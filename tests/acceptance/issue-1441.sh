#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1441.sh
#
# Issue #1441: emit_tape_proposal always uuidgen'd a new id on every pick. A
# re-queued issue (no-push -> backlog -> pick again) appended a second proposal
# for the same `ref`, so the live tape held two samples of one decision
# (observed on #1409: 13:37 and 22:27).
#
# Fix: emit_tape_proposal() checks the per-issue id file
# /tmp/dev-proposal-id-${PROJECT_NAME}-${issue}. If it is present and contains
# a non-empty id, the proposal is already on the tape — reuse that id and leave
# the file alone (log the reuse, return 0). Only mint a fresh uuid and append a
# proposal when the file is missing or empty (first pick, or a wiped /tmp).
#
# Acceptance (read-only — no live services, no agents started, no pick
# triggered; the emitter is exercised in-process with a stub curl, the same
# extract-and-stub approach as issue-1398):
#   1. two calls on the same issue leave exactly one tape line and the id file
#      unchanged across the calls — the first pick mints an id, the second
#      reuses it (reuse logged, no second proposal)
#   2. a fresh pick (no id file) still appends one proposal and writes the
#      id file (the existing #1398 behavior)
#   3. an unwritable $TAPE_DIR still returns 0 (warning logged, nothing left)
#   4. a forge API failure degrades to class="dev" / context={} and still
#      appends the record (rc 0)
#
# The stub curl (ac_write_curl_stub, tests/lib/acceptance-helpers.sh) stands in
# for the forge; AC_STUB_FAIL=1 makes it fail like an unreachable API.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

TARGET="$REPO_ROOT/dev/dev-poll.sh"

# ── 1. Wiring: dev-poll sources the tape lib and calls the emitter ─────────
# Shared wiring checks (lib helper) — the extracted source is what the
# re-pick assertions below run against.
FN_SRC="$(ac_tape_emitter_wiring "$TARGET" emit_tape_proposal \
  'emit_tape_proposal "$READY_ISSUE"')"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-1441"   # sentinel — can never clobber a live id file
trap 'rm -rf "$TMP_DIR" \
  /tmp/dev-proposal-id-acceptance-1441-1441 \
  /tmp/dev-proposal-id-acceptance-1441-1442 \
  /tmp/dev-proposal-id-acceptance-1441-1443 \
  /tmp/dev-proposal-id-acceptance-1441-1444' EXIT

# ── Stub curl: hermetic forge stand-in (no network, no live services) ───────
STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
ac_write_curl_stub "$STUB_BIN"

# The extracted emitter logs through log(); the subshells inherit this
# stand-in so those lines land in the runner's captured output.
log() { echo "poll: $*"; }

# ── 2. Re-pick: two calls on one issue -> exactly one tape line, stable id ──
# Call 1 is the first pick (no id file yet); call 2 is the re-pick and must
# hit the guard — reuse the existing id, log it, return 0, append nothing.
TAPE_REPICK="$TMP_DIR/tape-repick"
ID_REPICK="/tmp/dev-proposal-id-${PROJECT_NAME}-1441"

rc=0
out1="$(ac_run_tape_emit "$STUB_BIN" "$TAPE_REPICK" "$FN_SRC" "0" emit_tape_proposal 1441)" || rc=$?
ac_assert_eq "$rc" "0" "first pick must return 0 (got $rc): $out1"
ac_assert_file "$TAPE_REPICK/tape.jsonl" "no tape record was appended by the first pick"
ac_assert_eq "$(wc -l < "$TAPE_REPICK/tape.jsonl")" "1" \
  "first pick must append exactly one tape line"
LINE="$(head -n 1 "$TAPE_REPICK/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1441" and .class == "backlog" and .context.open_prs == 3 and (.parent | not) and (.caused_by | not)' \
  "$LINE" \
  "first-pick record must be an approved dev-loop proposal with ref 1441"
[ -f "$ID_REPICK" ] || ac_fail "id file $ID_REPICK missing after the first pick"
ID_AFTER_1="$(cat "$ID_REPICK")"
[ -n "$ID_AFTER_1" ] || ac_fail "id file must contain the recorded id"
ac_assert_eq "$(jq -r '.id' <<<"$LINE")" "$ID_AFTER_1" \
  "id file after first pick must contain exactly the recorded proposal id"

# Second call: same issue, id file present and non-empty -> guard fires.
rc=0
out2="$(ac_run_tape_emit "$STUB_BIN" "$TAPE_REPICK" "$FN_SRC" "0" emit_tape_proposal 1441)" || rc=$?
ac_assert_repick "$rc" "$out2"
ac_assert_eq "$(wc -l < "$TAPE_REPICK/tape.jsonl")" "1" \
  "two calls on one issue must leave exactly one tape line"
ac_assert_eq "$(cat "$ID_REPICK")" "$ID_AFTER_1" \
  "the id file must be unchanged by the re-pick (stable id)"
# The single line still references the first-pick id, not a minted second one.
ac_assert_eq "$(jq -r '.id' <<<"$LINE")" "$(cat "$ID_REPICK")" \
  "the (sole) tape line id must equal the id file contents after both calls"

# ── 3. First pick with no id file: append + write id file (#1398 behavior) ──
# A distinct issue number so its id file does not exist yet.
TAPE_FIRST="$TMP_DIR/tape-first"
ID_FIRST="/tmp/dev-proposal-id-${PROJECT_NAME}-1442"
rc=0
out3="$(ac_run_tape_emit "$STUB_BIN" "$TAPE_FIRST" "$FN_SRC" "0" emit_tape_proposal 1442)" || rc=$?
ac_assert_eq "$rc" "0" "first pick on a fresh issue must return 0 (got $rc): $out3"
ac_assert_eq "$(wc -l < "$TAPE_FIRST/tape.jsonl")" "1" \
  "a first pick must append exactly one tape line"
LINE="$(head -n 1 "$TAPE_FIRST/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1442" and .class == "backlog"' \
  "$LINE" \
  "fresh-issue record must be an approved dev-loop proposal with ref 1442"
ac_assert_eq "$(cat "$ID_FIRST")" "$(jq -r '.id' <<<"$LINE")" \
  "id file after a fresh first pick must contain exactly the recorded proposal id"

# ── 4. Forge API failure: degrades to {} / "dev", record still appended ────
TAPE_APIFAIL="$TMP_DIR/tape-apifail"
rc=0
out4="$(ac_run_tape_emit "$STUB_BIN" "$TAPE_APIFAIL" "$FN_SRC" "1" emit_tape_proposal 1443)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_proposal must return 0 when the forge API fails (got $rc): $out4"
LINE="$(head -n 1 "$TAPE_APIFAIL/tape.jsonl" 2>/dev/null || true)"
[ -n "$LINE" ] || ac_fail "a record must still be appended when the forge API is unreachable"
ac_assert_jq '.type == "proposal" and .class == "dev" and .context == {} and .ref == "1443"' \
  "$LINE" \
  "API failure must degrade to class=dev and context={} while still appending the record"

# ── 5. Unwritable TAPE_DIR: warning, rc 0, no record, no dangling id file ──
# A regular file as the tape dir's parent can never be created into — for any
# user, root included — so the tape writer's mkdir fails deterministically.
touch "$TMP_DIR/blocker"
TAPE_UNWRITABLE="$TMP_DIR/blocker/tape"
rc=0
out5="$(ac_run_tape_emit "$STUB_BIN" "$TAPE_UNWRITABLE" "$FN_SRC" "0" emit_tape_proposal 1444)" || rc=$?
ac_assert_eq "$rc" "0" "an unwritable TAPE_DIR must not fail the pick (got $rc): $out5"
case "$out5" in
  *"tape: failed to append"*) ;;
  *) ac_fail "unwritable TAPE_DIR must log a tape warning, got: $out5" ;;
esac
[ ! -f "$TAPE_UNWRITABLE/tape.jsonl" ] \
  || ac_fail "no tape record may be written when TAPE_DIR is unwritable"
[ ! -f "/tmp/dev-proposal-id-${PROJECT_NAME}-1444" ] \
  || ac_fail "no id file may be left behind when the tape append fails"

ac_pass
