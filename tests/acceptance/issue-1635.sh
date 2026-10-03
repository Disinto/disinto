#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1635.sh
#
# Issue #1635: feat(dev): dev proposals keep the issue text and drop
# recomputable context.
#
# Contract under test (dev/dev-poll.sh, emit_tape_proposal): a pick's
# proposal now stores the issue text as a content-addressed payload and its
# context no longer carries recomputable state:
#   * payloads[0] names a file in ${TAPE_DIR}/payloads/ holding the issue's
#     {title, body} exactly as they stood at pick time;
#   * context has no size_class key (open_prs and backend only);
#   * a failing tape_payload still writes the proposal — without `payloads`;
#   * the pick survives a genuine top-level set -e context even when the
#     payload store fails.
#
# Acceptance (read-only — no live services, no agents started; the emitter is
# exercised in-process against a fake curl, mirroring the #1398 / #1619 /
# #1632 extract-and-stub convention):
#   * AC1: a stubbed pick writes one proposal whose payloads[0] points at a
#           ${TAPE_DIR}/payloads/ file holding the stub issue's title and body;
#           .context has no size_class key; the project id file holds the
#           proposal id.
#   * AC2: with the store made to fail (PAYLOAD_DIR under a regular file, so
#           its mkdir -p is impossible) the proposal is still appended but has
#           no payloads field.
#   * AC3: the same failing store under a genuine top-level set -e context (a
#           bare subshell, no `||`/`if` guard — mirroring the #1598/#1619/#1632
#           set-e regression) — rc 0, exactly one proposal, no payloads.
#   * AC4: this test exits 0 and calls ac_pass.
#
# Run via: tools/run-acceptance.sh 1635
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk jq grep mktemp head wc cat sed
ac_assert_file "$REPO_ROOT/dev/dev-poll.sh" "dev/dev-poll.sh is missing"
ac_assert_file "$REPO_ROOT/lib/tape.sh" "lib/tape.sh is missing"

# ── Wiring: dev-poll sources the tape lib and calls the emitter ─────────────
grep -q '^source .*lib/tape\.sh' "$REPO_ROOT/dev/dev-poll.sh" \
  || ac_fail "dev-poll.sh must source lib/tape.sh"
grep -qF 'emit_tape_proposal "$READY_ISSUE"' "$REPO_ROOT/dev/dev-poll.sh" \
  || ac_fail 'dev-poll.sh must call emit_tape_proposal "$READY_ISSUE"'
ac_assert_file "$REPO_ROOT/lib/tape.sh" "lib/tape.sh is missing"

# ── Extract the function under test ──────────────────────────────────────────
DEV_POLL="$REPO_ROOT/dev/dev-poll.sh"
FN_SRC="$(ac_extract_fn emit_tape_proposal "$DEV_POLL")"
[ -n "$FN_SRC" ] || ac_fail "could not extract emit_tape_proposal() from dev-poll.sh"

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1635.XXXXXX)"
PROJECT_NAME="acceptance-1635"   # sentinel — can never clobber a live id file
export PROJECT_NAME
export AC_TEST=acceptance-1635
trap 'rm -rf "$TMP_DIR" \
  /tmp/dev-proposal-id-acceptance-1635-1635 \
  /tmp/dev-proposal-id-acceptance-1635-1636 \
  /tmp/dev-proposal-id-acceptance-1635-1637 \
  /tmp/dev-proposal-started-acceptance-1635-1635 \
  /tmp/dev-proposal-started-acceptance-1635-1636 \
  /tmp/dev-proposal-started-acceptance-1635-1637' EXIT

# ── Fake forge: issues carry a title and body (the shared stub does not) ─────
STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
# Fake forge API for issue-1635 — last arg is the URL. AC_STUB_FAIL=1
# forces failure (degradation path, for completeness).
url="$*"
if [ -n "${AC_STUB_FAIL:-}" ]; then
  exit 22
fi
case "$url" in
  *'/pulls?state=open'*)
    printf '%s\n' '[{"number":1},{"number":2},{"number":3}]'
    ;;
  *'/issues/'*)
    printf '%s\n' \
      '{"id":1635,"title":"1635 keep the issue text","body":"Dev proposals keep the issue text as a payload and drop recomputable context.","labels":[{"name":"backlog"}]}'
    ;;
  *)
    exit 22
    ;;
esac
STUB
chmod +x "$STUB_BIN/curl"

# The extracted emitter logs through log(); a stand-in keeps its lines in the
# captured output.
log() { echo "poll: $*"; }

# run_emit <stub_bin> <tape_dir> <fn_src> <issue> [bare] [payload_dir] — run
# the extracted emitter in a throwaway subshell: stub curl on PATH, sentinels
# for API/FORGE_API/FORGE_TOKEN/TAPE_DIR/PAYLOAD_DIR/PROJECT_NAME, the real
# lib/tape.sh (class/parent derivation needs no sprint libs — the stub issue
# has no milestone), and the test's log() stand-in. bare=1 opens the subshell
# under a genuine top-level set -euo pipefail (the set-e regression context).
# The subshell's combined output (stdout+stderr) is printed; the exit status is
# the emitter's.
run_emit() {
  local stub_bin="$1" tape_dir="$2" fn_src="$3" issue="$4" bare payload_dir
  bare="${5:-0}"
  payload_dir="${6:-$tape_dir/payloads}"
  (
    [ "$bare" = "1" ] && set -euo pipefail
    export PATH="$stub_bin:$PATH"
    export API="https://forge.example/api/v1"
    export FORGE_API="https://forge.example/api/v1"
    export FORGE_TOKEN="stub-token"
    export TAPE_DIR="$tape_dir"
    export PAYLOAD_DIR="$payload_dir"
    export PROJECT_NAME
    # shellcheck disable=SC1090,SC1091
    source "$REPO_ROOT/lib/tape.sh"
    eval "$fn_src"
    emit_tape_proposal "$issue"
  ) 2>&1
}

# ── AC1: stubbed pick — payload holds the issue text; no size_class ───────────
ac_log "AC1: a stubbed pick stores the issue text as a payload and drops size_class"
TAPE1="$TMP_DIR/tape1"
rc=0
out1="$(run_emit "$STUB_BIN" "$TAPE1" "$FN_SRC" 1635)" || rc=$?
ac_assert_eq "$rc" "0" "AC1: emit_tape_proposal must return 0 on success (got $rc): $out1"
ac_assert_file "$TAPE1/tape.jsonl" "AC1: no proposal appended to $TAPE1/tape.jsonl"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "1" "AC1: picking must append exactly one tape line"
LINE1="$(head -n 1 "$TAPE1/tape.jsonl")"

# payload[0] names a file in ${TAPE_DIR}/payloads/
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1635" and .class == "backlog" and .context.open_prs == 3 and (.payloads != null) and (.payloads[0] | type) == "string" and (.payloads[0] | test("^[0-9a-f]{64}$"))' \
  "$LINE1" \
  "AC1: proposal must be an approved dev pick with a single 64-hex payload ref"
HASH1="$(jq -r '.payloads[0]' <<<"$LINE1")"
PAYLOAD_FILE="$TAPE1/payloads/${HASH1}"
ac_assert_file "$PAYLOAD_FILE" "AC1: no payload file at ${PAYLOAD_FILE} (expected payloads[0] = ${HASH1})"
ac_assert_jq '.title == "1635 keep the issue text" and .body == "Dev proposals keep the issue text as a payload and drop recomputable context."' \
  "$(jq -c . "$PAYLOAD_FILE")" \
  "AC1: payload file must hold the stub issue's exact title and body"
# context: no recomputable size_class key
if jq -e '.context | has("size_class")' <<<"$LINE1" >/dev/null 2>&1; then
  ac_fail "AC1: context still carries a recomputable size_class key"
fi
ac_log "AC1: payload holds the issue text; context has no size_class"

# ── AC2: failing tape_payload → proposal still written, without payloads ─────
ac_log "AC2: a failing tape_payload still writes the proposal, without payloads"
touch "$TMP_DIR/payblock"   # PAYLOAD_DIR below sits under a regular file → mkdir -p impossible
TAPE2="$TMP_DIR/tape2"
rc=0
out2="$(run_emit "$STUB_BIN" "$TAPE2" "$FN_SRC" 1636 0 "$TMP_DIR/payblock/payloads")" || rc=$?
ac_assert_eq "$rc" "0" "AC2: a failing store must not fail the pick (got $rc): $out2"
ac_assert_file "$TAPE2/tape.jsonl" "AC2: no proposal appended when the payload store fails"
ac_assert_eq "$(wc -l < "$TAPE2/tape.jsonl")" "1" "AC2: exactly one proposal even with a failing store"
LINE2="$(head -n 1 "$TAPE2/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1636" and (.payloads != null | not)' \
  "$LINE2" \
  "AC2: the proposal must still be appended but must have no payloads field when the store fails"
ac_log "AC2: failing store omits payloads but does not block the pick"

# ── AC3: failing store under a genuine set -e context ─────────────────────────
ac_log "AC3: the failing store must not kill the pick under a genuine set -e context"
rc=0
out3="$(run_emit "$STUB_BIN" "$TAPE2" "$FN_SRC" 1637 1 "$TMP_DIR/payblock/payloads")" || rc=$?
ac_assert_eq "$rc" "0" "AC3: must exit 0 under top-level set -e with a failing store (got $rc): $out3"
ac_assert_file "$TAPE2/tape.jsonl" "AC3: no proposal written under set -e with a failing store"
ac_assert_eq "$(wc -l < "$TAPE2/tape.jsonl")" "2" "AC3: exactly two proposals (AC2 + AC3, both without payloads) under set -e"
LINE3="$(tail -n 1 "$TAPE2/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1637" and (.payloads != null | not)' \
  "$LINE3" \
  "AC3: set-e + failing store still appends one payload-free proposal"
ac_log "AC3: failing store survives a genuine top-level set -e context"

# ── Static belt-and-braces: the emitter no longer computes size_class ─────────
ac_log "AC4: the extracted emitter carries no size_class derivation"
if printf '%s\n' "$FN_SRC" | grep -Eq 'size_class'; then
  ac_fail "AC4: emit_tape_proposal still references size_class"
fi
ac_log "AC4: the extracted emitter references neither size_class"

ac_log "all acceptance criteria met for issue 1635"
ac_pass
