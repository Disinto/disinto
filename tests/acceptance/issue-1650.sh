#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1650.sh
#
# Issue #1650: append a column to a markdown table.
#
# The calibration report gains columns from tools that run after the table
# is finished. lib/table-column.sh (no callers yet) is the shared append.
#
# Function (sourced):
#   table_append_column NAME VALUES_JSON
#     reads a markdown table on stdin, writes it with one more column.
#     Trailing whitespace of each line is dropped first. Line 1 gets
#     ` NAME |`; line 2 gets `---|`; a later line starting with `|` gets
#     ` <value> |` from VALUES_JSON["<loop>/<class>"] (first two cells,
#     trimmed), or `-` when the key is missing. Other lines pass through.
#     Invalid JSON (or not an object of strings): rc 1, print nothing.
#
# Hermetic: no network, no forge, no agent — fixture strings only.
#
# Acceptance: `bash tests/acceptance/issue-1650.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq awk
ac_assert_file "$REPO_ROOT/lib/table-column.sh" "lib/table-column.sh is missing"
ac_assert_file "$REPO_ROOT/lib/AGENTS.md" "lib/AGENTS.md is missing"

# The review (formula 3b) requires this row directly after lib/stats.sh.
# shellcheck disable=SC2016  # the row is a literal markdown cell, backticks included
ROW='| `lib/table-column.sh` | `table_append_column NAME VALUES_JSON` (#1650): appends one column to a markdown table read on stdin; a row'"'"'s value is the key `<loop>/<class>` (its first two cells) of VALUES_JSON, `-` when missing. | calibration column tools (#1651, #1652) |'
grep -qF "$ROW" "$REPO_ROOT/lib/AGENTS.md" \
  || ac_fail "lib/AGENTS.md must document table_append_column (#1650)"
awk '
  $0 ~ /\| `lib\/stats\.sh` \|/ { seen = 1; next }
  seen { if ($0 ~ /\| `lib\/table-column\.sh` \|/) ok = 1; exit }
  END { exit ok ? 0 : 1 }
' "$REPO_ROOT/lib/AGENTS.md" \
  || ac_fail "lib/table-column.sh row must sit directly after the lib/stats.sh row"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# append_col NAME JSON TABLE — source the lib in a throwaway subshell and
# feed TABLE on stdin (a here-string, so the function's rc is the pipeline
# rc and a short fixture cannot SIGPIPE). stdout -> $OUT, stderr -> $ERR,
# exit status -> $RC.
append_col() {
  local name="$1" json="$2" table="$3"
  RC=0
  OUT=""
  ERR=""
  (
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/table-column.sh"
    table_append_column "$name" "$json" <<<"$table"
  ) >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null || true)"
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
}

# The three-line table from the acceptance criteria. No trailing newline in
# the string: the here-string supplies the final newline, so the function
# sees exactly these lines.
BASE='| loop | class | n |
|---|---|---|
| dev | backlog | 3 |'
WANT='| loop | class | n | sig |
|---|---|---|---|
| dev | backlog | 3 | x:1 |'

# ── AC1: the example table gains a sig column ────────────────────────────────
ac_log "AC1: header, separator, and the dev/backlog row gain sig"
append_col sig '{"dev/backlog":"x:1"}' "$BASE"
ac_assert_eq "$RC" "0" "table_append_column must return 0 (rc=$RC) [stderr: $ERR]"
[ -z "$ERR" ] || ac_fail "happy path must not print stderr (got: $ERR)"
ac_assert_eq "$OUT" "$WANT" \
  "appended table mismatch (got '$OUT')"

# ── AC2: a row whose key is missing gets '-' ─────────────────────────────────
ac_log "AC2: a missing key prints -"
MISS='| loop | class | n |
|---|---|---|
| dev | bug | 1 |'
MISS_WANT='| loop | class | n | sig |
|---|---|---|---|
| dev | bug | 1 | - |'
append_col sig '{"dev/backlog":"x:1"}' "$MISS"
ac_assert_eq "$RC" "0" "missing-key row must return 0 (rc=$RC)"
[ -z "$ERR" ] || ac_fail "missing-key row must not print stderr (got: $ERR)"
ac_assert_eq "$OUT" "$MISS_WANT" \
  "missing key must become '-' (got '$OUT')"

# Surrounding spaces in the first two cells do not change the key.
PADDED='| loop | class | n |
|---|---|---|
|  dev  |  backlog  | 3 |'
append_col sig '{"dev/backlog":"x:1"}' "$PADDED"
ac_assert_eq "$RC" "0" "padded cells must return 0 (rc=$RC)"
ac_assert_eq "$OUT" '| loop | class | n | sig |
|---|---|---|---|
|  dev  |  backlog  | 3 | x:1 |' \
  "padded cells must still resolve dev/backlog (got '$OUT')"

# ── AC3: header and separator only — both extended, nothing else ─────────────
ac_log "AC3: a header-and-separator table is extended and nothing else"
HEAD='| loop | class | n |
|---|---|---|'
HEAD_WANT='| loop | class | n | sig |
|---|---|---|---|'
append_col sig '{"dev/backlog":"x:1"}' "$HEAD"
ac_assert_eq "$RC" "0" "header-only table must return 0 (rc=$RC)"
[ -z "$ERR" ] || ac_fail "header-only table must not print stderr (got: $ERR)"
ac_assert_eq "$OUT" "$HEAD_WANT" \
  "header-only table mismatch (got '$OUT')"

# ── AC4: invalid JSON returns 1 and prints nothing ───────────────────────────
ac_log "AC4: VALUES_JSON 'not json' returns 1 and prints nothing"
append_col sig 'not json' "$BASE"
ac_assert_eq "$RC" "1" "invalid JSON must return 1 (rc=$RC)"
ac_assert_eq "$OUT" "" "invalid JSON must print nothing (got '$OUT')"
ac_assert_eq "$ERR" "" "invalid JSON must not print stderr (got '$ERR')"

# A JSON array, and an object whose value is not a string, are not an
# object of strings — same refusal.
append_col sig '["x:1"]' "$BASE"
ac_assert_eq "$RC" "1" "a JSON array must return 1 (rc=$RC)"
ac_assert_eq "$OUT" "" "a JSON array must print nothing (got '$OUT')"
append_col sig '{"dev/backlog":1}' "$BASE"
ac_assert_eq "$RC" "1" "a non-string value must return 1 (rc=$RC)"
ac_assert_eq "$OUT" "" "a non-string value must print nothing (got '$OUT')"

# ── Trailing whitespace is dropped before the column is appended ─────────────
ac_log "trailing whitespace is dropped; a non-row line passes through"
# The data line and the prose line carry trailing spaces. The blank line
# between separator and data must survive.
TRAIL='| loop | class | n |   
|---|---|---|   

| dev | backlog | 3 |   
note stays   
'
# The assignment above ends with a newline, and the here-string adds another,
# so the function also sees a final empty line. Build the fixture without
# that extra blank by stripping the assignment's trailing newline.
TRAIL="${TRAIL%$'\n'}"
TRAIL_WANT='| loop | class | n | sig |
|---|---|---|---|

| dev | backlog | 3 | x:1 |
note stays'
append_col sig '{"dev/backlog":"x:1"}' "$TRAIL"
ac_assert_eq "$RC" "0" "trailing-whitespace table must return 0 (rc=$RC) [stderr: $ERR]"
ac_assert_eq "$OUT" "$TRAIL_WANT" \
  "trailing whitespace / pass-through mismatch (got '$OUT')"

# A second append still keys off the first two cells (the new column is not
# part of the key). This is how #1651 and #1652 stack.
ac_log "a second append still keys off loop/class"
append_col purpose '{"dev/backlog":"fix"}' "$WANT"
ac_assert_eq "$RC" "0" "second append must return 0 (rc=$RC)"
ac_assert_eq "$OUT" '| loop | class | n | sig | purpose |
|---|---|---|---|---|
| dev | backlog | 3 | x:1 | fix |' \
  "second column must key off the original cells (got '$OUT')"

ac_pass "issue #1650: append a column to a markdown table"
