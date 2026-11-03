#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2060.sh
#
# Issue #2060: table_append_column keys a row by loop/class/model.
#
# Once the calibration table prints a `model` cell third (#2062), a column
# tool that wants per-model values (#2063, #2064) has no way to address one
# model's row: every model row of a class got the same value. lib/table-column.sh
# now looks VALUES_JSON up at the three-cell key `<loop>/<class>/<model>`
# first, then at the two-cell key `<loop>/<class>`, then prints `-` — one jq
# call per row. A caller still keying by loop/class keeps working, and on a
# table whose third cell is `n` the three-cell key misses and the two-cell key
# hits, so the #1650 output is byte-identical.
#
# Hermetic: no network, no forge, no agent — fixture strings only.
#
# Acceptance: `bash tests/acceptance/issue-2060.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq
ac_assert_file "$REPO_ROOT/lib/table-column.sh" "lib/table-column.sh is missing"
ac_assert_file "$REPO_ROOT/lib/AGENTS.md" "lib/AGENTS.md is missing"

# ── AC0: the lib parses, and lib/AGENTS.md says the same thing ────────────────
bash -n "$REPO_ROOT/lib/table-column.sh" \
  || ac_fail "lib/table-column.sh must parse with bash -n"

# shellcheck disable=SC2016  # the sentence is a literal markdown cell, backticks included
DOC='a row'"'"'s value is VALUES_JSON at `<loop>/<class>/<model>` (its first three cells), else at `<loop>/<class>` (its first two), else `-` (#2060)'
grep -qF "$DOC" "$REPO_ROOT/lib/AGENTS.md" \
  || ac_fail "lib/AGENTS.md must document the loop/class/model key (#2060)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# col NAME JSON TABLE — source the lib in a throwaway subshell, feed TABLE on
# stdin, and park the outcome in the globals RC (status), OUT (stdout) and
# ERR (stderr).
col() {
  local name="$1" json="$2" table="$3"
  RC=0 OUT="" ERR=""
  {
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/table-column.sh"
    table_append_column "$name" "$json" <<<"$table"
  } >"$TMP_DIR/col.out" 2>"$TMP_DIR/col.err" || RC=$?
  OUT="$(cat "$TMP_DIR/col.out" 2>/dev/null || true)"
  ERR="$(cat "$TMP_DIR/col.err" 2>/dev/null || true)"
}

# A calibration-shaped table: loop, class, model, n.
MODEL='| loop | class | model | n |
|---|---|---|---|
| dev | backlog | grok-4.7 | 1 |
| dev | backlog | - | 1 |'

# ── AC1: the three-cell key wins, the two-cell key covers the rest ────────────
ac_log "AC1: dev/backlog/grok-4.7 gets its own value, the model-less row falls back"
col sig '{"dev/backlog/grok-4.7":"a","dev/backlog":"b"}' "$MODEL"
ac_assert_eq "$RC" "0" "the model-keyed append must return 0 (rc=$RC) [stderr: $ERR]"
[ -z "$ERR" ] || ac_fail "the model-keyed append must not print stderr (got: $ERR)"
ac_assert_eq "$OUT" '| loop | class | model | n | sig |
|---|---|---|---|---|
| dev | backlog | grok-4.7 | 1 | a |
| dev | backlog | - | 1 | b |' \
  "model rows must resolve at loop/class/model, falling back to loop/class (got '$OUT')"

# ── AC2: a loop/class-only key still reaches every row of that class ──────────
ac_log "AC2: a loop/class-only key covers both model rows of the class"
col sig '{"dev/backlog":"b"}' "$MODEL"
ac_assert_eq "$RC" "0" "the class-keyed append must return 0 (rc=$RC)"
ac_assert_eq "$OUT" '| loop | class | model | n | sig |
|---|---|---|---|---|
| dev | backlog | grok-4.7 | 1 | b |
| dev | backlog | - | 1 | b |' \
  "the two-cell key must still apply when no model key exists (got '$OUT')"

ac_log "AC2b: no key at all prints - on every row"
col sig '{}' "$MODEL"
ac_assert_eq "$RC" "0" "an empty VALUES_JSON must return 0 (rc=$RC)"
ac_assert_eq "$OUT" '| loop | class | model | n | sig |
|---|---|---|---|---|
| dev | backlog | grok-4.7 | 1 | - |
| dev | backlog | - | 1 | - |' \
  "a row with no key must get '-' (got '$OUT')"

# ── AC3: the #1650 table (third cell is n) is byte-identical ──────────────────
ac_log "AC3: an n-column table keys off loop/class exactly as before"
NKEY='| loop | class | n |
|---|---|---|
| dev | backlog | 3 |'
col sig '{"dev/backlog":"x:1"}' "$NKEY"
ac_assert_eq "$RC" "0" "the n-column append must return 0 (rc=$RC) [stderr: $ERR]"
ac_assert_eq "$OUT" '| loop | class | n | sig |
|---|---|---|---|
| dev | backlog | 3 | x:1 |' \
  "the loop/class fallback must reproduce the #1650 output (got '$OUT')"

# dev/backlog/3 is the three-cell key of that same row, so it must win over
# dev/backlog — the lookup order is three cells first, then two.
ac_log "AC3b: the three-cell key beats the two-cell key when both are present"
col sig '{"dev/backlog/3":"three","dev/backlog":"two"}' "$NKEY"
ac_assert_eq "$RC" "0" "the precedence check must return 0 (rc=$RC)"
ac_assert_eq "$OUT" '| loop | class | n | sig |
|---|---|---|---|
| dev | backlog | 3 | three |' \
  "loop/class/model must be tried before loop/class (got '$OUT')"

# ── AC4: invalid JSON returns 1 and writes nothing ────────────────────────────
ac_log "AC4: VALUES_JSON 'not json' returns 1 and prints nothing"
col sig 'not json' "$MODEL"
ac_assert_eq "$RC" "1" "invalid JSON must return 1 (rc=$RC)"
ac_assert_eq "$OUT" "" "invalid JSON must print nothing (got '$OUT')"
ac_assert_eq "$ERR" "" "invalid JSON must not print stderr (got '$ERR')"

# A JSON array and a non-string value are refused the same way.
col sig '["a"]' "$MODEL"
ac_assert_eq "$RC" "1" "a JSON array must return 1 (rc=$RC)"
ac_assert_eq "$OUT" "" "a JSON array must print nothing (got '$OUT')"
col sig '{"dev/backlog/grok-4.7":1}' "$MODEL"
ac_assert_eq "$RC" "1" "a non-string value must return 1 (rc=$RC)"
ac_assert_eq "$OUT" "" "a non-string value must print nothing (got '$OUT')"

ac_pass "issue #2060: table_append_column keys a row by loop/class/model"
