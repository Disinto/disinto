#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1675.sh
#
# Issue #1675: list the sprints whose soak is over.
#
# tools/sprint-due.sh walks ${TAPE_DIR}/sprints/<N> (N an integer) that have
# no <N>.done marker, reads the milestone, and prints one line per sprint
# whose soak is over:
#
#   <N><TAB><sprint proposal id from the id file>
#
# Nothing else goes to stdout. Hermetic: no network, stubbed forge_api,
# temp TAPE_DIR.
#
# Acceptance:
#   * A closed milestone with soak: 0h: one line 1<TAB><id>, and 1.soak exists
#   * soak: 7d and a .soak epoch one day old: no line
#   * An open milestone with open issues: no line, and its .soak is removed
#   * An id file with a .done marker: no line and no forge call
#   * bash tests/acceptance/issue-1675.sh exits 0 and calls ac_pass
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq date sort mktemp cmp
ac_assert_file "$REPO_ROOT/tools/sprint-due.sh" "tools/sprint-due.sh is missing"
ac_assert_file "$REPO_ROOT/lib/sprint-block.sh" "lib/sprint-block.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TAPE_DIR="$TMP_DIR/tape"
FIXTURES="$TMP_DIR/fixtures"
FAIL_DIR="$TMP_DIR/fail"
STUB_BIN="$TMP_DIR/bin"
CALLS="$TMP_DIR/calls"
mkdir -p "$TAPE_DIR/sprints" "$FIXTURES" "$FAIL_DIR" "$STUB_BIN"
: >"$CALLS"

cat >"$STUB_BIN/forge_api" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FORGE_CALLS:?}"
method="${1:-}"
path="${2:-}"
if [ "$method" != "GET" ]; then
  echo "stub: bad method ${method}" >&2
  exit 1
fi
n="${path#/milestones/}"
if [ "$path" != "/milestones/${n}" ] || ! [[ "$n" =~ ^[0-9]+$ ]]; then
  echo "stub: bad path ${path}" >&2
  exit 1
fi
if [ -f "${FORGE_FAIL_DIR:?}/${n}" ]; then
  echo "stub: forced failure for ${n}" >&2
  exit 1
fi
cat "${FORGE_FIXTURES:?}/${n}.json"
EOF
chmod +x "$STUB_BIN/forge_api"

# write_milestone N STATE OPEN CLOSED DESC — fixture the stub returns.
write_milestone() {
  local n="$1" state="$2" open_n="$3" closed_n="$4" desc="$5"
  jq -n \
    --argjson id "$n" \
    --arg state "$state" \
    --argjson open_issues "$open_n" \
    --argjson closed_issues "$closed_n" \
    --arg description "$desc" \
    '{id: $id, state: $state, open_issues: $open_issues,
      closed_issues: $closed_issues, description: $description}' \
    >"$FIXTURES/${n}.json"
}

reset_sprints() {
  rm -rf "$TAPE_DIR/sprints"
  mkdir -p "$TAPE_DIR/sprints"
  : >"$CALLS"
  rm -f "$FAIL_DIR"/*
}

# run_due — execute sprint-due.sh. stdout file $TMP_DIR/out, stderr $TMP_DIR/err,
# exit status $RC. FORGE_API is unset so a missed stub cannot fall through to curl.
run_due() {
  RC=0
  : >"$TMP_DIR/out"
  : >"$TMP_DIR/err"
  env -u FORGE_API -u FORGE_TOKEN \
    TAPE_DIR="$TAPE_DIR" \
    PATH="$STUB_BIN:${PATH}" \
    FORGE_CALLS="$CALLS" \
    FORGE_FIXTURES="$FIXTURES" \
    FORGE_FAIL_DIR="$FAIL_DIR" \
    bash "$REPO_ROOT/tools/sprint-due.sh" >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
}

# _shown FILE — captured stream with tabs visible, for a FAIL line.
_shown() {
  sed 's/\t/<TAB>/g' "$1"
}

# assert_stdout_eq FILE — byte-compare captured stdout (trailing newline counts).
assert_stdout_eq() {
  local expect="$1" why="$2"
  if ! cmp -s "$TMP_DIR/out" "$expect"; then
    ac_fail "${why} (stdout: $(_shown "$TMP_DIR/out")) [stderr: $(_shown "$TMP_DIR/err")]"
  fi
}

assert_stdout_empty() {
  local why="$1"
  if [ -s "$TMP_DIR/out" ]; then
    ac_fail "${why} (stdout: $(_shown "$TMP_DIR/out")) [stderr: $(_shown "$TMP_DIR/err")]"
  fi
}

PROP1="11111111-1111-4111-8111-111111111111"

# ── AC1: closed milestone, soak 0h, prints the line and writes 1.soak ────────
ac_log "AC1: closed milestone with soak: 0h prints 1<TAB><id> and writes 1.soak"
reset_sprints
# open_issues stays above 0: state closed is enough on its own.
write_milestone 1 closed 2 4 $'class: internal\nsoak: 0h\n'
printf '%s\n' "$PROP1" >"$TAPE_DIR/sprints/1"
# A non-id file must not become a forge call.
printf 'ignore\n' >"$TAPE_DIR/sprints/notes"
: >"$TAPE_DIR/sprints/.lock"

run_due
ac_assert_eq "$RC" "0" "sprint-due.sh must exit 0 (rc=$RC) stderr=$(cat "$TMP_DIR/err")"
printf '1\t%s\n' "$PROP1" >"$TMP_DIR/expect"
assert_stdout_eq "$TMP_DIR/expect" "AC1: stdout must be exactly one due line"
[ -f "$TAPE_DIR/sprints/1.soak" ] || ac_fail "AC1: 1.soak must exist"
epoch="$(tr -d '[:space:]' <"$TAPE_DIR/sprints/1.soak")"
[[ "$epoch" =~ ^[0-9]+$ ]] || ac_fail "AC1: 1.soak must be an epoch (got: $epoch)"
now="$(date -u +%s)"
delta=$((now - epoch))
if [ "$delta" -lt 0 ] || [ "$delta" -gt 30 ]; then
  ac_fail "AC1: 1.soak epoch $epoch is not the current epoch (now $now)"
fi
grep -qx 'GET /milestones/1' "$CALLS" \
  || ac_fail "AC1: must call forge_api GET /milestones/1 (calls: $(cat "$CALLS"))"
if grep -q 'milestones/notes\|GET /notes' "$CALLS"; then
  ac_fail "AC1: a non-integer file must not be a forge call (calls: $(cat "$CALLS"))"
fi
ac_log "AC1 OK"

# ── AC2: soak 7d, epoch one day old: not due, epoch preserved ────────────────
ac_log "AC2: soak: 7d and a .soak epoch one day old prints no line"
reset_sprints
write_milestone 2 closed 0 3 $'class: deploy\nsoak: 7d\n'
printf '%s\n' "prop-2" >"$TAPE_DIR/sprints/2"
old=$(( $(date -u +%s) - 86400 ))
printf '%s\n' "$old" >"$TAPE_DIR/sprints/2.soak"

run_due
ac_assert_eq "$RC" "0" "AC2: sprint-due.sh must exit 0 (rc=$RC)"
assert_stdout_empty "AC2: a soak that is not over must print no line"
ac_assert_eq "$(tr -d '[:space:]' <"$TAPE_DIR/sprints/2.soak")" "$old" \
  "AC2: an existing .soak epoch must not be rewritten"
ac_log "AC2 OK"

# ── AC3: open milestone with open issues: no line, .soak removed ─────────────
ac_log "AC3: open milestone with open issues prints no line and removes .soak"
reset_sprints
write_milestone 3 open 2 1 $'soak: 0h\n'
printf '%s\n' "prop-3" >"$TAPE_DIR/sprints/3"
printf '%s\n' "100" >"$TAPE_DIR/sprints/3.soak"

run_due
ac_assert_eq "$RC" "0" "AC3: sprint-due.sh must exit 0 (rc=$RC)"
assert_stdout_empty "AC3: work not done must print no line"
[ ! -e "$TAPE_DIR/sprints/3.soak" ] || ac_fail "AC3: 3.soak must be removed"
ac_log "AC3 OK"

# ── AC4: .done marker: no line and no forge call ─────────────────────────────
ac_log "AC4: an id file with a .done marker prints no line and makes no forge call"
reset_sprints
# The fixture would be due if the tool asked for it.
write_milestone 4 closed 0 1 $'soak: 0h\n'
printf '%s\n' "prop-4" >"$TAPE_DIR/sprints/4"
: >"$TAPE_DIR/sprints/4.done"
printf 'ignore\n' >"$TAPE_DIR/sprints/notes"

run_due
ac_assert_eq "$RC" "0" "AC4: sprint-due.sh must exit 0 (rc=$RC)"
assert_stdout_empty "AC4: a .done sprint must print no line"
[ ! -s "$CALLS" ] || ac_fail "AC4: a .done sprint must not call forge (calls: $(cat "$CALLS"))"
[ ! -e "$TAPE_DIR/sprints/4.soak" ] || ac_fail "AC4: a .done sprint must not write .soak"
ac_log "AC4 OK"

# ── work done without closing: open_issues 0 and closed_issues above 0 ───────
ac_log "drained open milestone with soak: 0h is due"
reset_sprints
write_milestone 5 open 0 3 $'soak: 0h\n'
printf '%s\n' "prop-5" >"$TAPE_DIR/sprints/5"
run_due
ac_assert_eq "$RC" "0" "drained milestone must exit 0 (rc=$RC)"
printf '5\tprop-5\n' >"$TMP_DIR/expect"
assert_stdout_eq "$TMP_DIR/expect" "drained open milestone must be due"
[ -f "$TAPE_DIR/sprints/5.soak" ] || ac_fail "drained milestone must write 5.soak"

# An empty milestone (nothing closed) is not done, even with soak: 0h.
reset_sprints
write_milestone 8 open 0 0 $'soak: 0h\n'
printf '%s\n' "prop-8" >"$TAPE_DIR/sprints/8"
printf '%s\n' "50" >"$TAPE_DIR/sprints/8.soak"
run_due
assert_stdout_empty "an empty milestone must not be due"
[ ! -e "$TAPE_DIR/sprints/8.soak" ] || ac_fail "an empty milestone must remove .soak"

# ── a failed forge call: one log line, skip, .soak left in place ─────────────
ac_log "a failed forge call logs once, prints nothing, and leaves .soak"
reset_sprints
printf '%s\n' "prop-6" >"$TAPE_DIR/sprints/6"
printf '%s\n' "77" >"$TAPE_DIR/sprints/6.soak"
: >"$FAIL_DIR/6"
run_due
ac_assert_eq "$RC" "0" "a failed forge call must not fail the tool (rc=$RC)"
assert_stdout_empty "a failed forge call must print nothing"
ac_assert_eq "$(tr -d '[:space:]' <"$TAPE_DIR/sprints/6.soak")" "77" \
  "a failed forge call must not remove .soak"
err_lines="$(grep -c . "$TMP_DIR/err" || true)"
ac_assert_eq "$err_lines" "1" \
  "a failed call must be one log line (got: $(cat "$TMP_DIR/err"))"
grep -q 'forge_api GET /milestones/6 failed' "$TMP_DIR/err" \
  || ac_fail "the log line must name the failed call (got: $(cat "$TMP_DIR/err"))"

# ── missing sprints dir: nothing, no forge call ──────────────────────────────
rm -rf "$TAPE_DIR"
: >"$CALLS"
run_due
ac_assert_eq "$RC" "0" "a missing sprints dir must exit 0 (rc=$RC)"
assert_stdout_empty "a missing sprints dir must print nothing"
[ ! -s "$CALLS" ] || ac_fail "a missing sprints dir must not call forge"

ac_pass "issue #1675: list the sprints whose soak is over"
