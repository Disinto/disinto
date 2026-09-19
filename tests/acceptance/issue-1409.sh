#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1409.sh
#
# Issue #1409: planner/planner-run.sh — when the planner files a new backlog
# issue, emit a proposal record on the dev tape (lib/tape.sh):
#
#   tape_proposal <ulid> dev "<label or dev>" "" "" '{"organ":"planner"}' \
#     '{"p_success":0.5,"est_cost":0,"est_dvision":0}' "approved" "<issue>"
#
# Flat priors — calibration comes later. Tape failure warns and continues:
# the planner run is never aborted by the tape (total emitters).
#
# Acceptance criteria exercised:
#   1. wiring          — planner-run.sh sources lib/tape.sh, snapshots the
#                        open issues before the session, and runs
#                        planner_tape_tick after the session closes
#   2. emit path       — emit_planner_proposal with a fake issue number and a
#                        TAPE_DIR override appends exactly one proposal line
#                        containing the forecast block
#   3. class fallback  — an explicit label wins as class; an unreachable
#                        forge API degrades to class="dev" and still records
#   4. tick diff       — a new backlog issue emits one record; pre-existing
#                        and non-backlog (vision) issues emit none
#   5. totality        — an unwritable TAPE_DIR logs a WARNING, returns 0,
#                        and lands no record
#
# Hermetic: fake forge via curl stubs, TAPE_DIR under mktemp — no network,
# no live services.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd jq

TARGET="$REPO_ROOT/planner/planner-run.sh"
ac_assert_file "$TARGET" "planner/planner-run.sh must exist"

# ── 1. wiring ───────────────────────────────────────────────────────────────
grep -q '^source .*lib/tape\.sh' "$TARGET" \
  || ac_fail "planner-run.sh must source lib/tape.sh"
grep -q '^PLANNER_PRE_ISSUES="\$(mktemp)"' "$TARGET" \
  || ac_fail "planner-run.sh must snapshot open issues before the session"
grep -q 'planner_tape_tick "\$PLANNER_PRE_ISSUES"' "$TARGET" \
  || ac_fail "planner-run.sh must run planner_tape_tick after the session"

FN_SRC="$(ac_extract_fn emit_planner_proposal "$TARGET")"
[ -n "$FN_SRC" ] || ac_fail "could not extract emit_planner_proposal() from planner-run.sh"
JSON_SRC="$(ac_extract_fn planner_open_issues_json "$TARGET")"
[ -n "$JSON_SRC" ] || ac_fail "could not extract planner_open_issues_json() from planner-run.sh"
TICK_SRC="$(ac_extract_fn planner_tape_tick "$TARGET")"
[ -n "$TICK_SRC" ] || ac_fail "could not extract planner_tape_tick() from planner-run.sh"

# ── Hermetic forge ──────────────────────────────────────────────────────────
PROJECT_NAME="acceptance-1409"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
ac_write_curl_stub "$STUB_BIN"

# List-endpoint stub for the tick diff (ac_write_curl_stub fakes per-issue
# GETs and pulls only): */issues?state=open* → $LIST_BODY, per-issue GETs →
# the backlog+priority label object.
LIST_STUB_BIN="$TMP_DIR/bin-list"
mkdir -p "$LIST_STUB_BIN"
cat > "$LIST_STUB_BIN/curl" <<'LIST_STUB'
#!/usr/bin/env bash
# Fake forge list API — last arg is the URL.
url="$*"
case "$url" in
  *'/issues?state=open'*)
    printf '%s' "$LIST_BODY"
    ;;
  */issues/*)
    echo '{"labels":[{"name":"backlog"},{"name":"priority"}]}'
    ;;
  *)
    exit 22
    ;;
esac
LIST_STUB
chmod +x "$LIST_STUB_BIN/curl"

# log() stand-in — the extracted functions log through it; the subshell
# inherits it, so warning lines land in the runner's captured output.
# shellcheck disable=SC2034
log() { echo "planner: $*"; }

# run_emit <TAPE_DIR> <issue> [label] [fail] — run emit_planner_proposal in a
# subshell against the fake forge + TAPE_DIR; prints its output. fail=1 makes
# the stub curl always fail (API degradation).
run_emit() {
  local tape_dir="$1" issue="$2" label="${3:-}" fail="${4:-}"
  (
    ac_stub_env "$STUB_BIN" "$tape_dir"
    export FORGE_API="https://forge.example/api/v1"
    # shellcheck disable=SC1090,SC1091
    source "$REPO_ROOT/lib/tape.sh"
    eval "$FN_SRC"
    if [ "$fail" = "1" ]; then
      export AC_STUB_FAIL=1
    fi
    emit_planner_proposal "$issue" "$label"
  ) 2>&1
}

# ── 2. emit path: one proposal line with the forecast block ─────────────────
TAPE_HAPPY="$TMP_DIR/tape-happy"
HAPPY_OUT="$(run_emit "$TAPE_HAPPY" 1409 backlog)" \
  || ac_fail "emit_planner_proposal(1409) failed: $HAPPY_OUT"
ac_assert_file "$TAPE_HAPPY/tape.jsonl" "no tape record was appended"
ac_assert_eq "$(wc -l < "$TAPE_HAPPY/tape.jsonl")" "1" \
  "filing a backlog issue must append exactly one tape line"
HAPPY_LINE="$(head -n 1 "$TAPE_HAPPY/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .class == "backlog" and .ref == "1409" and .decision == "approved" and .context == {"organ":"planner"} and (.id | length > 0) and (.parent | not) and (.caused_by | not)' \
  "$HAPPY_LINE" \
  "record must be a dev-loop planner proposal"
ac_assert_jq '.forecast == {"p_success":0.5,"est_cost":0,"est_dvision":0}' \
  "$HAPPY_LINE" \
  "record must carry the flat-prior forecast block"

# ── 3. class fallback ───────────────────────────────────────────────────────
TAPE_LABEL="$TMP_DIR/tape-label"
LABEL_OUT="$(run_emit "$TAPE_LABEL" 1410 refactor)" \
  || ac_fail "emit_planner_proposal(1410, label) failed: $LABEL_OUT"
ac_assert_jq '.class == "refactor"' "$(head -n 1 "$TAPE_LABEL/tape.jsonl")" \
  "the explicit label must win as class"

TAPE_APIFAIL="$TMP_DIR/tape-apifail"
APIFAIL_OUT="$(run_emit "$TAPE_APIFAIL" 9998 '' 1)" \
  || ac_fail "emit_planner_proposal(9998, API down) must degrade, not fail: $APIFAIL_OUT"
ac_assert_file "$TAPE_APIFAIL/tape.jsonl" "API failure must still land the record"
ac_assert_jq '.class == "dev" and .ref == "9998" and .forecast == {"p_success":0.5,"est_cost":0,"est_dvision":0}' \
  "$(head -n 1 "$TAPE_APIFAIL/tape.jsonl")" \
  "API failure must degrade to class=dev and keep the forecast block"

# ── 4. tick diff: new backlog issue emits; pre-existing + vision do not ─────
TAPE_TICK="$TMP_DIR/tape-tick"
PRE_FILE="$TMP_DIR/pre-issues"
printf '100\n101\n' > "$PRE_FILE"
export LIST_BODY='[{"number":100,"labels":[{"name":"backlog"}]},{"number":101,"labels":[{"name":"priority"}]},{"number":1409,"labels":[{"name":"backlog"},{"name":"priority"}]},{"number":1411,"labels":[{"name":"vision"}]}]'
TICK_OUT="$(
  (
    export PATH="$LIST_STUB_BIN:$PATH"
    export API="https://forge.example/api/v1"
    export FORGE_API="https://forge.example/api/v1"
    export FORGE_TOKEN="stub-token"
    export TAPE_DIR="$TAPE_TICK"
    export PROJECT_NAME
    # shellcheck disable=SC1090,SC1091
    source "$REPO_ROOT/lib/tape.sh"
    eval "$FN_SRC"
    eval "$JSON_SRC"
    eval "$TICK_SRC"
    planner_tape_tick "$PRE_FILE"
  ) 2>&1
)" || ac_fail "planner_tape_tick failed: $TICK_OUT"
ac_assert_file "$TAPE_TICK/tape.jsonl" "tick must append the new backlog issue's record"
ac_assert_eq "$(wc -l < "$TAPE_TICK/tape.jsonl")" "1" \
  "only the new backlog issue may emit (pre-existing and vision issues are skipped)"
TICK_LINE="$(head -n 1 "$TAPE_TICK/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .class == "backlog" and .ref == "1409" and .forecast == {"p_success":0.5,"est_cost":0,"est_dvision":0}' \
  "$TICK_LINE" \
  "tick record must be a dev-loop proposal with the forecast block"

# ── 5. totality: unwritable TAPE_DIR warns, returns 0, lands no record ──────
touch "$TMP_DIR/blocker"
TAPE_BLOCKED="$TMP_DIR/blocker/tape"
BLOCKED_OUT="$(run_emit "$TAPE_BLOCKED" 9999 backlog)" \
  || ac_fail "an unwritable TAPE_DIR must not fail the planner run: $BLOCKED_OUT"
case "$BLOCKED_OUT" in
  *"WARNING: tape"*) ;;
  *) ac_fail "unwritable TAPE_DIR must log a tape warning, got: $BLOCKED_OUT" ;;
esac
[ ! -f "$TAPE_BLOCKED/tape.jsonl" ] \
  || ac_fail "no record may land in an unwritable TAPE_DIR"

ac_pass
