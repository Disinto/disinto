#!/usr/bin/env bash
# =============================================================================
# tools/calibration-signatures.sh — top signatures column on the calibration
# table (#1651)
#
# tools/calibration.sh says how often a class came back, not why. Rejections
# carry signatures too (needs-ops, design-conflict) and are correct refusals,
# not failures, so this column is not limited to failures. It is a separate
# tool (not a change to the jq program inside calibration.sh, #1615): it reads
# the finished table on stdin and writes it to stdout with a `top signatures`
# column appended via table_append_column (lib/table-column.sh, #1650).
#
# Per `<loop>/<class>` the labels are:
#   * the `signature` of the last outcome, in tape order, of each proposal on
#     ${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl whose loop and class match.
#     A proposal with no outcome, or whose last outcome has no signature, adds
#     nothing. An earlier outcome's signature is not a fallback.
#   * one `stuck` for each sample of that loop and class printed by
#     ${TAPE_STUCK_TOOL:-<this dir>/tape-stuck.sh}, run with no arguments
#     (#1648). The sample's own signature field is not read — the label is
#     always `stuck`.
#
# The cell is up to three labels as `name:count`, comma-separated, most
# frequent first, ties broken by name. No label: the key is left out of the
# values object, so the row prints `-`.
#
# Tape only. No rubric is read. A malformed tape line (a torn final line) is
# skipped by the reader and never fails the report.
#
# Usage:
#   tools/calibration.sh | tools/calibration-signatures.sh
#
# Environment:
#   TAPE_DIR         tape directory (default /srv/disinto/tape)
#   TAPE_STUCK_TOOL  stuck-proposal reader (default <this dir>/tape-stuck.sh);
#                    run with no arguments; a non-zero exit fails this tool
#
# Exit codes:
#   0  table printed, with the column appended
#   1  jq missing, the stuck tool failed or did not print a JSON array, or
#      the tape could not be read. Nothing is written (stdin is still
#      consumed, so a pipeline writer is not SIGPIPE'd).
#
# Hermetic aside from the tape dir and the stuck tool it is pointed at. No
# network, no agent, no secrets (AD-006). Does not source lib/env.sh.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/table-column.sh
source "$REPO_ROOT/lib/table-column.sh"

# Consume stdin before any refusal. A missing jq, or a stuck tool that fails,
# must not leave the pipeline writer with SIGPIPE.
table="$(cat || true)"

if ! command -v jq >/dev/null 2>&1; then
  echo "calibration-signatures: required tool missing: jq" >&2
  exit 1
fi

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
TAPE_FILE="${TAPE_DIR}/tape.jsonl"
STUCK_TOOL="${TAPE_STUCK_TOOL:-$SCRIPT_DIR/tape-stuck.sh}"

stuck_rc=0
stuck_out="$("$STUCK_TOOL")" || stuck_rc=$?
if [ "$stuck_rc" -ne 0 ]; then
  echo "calibration-signatures: stuck tool failed (rc=$stuck_rc): $STUCK_TOOL" >&2
  exit 1
fi
if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$stuck_out"; then
  echo "calibration-signatures: stuck tool did not print a JSON array" >&2
  exit 1
fi

# A missing or empty tape contributes no outcome signatures. /dev/null parses
# as no records, so the filter below has one shape.
tape_input="/dev/null"
if [ -f "$TAPE_FILE" ] && [ -s "$TAPE_FILE" ]; then
  tape_input="$TAPE_FILE"
fi

# One object: "<loop>/<class>" -> "name:count, ..." (at most three). A key
# with no label is absent, and table_append_column prints `-` for it.
values="$(jq -R -s -c --argjson stuck "$stuck_out" '
  [ split("\n")[]
    | (try fromjson catch null)
    | select(type == "object") ] as $recs
  | ($recs | map(select(.type == "proposal"
          and ((.id | type) == "string")
          and ((.loop | type) == "string")
          and ((.class | type) == "string")))) as $props
  # Last outcome in tape order: reduce walks the file, so a later outcome
  # replaces an earlier one for the same proposal_id. group_by would sort.
  | (reduce ($recs | map(select(.type == "outcome"
          and ((.proposal_id | type) == "string"))))[] as $o
      ({}; .[$o.proposal_id] = $o)) as $lasts
  | ([ $props[]
       | . as $p
       | ($lasts[$p.id].signature) as $sig
       | select(($sig | type) == "string" and $sig != "")
       | {key: ($p.loop + "/" + $p.class), sig: $sig}
     ] + [
       $stuck[]
       | select(type == "object"
               and ((.loop | type) == "string")
               and ((.class | type) == "string"))
       | {key: (.loop + "/" + .class), sig: "stuck"}
     ]) as $labels
  | ($labels
     | group_by(.key)
     | map(
         (.[0].key) as $k
         | (group_by(.sig)
            | map({key: .[0].sig, value: length})
            | sort_by([-.value, .key])
            | .[0:3]
            | map("\(.key):\(.value)")
            | join(", ")) as $v
         | select($v != "")
         | {key: $k, value: $v}
       )
     | from_entries)
' "$tape_input")"

printf '%s' "$table" | table_append_column "top signatures" "$values"
