#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1443.sh
#
# Issue #1443: when dev-poll records a pick, the proposal's context is
# enriched (lib/tape.sh / dev-poll.sh emit_tape_proposal()) with size_class
# and backend, on top of the unchanged open_prs:
#
#   context.open_prs  : one forge call, unchanged ({} context if it fails)
#   context.size_class: "S"|"M"|"L" from a size label (case-insensitive
#                       s|m|l), else "M"
#   context.backend   : DSH_MODEL > CLAUDE_MODEL > AGENT_HARNESS; omitted
#                       when none of the model env vars is set.  Never
#                       "area".
#
# Acceptance (read-only — no live services, no agents started, no pick
# triggered; the emitter is exercised in-process with a stub curl, the same
# extract-and-stub approach as issue-1398/1399/1409):
#   1. a pick appends exactly one proposal record (rc 0) with open_prs 3,
#      a size_class, and (when a model is set) a backend; area is absent
#   2. size_class maps size labels s/S, m/M, l/L to S/M/L (case-insensitive)
#      and defaults to M when no size label is present
#   3. backend resolves by precedence DSH_MODEL > CLAUDE_MODEL >
#      AGENT_HARNESS and is omitted when no model env is set
#   4. a forge API failure still degrades to class="dev" / context={}
#   5. an unwritable TAPE_DIR logs a warning, returns 0, and leaves no
#      record and no id file
#
# The stub curl stands in for forge: */issues/* returns the issue JSON with
# an optional size label (AC_STUB_SIZE), */pulls?state=open* returns three
# open PRs, and AC_STUB_FAIL=1 makes it fail like an unreachable API.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd jq

TARGET="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$TARGET" "dev-poll.sh must exist for the context-emitter check"

# ── 1. Wiring: dev-poll sources the tape lib and calls the emitter ─────────
grep -q '^source .*lib/tape\.sh' "$TARGET" \
  || ac_fail "dev-poll.sh must source lib/tape.sh (context wiring)"
grep -q 'emit_tape_proposal "\$READY_ISSUE"' "$TARGET" \
  || ac_fail "dev-poll.sh must call emit_tape_proposal for the picked issue"

FN_SRC="$(ac_extract_fn emit_tape_proposal "$TARGET")"
[ -n "$FN_SRC" ] || ac_fail "could not extract emit_tape_proposal() (context) from dev-poll.sh"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-1443"   # sentinel — can never clobber a live id file
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-*" 2>/dev/null || true
trap 'rm -rf "$TMP_DIR" /tmp/dev-proposal-id-acceptance-1443-*' EXIT

# ── Stub curl: hermetic forge stand-in (no network, no live services) ───────
# */issues/* answers the issue JSON (backlog primary label, plus an optional
# size label when AC_STUB_SIZE is set); */pulls?state=open* answers 3 open
# PRs; AC_STUB_FAIL=1 makes any call fail like an unreachable API.
STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
# Pick the URL from the curl arguments: it is the http(s) value, never a flag
# like -sf or -H.  (The real caller passes flags first, the URL last.)
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
if [ -n "${AC_STUB_FAIL:-}" ]; then exit 22; fi
size="${AC_STUB_SIZE:-}"
case "$url" in
  *issues*)
    if [ -n "$size" ]; then
      printf '%s' "{\"labels\":[{\"name\":\"backlog\"},{\"name\":\"$size\"}]}"
    else
      printf '%s' '{"labels":[{"name":"backlog"}]}'
    fi
    ;;
  *pulls*)
    printf '%s' '[{"n":1},{"n":2},{"n":3}]'
    ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$STUB_BIN/curl"

# The extracted emitter logs through log(); the subshells inherit this
# stand-in so its lines land in the runner's captured output.
log() { echo "poll: $*"; }

# run_emit <TAPE_DIR> <issue> <fail> <size-label> <models>
#   fail    : 0 or 1; 1 = AC_STUB_FAIL (unreachable API)
#   size-label : label to add to the issue ("s"/"m"/"l"/"S"/"M"/"L", or "" none)
#   models  : "dsh" | "claude" | "harness" | "dsh+claude" | "" (none)
# Runs the extracted function via the shared ac_run_tape_emit subshell runner
# (stub curl on PATH, real lib/tape.sh, sentinel PROJECT_NAME, caller's
# TAPE_DIR).  The prefix vars control the model env the subshell sees.
run_emit() {
  local tape_dir="$1" issue="$2" fail="${3:-0}" size="${4:-}" models="${5:-}"
  local dsh="" claude="" harness=""
  case "$models" in
    dsh)            dsh="dsh-model-1443" ;;
    claude)         claude="claude-model-1443" ;;
    harness)        harness="dsh-harness-1443" ;;
    "dsh+claude")   dsh="dsh-model-1443"; claude="claude-model-1443" ;;
  esac
  local ac_fail=""
  if [ "$fail" = "1" ]; then ac_fail="1"; fi
  DSH_MODEL="$dsh" CLAUDE_MODEL="$claude" AGENT_HARNESS="$harness" \
    AC_STUB_FAIL="$ac_fail" AC_STUB_SIZE="$size" \
    ac_run_tape_emit "$STUB_BIN" "$tape_dir" "$FN_SRC" "$fail" \
      emit_tape_proposal "$issue"
}

# ── 2. size_class + backend, per combination ─────────────────────────────────

# ── 2a. No size label → M; DSH_MODEL → backend from DSH ─────────────────────
TAPE1="$TMP_DIR/tape-1"
rc=0
out="$(run_emit "$TAPE1" 1443 0 "" dsh)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_proposal must return 0 (no size label, DSH_MODEL): $out"
ac_assert_file "$TAPE1/tape.jsonl" "no tape record was appended to $TAPE1/tape.jsonl"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "1" "a pick must append exactly one tape line"
LINE="$(head -n 1 "$TAPE1/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1443" and .class == "backlog" and .context.open_prs == 3 and .context.size_class == "M" and .context.backend == "dsh-model-1443" and (.context | has("area") | not) and (.parent | not) and (.caused_by | not) and (.forecast | not)' \
  "$LINE" \
  "no size label yields size_class M, backend from DSH_MODEL, no area/parent/caused_by/forecast"
ID_FILE="/tmp/dev-proposal-id-${PROJECT_NAME}-1443"
[ -f "$ID_FILE" ] || ac_fail "id file $ID_FILE missing after a successful pick"
ac_assert_eq "$(cat "$ID_FILE")" "$(jq -r '.id' <<<"$LINE")" \
  "the project-scoped id file must contain exactly the recorded proposal id"

# ── 2b. Size label "s" → S; CLAUDE_MODEL → backend from CLAUDE ──────────────
TAPE2="$TMP_DIR/tape-2"
rc=0
out="$(run_emit "$TAPE2" 1444 0 "s" claude)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_proposal must return 0 (size label s, CLAUDE_MODEL): $out"
LINE="$(head -n 1 "$TAPE2/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1444" and .class == "backlog" and .context.open_prs == 3 and .context.size_class == "S" and .context.backend == "claude-model-1443" and (.context | has("area") | not)' \
  "$LINE" \
  "size label s maps to size_class S, backend from CLAUDE_MODEL"

# ── 2c. Size label "L" (uppercase) → L (case-insensitive); AGENT_HARNESS ────
TAPE3="$TMP_DIR/tape-3"
rc=0
out="$(run_emit "$TAPE3" 1445 0 "L" harness)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_proposal must return 0 (uppercase size label L, AGENT_HARNESS): $out"
LINE="$(head -n 1 "$TAPE3/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1445" and .class == "backlog" and .context.open_prs == 3 and .context.size_class == "L" and .context.backend == "dsh-harness-1443" and (.context | has("area") | not)' \
  "$LINE" \
  "uppercase size label L maps to size_class L (case-insensitive), backend from AGENT_HARNESS"

# ── 2d. Size label "m" → M; DSH_MODEL+CLAUDE_MODEL → DSH wins precedence ────
TAPE4="$TMP_DIR/tape-4"
rc=0
out="$(run_emit "$TAPE4" 1446 0 "m" "dsh+claude")" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_proposal must return 0 (size label m, DSH_MODEL+CLAUDE_MODEL): $out"
LINE="$(head -n 1 "$TAPE4/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1446" and .class == "backlog" and .context.open_prs == 3 and .context.size_class == "M" and .context.backend == "dsh-model-1443" and (.context | has("area") | not)' \
  "$LINE" \
  "size label m maps to size_class M; with both DSH_MODEL and CLAUDE_MODEL set, backend must come from DSH_MODEL (precedence)"

# ── 2e. No size label, no model → size_class M, backend omitted ─────────────
TAPE5="$TMP_DIR/tape-5"
rc=0
out="$(run_emit "$TAPE5" 1447 0 "" "")" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_proposal must return 0 (no size label, no model): $out"
LINE="$(head -n 1 "$TAPE5/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1447" and .class == "backlog" and .context.open_prs == 3 and .context.size_class == "M" and (has("backend") | not) and (.context | has("area") | not)' \
  "$LINE" \
  "no model env vars yields no backend key, size_class defaults to M"

# ── 3. Forge API failure: degrades to class="dev" / context={}, rc 0 ─────────
TAPE6="$TMP_DIR/tape-6"
rc=0
out="$(run_emit "$TAPE6" 9998 1 "" "")" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_proposal must return 0 when the forge API fails (got $rc): $out"
LINE="$(head -n 1 "$TAPE6/tape.jsonl" 2>/dev/null || true)"
[ -n "$LINE" ] || ac_fail "a record must still be appended when the forge API is unreachable"
ac_assert_jq '.type == "proposal" and .class == "dev" and .context == {} and .ref == "9998" and .decision == "approved"' \
  "$LINE" \
  "API failure degrades to class=dev and context={} while still appending the record (pick proceeds)"

# ── 4. Unwritable TAPE_DIR: warning, rc 0, no record, no dangling id file ────
# A regular file as the tape dir's parent can never be created into — for any
# user, root included — so the tape writer's mkdir fails deterministically.
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-9999" 2>/dev/null || true
touch "$TMP_DIR/blocker"
TAPE7="$TMP_DIR/blocker/tape"
rc=0
out="$(run_emit "$TAPE7" 9999 0 "" "")" || rc=$?
ac_assert_eq "$rc" "0" "an unwritable TAPE_DIR must not fail the pick (got $rc): $out"
case "$out" in
  *"tape: failed to append"*) ;;
  *) ac_fail "unwritable TAPE_DIR must log a tape-append warning, got: $out" ;;
esac
[ ! -f "$TAPE7/tape.jsonl" ] || ac_fail "no tape record may be written when TAPE_DIR is unwritable"
[ ! -f "/tmp/dev-proposal-id-${PROJECT_NAME}-9999" ] \
  || ac_fail "no id file may be left behind when the tape append fails"

ac_pass
