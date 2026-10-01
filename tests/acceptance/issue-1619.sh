#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1619.sh
#
# Issue #1619: feat(dev): dev proposals take parent and class from their
# milestone's sprint.
#
# Contract under test (dev/dev-poll.sh, emit_tape_proposal): the dev proposal's
# class is the issue's milestone sprint nature, and its parent is that milestone's
# sprint proposal id (lib/sprint-tape.sh, #1618):
#   * an integer milestone id -> class = the sprint block "class:" line
#     ("deploy"/"experiment"/"internal" or "unclassed" when absent) and
#     parent = the sprint proposal id minted under $TAPE_DIR/sprints/<id>;
#   * no usable (missing / non-integer) milestone -> class "backlog", no parent;
#   * a failed sprint mint (e.g. $TAPE_DIR/sprints is not a directory) must
#     never block the pick: parent stays empty and the proposal is still written.
#
# Acceptance (read-only, hermetic — the same extract-and-stub approach as
# issue-1398 / issue-1598: the emitter is exercised in-process against a fake
# curl, no live services, no agents started):
#   * AC1: milestone id 7 carrying "class: deploy" -> dev .class "deploy" and
#          .parent == the sprint id persisted at $TAPE_DIR/sprints/7 (a real
#          minted sprint proposal is also on the tape).
#   * AC2: milestone id 8 WITHOUT a "class:" line -> dev .class "unclassed".
#   * AC3: no usable milestone -> .class "backlog", no parent.
#   * AC4: milestone id 9 with "class: deploy" but $TAPE_DIR/sprints is a
#          regular file (so the mint fails) -> the proposal is still written
#          with .class "deploy" and NO parent, and the pick survives under a
#          genuine top-level set -e context (bare subshell, no `||`/`if` guard
#          — mirroring the #1598 AC4 set-e regression).
#   * AC5: this test exits 0 and calls ac_pass.
#
# Run via: tools/run-acceptance.sh 1619
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk jq grep mktemp head wc cat

DEV_POLL="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$DEV_POLL" "dev/dev-poll.sh is missing"
ac_assert_file "$REPO_ROOT/lib/tape.sh" "lib/tape.sh is missing"
ac_assert_file "$REPO_ROOT/lib/sprint-block.sh" "lib/sprint-block.sh is missing"
ac_assert_file "$REPO_ROOT/lib/sprint-tape.sh" "lib/sprint-tape.sh is missing"

# ── Wiring: dev-poll sources the tape + sprint libs and derives class/parent ──
grep -q '^source .*lib/tape\.sh' "$DEV_POLL" \
  || ac_fail "dev-poll.sh must source lib/tape.sh"
grep -q '^source .*lib/sprint-block\.sh' "$DEV_POLL" \
  || ac_fail "dev-poll.sh must source lib/sprint-block.sh (#1619)"
grep -q '^source .*lib/sprint-tape\.sh' "$DEV_POLL" \
  || ac_fail "dev-poll.sh must source lib/sprint-tape.sh (#1619)"
grep -qE 'sprint_field|sprint_proposal_id' "$DEV_POLL" \
  || ac_fail "dev-poll.sh must derive class/parent from the milestone sprint (#1619)"
# The parent slot (4th arg to tape_proposal) must be the derived parent, not a
# hard-coded value or an empty string.
grep -qF 'tape_proposal "$id" dev "$class" "$parent"' "$DEV_POLL" \
  || ac_fail "dev-poll.sh must pass the derived parent into tape_proposal (#1619)"

# ── Extract the function under test ───────────────────────────────────────────
FN_SRC="$(ac_extract_fn emit_tape_proposal "$DEV_POLL")"
[ -n "$FN_SRC" ] || ac_fail "could not extract emit_tape_proposal() from dev-poll.sh"

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1619.XXXXXX)"
PROJECT_NAME="acceptance-1619"   # sentinel — can never clobber a live id file
export PROJECT_NAME
# Distinct issues per AC (70-73) => distinct re-pick id files; the guard never fires.
rm -f /tmp/dev-proposal-id-acceptance-1619-70 \
      /tmp/dev-proposal-id-acceptance-1619-71 \
      /tmp/dev-proposal-id-acceptance-1619-72 \
      /tmp/dev-proposal-id-acceptance-1619-73 \
      /tmp/dev-proposal-started-acceptance-1619-70 \
      /tmp/dev-proposal-started-acceptance-1619-71 \
      /tmp/dev-proposal-started-acceptance-1619-72 \
      /tmp/dev-proposal-started-acceptance-1619-73 2>/dev/null || true
trap 'rm -rf "$TMP_DIR" \
      /tmp/dev-proposal-id-acceptance-1619-70 \
      /tmp/dev-proposal-id-acceptance-1619-71 \
      /tmp/dev-proposal-id-acceptance-1619-72 \
      /tmp/dev-proposal-id-acceptance-1619-73 \
      /tmp/dev-proposal-started-acceptance-1619-70 \
      /tmp/dev-proposal-started-acceptance-1619-71 \
      /tmp/dev-proposal-started-acceptance-1619-72 \
      /tmp/dev-proposal-started-acceptance-1619-73' EXIT

# The extracted emitter logs through log(); subshells inherit this stand-in.
log() { echo "poll: $*"; }

# ── Per-AC issue JSON, keyed on the issue number the stub matches on ──────────
# The shared ac_write_curl_stub returns ONE fixed body (no milestone) for every
# issue; here each AC needs its own issue/milestone, so we build four JSON bodies
# and a stub that selects by the issue number in the request path.
JSON_DIR="$TMP_DIR/issues"
mkdir -p "$JSON_DIR"
jq -n --argjson mid 7 '{"id":70,"labels":[{"name":"backlog"}],"milestone":{"id":$mid,"description":"class: deploy"}}' > "$JSON_DIR/issue70.json"
jq -n --argjson mid 8 '{"id":71,"labels":[{"name":"backlog"}],"milestone":{"id":$mid,"description":"release notes (no class line)"}}' > "$JSON_DIR/issue71.json"
jq -n '{"id":72,"labels":[{"name":"backlog"}]}' > "$JSON_DIR/issue72.json"
jq -n --argjson mid 9 '{"id":73,"labels":[{"name":"backlog"}],"milestone":{"id":$mid,"description":"class: deploy"}}' > "$JSON_DIR/issue73.json"
export MILESTONE_JSON_DIR="$JSON_DIR"

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
# One curl stub for all four ACs: pulls -> three open PRs; issues/<n> -> the
# body for that issue number (selected from the JSON_DIR files above).
# Note: the caller invokes `curl -sf -H "<token>" "$URL"`, so the URL is not
# arg $1 (that is -sf). Scan all args for the one starting with a scheme.
cat > "$STUB_BIN/curl" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${AC_STUB_FAIL:-}" == "1" ]]; then exit 1; fi
url=""
for a in "$@"; do
  case "$a" in
    *://*) url="$a" ;;
  esac
done
if [[ "$url" == *"/pulls"* ]]; then
  printf '%s\n' '[{"state":"open"},{"state":"open"},{"state":"open"}]'
  exit 0
fi
if [[ "$url" == *"issues/"* ]]; then
  n="${url##*/issues/}"
  n="${n%%\?*}"
  printf '%s\n' "$(cat "${MILESTONE_JSON_DIR}/issue${n}.json" 2>/dev/null)"
  exit 0
fi
printf '%s\n' '{}'
STUB_EOF
chmod +x "$STUB_BIN/curl"
export STUB_BIN

# Runner for the milestone ACs: like the shared ac_run_tape_emit, but it also
# sources the two sprint libs so sprint_field() and sprint_proposal_id() are
# defined in the subshell. (The shared ac_run_tape_emit sources lib/tape.sh
# alone, so it would not know the sprint helpers.)
ac_run_sprint_emit() {
  local stub_bin="$1" tape_dir="$2" fn_src="$3" fail="$4" fn_name="$5"
  shift 5
  (
    ac_stub_env "$stub_bin" "$tape_dir"
    export FORGE_API="https://forge.example/api/v1"
    # shellcheck disable=SC1090,SC1091
    source "$REPO_ROOT/lib/tape.sh"
    source "$REPO_ROOT/lib/sprint-block.sh"
    source "$REPO_ROOT/lib/sprint-tape.sh"
    eval "$fn_src"
    if [ "$fail" = "1" ]; then
      export AC_STUB_FAIL=1
    fi
    "$fn_name" "$@"
  ) 2>&1
}

# ── AC1: milestone id 7 "class: deploy" -> .class deploy, .parent = sprint id ──
ac_log "AC1: milestone id 7 with 'class: deploy' -> dev .class deploy, .parent = the minted sprint id (sprints/7)"
TAPE1="$TMP_DIR/tape1"
mkdir -p "$TAPE1"
rc=0
out="$(ac_run_sprint_emit "$STUB_BIN" "$TAPE1" "$FN_SRC" "0" emit_tape_proposal 70)" || rc=$?
ac_assert_eq "$rc" "0" "AC1: must exit 0 (got $rc): $out"
ac_assert_file "$TAPE1/tape.jsonl" "AC1: no tape.jsonl"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "2" \
  "AC1: expect two proposals on the tape (the minted sprint + the dev pick)"
SPRINT_LINE="$(head -n 1 "$TAPE1/tape.jsonl")"
DEV_LINE="$(tail -n 1 "$TAPE1/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "sprint" and .class == "deploy" and .ref == "milestone:7"' \
  "$SPRINT_LINE" \
  "AC1: a minted sprint proposal for milestone 7 is on the tape"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "70" and .class == "deploy"' \
  "$DEV_LINE" \
  "AC1: the dev proposal is an approved dev pick (ref 70, class deploy)"
PARENT_ID="$(cat "$TAPE1/sprints/7" 2>/dev/null)"
[ -n "$PARENT_ID" ] || ac_fail "AC1: no parent id minted for milestone 7 (sprints/7 is empty or missing)"
ac_assert_jq ".parent == \"$PARENT_ID\"" "$DEV_LINE" \
  "AC1: .parent is the sprint id persisted at ${TAPE1}/sprints/7"
ac_log "AC1: class=deploy, parent=<sprints/7 id> (sprint proposal minted)"

# ── AC2: milestone id 8 WITHOUT a class line -> .class unclassed ───────────────
ac_log "AC2: milestone id 8 WITHOUT a 'class:' line -> dev .class unclassed"
TAPE2="$TMP_DIR/tape2"
mkdir -p "$TAPE2"
rc=0
out="$(ac_run_sprint_emit "$STUB_BIN" "$TAPE2" "$FN_SRC" "0" emit_tape_proposal 71)" || rc=$?
ac_assert_eq "$rc" "0" "AC2: must exit 0 (got $rc): $out"
ac_assert_file "$TAPE2/tape.jsonl" "AC2: no tape.jsonl"
ac_assert_eq "$(wc -l < "$TAPE2/tape.jsonl")" "2" \
  "AC2: expect two proposals on the tape (the minted sprint + the dev pick)"
DEV_LINE="$(tail -n 1 "$TAPE2/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "71" and .class == "unclassed"' \
  "$DEV_LINE" \
  "AC2: class unclassed when the milestone has no 'class:' line"
PARENT_ID2="$(cat "$TAPE2/sprints/8" 2>/dev/null)"
ac_assert_jq ".parent == \"$PARENT_ID2\"" "$DEV_LINE" \
  "AC2: .parent is the sprint id persisted at ${TAPE2}/sprints/8 (unclassed sprint)"
ac_log "AC2: no class line -> dev class unclassed"

# ── AC3: no usable milestone -> .class backlog, no parent ──────────────────────
ac_log "AC3: no usable milestone -> dev .class backlog, no parent"
TAPE3="$TMP_DIR/tape3"
mkdir -p "$TAPE3"
rc=0
out="$(ac_run_sprint_emit "$STUB_BIN" "$TAPE3" "$FN_SRC" "0" emit_tape_proposal 72)" || rc=$?
ac_assert_eq "$rc" "0" "AC3: must exit 0 (got $rc): $out"
ac_assert_file "$TAPE3/tape.jsonl" "AC3: no tape.jsonl"
ac_assert_eq "$(wc -l < "$TAPE3/tape.jsonl")" "1" \
  "AC3: exactly one proposal (the dev pick; no sprint is minted)"
DEV_LINE="$(tail -n 1 "$TAPE3/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "72" and .class == "backlog" and (.parent == null or .parent == "")' \
  "$DEV_LINE" \
  "AC3: class backlog with no parent when the issue has no usable milestone"
ac_log "AC3: no usable milestone -> backlog, no parent"

# ── AC4: failed mint (sprints is a regular file) -> no parent, survives set -e ─
# The mint fails because $TAPE_DIR/sprints is a file (mkdir -p cannot create it).
# The failure is wrapped (`|| parent=""`) so it must NOT trip a genuine top-level
# set -e context: run the emitter BARE (set -euo pipefail, no `||`/`if` guard)
# exactly as dev-poll.sh calls emit_tape_proposal, mirroring the #1598 AC4.
ac_log "AC4: mint failure (sprints is a file) -> proposal written with .class deploy, no parent, under genuine set -e (bare subshell)"
TAPE4="$TMP_DIR/tape4"
mkdir -p "$TAPE4"
touch "$TAPE4/sprints"   # sprints is a regular file -> mkdir -p in the mint fails
export TMP_DIR STUB_BIN JSON_DIR REPO_ROOT FN_SRC PROJECT_NAME MILESTONE_JSON_DIR TAPE4
(
  set -euo pipefail
  export PATH="$STUB_BIN:$PATH"
  export API="https://forge.example/api/v1"
  export FORGE_API="https://forge.example/api/v1"
  export FORGE_TOKEN="stub-token"
  export TAPE_DIR="$TAPE4"
  export PROJECT_NAME
  export MILESTONE_JSON_DIR
  # shellcheck disable=SC1090,SC1091
  source "$REPO_ROOT/lib/tape.sh"
  source "$REPO_ROOT/lib/sprint-block.sh"
  source "$REPO_ROOT/lib/sprint-tape.sh"
  eval "$FN_SRC"
  emit_tape_proposal 73
)
ac_assert_file "$TAPE4/tape.jsonl" "AC4: set-e kill or mint failure — no proposal line written"
ac_assert_eq "$(wc -l < "$TAPE4/tape.jsonl")" "1" "AC4: exactly one proposal (the dev pick) under set -e"
DEV_LINE="$(tail -n 1 "$TAPE4/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "73" and .class == "deploy" and (.parent == null or .parent == "")' \
  "$DEV_LINE" \
  "AC4: class deploy with no parent when the sprint mint failed (pick not blocked)"
ac_log "AC4: failed sprint mint does not block the pick; survives set -e"

ac_log "all acceptance criteria met for issue 1619"
ac_pass
