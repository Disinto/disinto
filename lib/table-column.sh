#!/usr/bin/env bash
# =============================================================================
# lib/table-column.sh — append one column to a markdown table (#1650)
#
# The calibration report gains columns (top signatures, purpose) from tools
# that run after tools/calibration.sh. Those tools must not edit the jq
# program inside calibration.sh (#1615); they append a column to the finished
# table. This is the one shared way to do that. Called by
# tools/calibration-signatures.sh (#1651); #1652 is the other planned caller.
#
# Function (sourced):
#   table_append_column NAME VALUES_JSON
#     reads a markdown table on stdin, writes it to stdout with one more
#     column at the end. Trailing whitespace of each line is dropped first.
#       * line 1 (the header) gets ` NAME |` appended
#       * line 2 (the separator) gets `---|` appended
#       * every later line that starts with `|` gets ` <value> |`, where
#         value is VALUES_JSON["<loop>/<class>"] and loop/class are that
#         line's first two cells with surrounding spaces trimmed; `-` when
#         the key is missing
#       * every other line passes through unchanged (already trimmed)
#     VALUES_JSON is a JSON object of strings. Invalid JSON, a non-object,
#     or a non-string value: return 1 and write nothing (stdin is still
#     consumed, so a pipeline writer is not SIGPIPE'd). Wrong arity: return
#     2, write nothing, one usage line on stderr.
#
# Hermetic: bash + jq. No network, no agent, no secrets (AD-006).
# =============================================================================
set -euo pipefail

# _table_drain — consume stdin and discard it. A refused call must not leave
# a pipeline writer with SIGPIPE (the refusal is "write nothing", not "do not
# read"). cat failing (closed stdin) is not an error.
_table_drain() {
  cat >/dev/null || true
}

# _table_trim_right — print $1 with trailing whitespace removed. An
# all-whitespace string prints empty. The ${...%...} form is the same idiom
# as lib/sprint-block.sh; spelled here so this file stays self-contained.
_table_trim_right() {
  local s="${1-}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# _table_trim — print $1 with leading and trailing whitespace removed.
_table_trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# _table_row_key LINE — `<loop>/<class>` from the first two pipe-cells.
# A missing cell is empty, so the key is still `loop/class` (either side
# may be blank). Cells are trimmed; the rest of the row is ignored, so a
# column appended earlier does not move the key.
_table_row_key() {
  local line="$1" rest loop class
  rest="${line#|}"
  loop="${rest%%|*}"
  rest="${rest#*|}"
  class="${rest%%|*}"
  printf '%s/%s' "$(_table_trim "$loop")" "$(_table_trim "$class")"
}

# _table_json_ok JSON — rc 0 when JSON is an object whose every value is a
# string. Parse errors and any other shape are rc 1. Nothing is printed.
_table_json_ok() {
  jq -e 'type == "object" and all(.[]; type == "string")' >/dev/null 2>&1 <<<"$1"
}

# table_append_column NAME VALUES_JSON — see the file header.
table_append_column() {
  local name json
  if [ "$#" -ne 2 ]; then
    _table_drain
    echo "table_append_column: usage: table_append_column NAME VALUES_JSON" >&2
    return 2
  fi
  name="$1"
  json="$2"

  if ! command -v jq >/dev/null 2>&1; then
    _table_drain
    echo "table_append_column: required tool missing: jq" >&2
    return 1
  fi
  if ! _table_json_ok "$json"; then
    _table_drain
    return 1
  fi

  local n=0 line key value
  while IFS= read -r line || [ -n "${line:-}" ]; do
    line="$(_table_trim_right "$line")"
    n=$((n + 1))
    if [ "$n" -eq 1 ]; then
      printf '%s\n' "${line} ${name} |"
    elif [ "$n" -eq 2 ]; then
      printf '%s\n' "${line}---|"
    elif [[ "$line" == "|"* ]]; then
      key="$(_table_row_key "$line")"
      value="$(jq -r --arg key "$key" 'if has($key) then .[$key] else "-" end' <<<"$json")"
      printf '%s\n' "${line} ${value} |"
    else
      printf '%s\n' "$line"
    fi
  done
}
